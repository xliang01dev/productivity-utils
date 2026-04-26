#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRICE_DIR="$SCRIPT_DIR/../price"
DATA_DIR="$SCRIPT_DIR/../data"
PRICE_JSON="$PRICE_DIR/model_prices_and_context_window.json"
PRICE_CSV="$PRICE_DIR/claude_model_prices.csv"
ROLLING_CSV="$DATA_DIR/rolling_metrics_7_days.csv"
ROLLING_HEADER="date,total_input_count,total_input_cost,total_cache_created_count,total_cache_created_cost,total_cache_read_count,total_cache_read_cost,total_output_count,total_output_cost"
LOG="$DATA_DIR/widget.log"
SF="| font=Menlo size=11 trim=false"

# shared awk helpers — injected into format_k, format_cost, and render_bar_chart
_AWK_COMMIFY='function commify(x,   s,r,i,l) {
  s = sprintf("%d", x); r = ""; l = length(s)
  for (i = 1; i <= l; i++) {
    if (i > 1 && (l - i + 1) % 3 == 0) r = r ","
    r = r substr(s, i, 1)
  }
  return r
}'
_AWK_FORMAT='
function fmt_k(n,   v,ip,dp) {
  if (n >= 1000000) {
    v = n / 1000000; ip = int(v); dp = int((v - ip) * 10 + 0.5)
    if (dp >= 10) { ip++; dp = 0 }
    return commify(ip) "." dp "m"
  } else if (n >= 500) {
    return commify(int(n / 1000 + 0.5)) "k"
  } else { return int(n) }
}
function fmt_cost(v,   d,c) {
  d = int(v); c = int((v - d) * 100 + 0.5)
  if (c >= 100) { d++; c = 0 }
  return "$" commify(d) "." sprintf("%02d", c)
}'

mkdir -p "$PRICE_DIR" "$DATA_DIR"
[ ! -f "$LOG" ] || { tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; } 2>/dev/null || true

# ── pricing ───────────────────────────────────────────────────────────────────

fetch_pricing_if_stale() {
  local needs_update=0
  if [ ! -f "$PRICE_JSON" ]; then
    needs_update=1
  else
    local now mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$PRICE_JSON")
    [ $(( now - mtime )) -gt 86400 ] && needs_update=1
  fi
  [ -f "$PRICE_JSON" ] && [ ! -s "$PRICE_CSV" ] && needs_update=1
  [ "$needs_update" -eq 0 ] && return 0

  local tmp_json="$PRICE_JSON.tmp"
  curl -sL --max-time 10 \
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
    -o "$tmp_json" 2>>"$LOG" \
    || { echo "$(date): curl failed" >> "$LOG"; rm -f "$tmp_json"; return 1; }
  mv "$tmp_json" "$PRICE_JSON"

  rm -f "$PRICE_CSV"
  jq -r '
    to_entries[]
    | select(.key | startswith("claude"))
    | [.key,
       (.value.cache_creation_input_token_cost // 0),
       (.value.cache_read_input_token_cost // 0),
       (.value.input_cost_per_token // 0),
       (.value.output_cost_per_token // 0)]
    | @csv
  ' "$PRICE_JSON" > "$PRICE_CSV" 2>>"$LOG" || { rm -f "$PRICE_CSV"; return 1; }
}

# ── ccusage ───────────────────────────────────────────────────────────────────

# fetch_ccusage_for_range <since_YYYYMMDD> <until_YYYYMMDD>
# outputs TSV: YYYYMMDD\tmodelName\tinputTokens\toutputTokens\tcacheCreationTokens\tcacheReadTokens
fetch_ccusage_for_range() {
  ccusage daily --since "$1" --until "$2" --mode=display --json --breakdown 2>/dev/null \
    | jq -r '
        .daily // []
        | .[]
        | (.date | gsub("-"; "")) as $date
        | .modelBreakdowns // []
        | .[]
        | [$date,
           .modelName,
           (.inputTokens // 0),
           (.outputTokens // 0),
           (.cacheCreationTokens // 0),
           (.cacheReadTokens // 0)]
        | @tsv
      ' 2>/dev/null || true
}

# ── cost calculation ──────────────────────────────────────────────────────────

# _calc_metrics_from_range_tsv — reads TSV from stdin (date as first field)
# outputs one CSV row per date: YYYY-MM-DD,in_count,in_cost,cc_count,cc_cost,...
_calc_metrics_from_range_tsv() {
  awk -F'\t' -v price_csv="$PRICE_CSV" -v log="$LOG" '
    BEGIN {
      while ((getline line < price_csv) > 0) {
        n = split(line, f, ",")
        if (n >= 5) {
          m = f[1]; gsub(/"/, "", m)
          p_cc[m] = f[2]+0
          p_cr[m] = f[3]+0
          p_in[m] = f[4]+0
          p_out[m] = f[5]+0
        }
      }
      close(price_csv)
    }
    NF == 6 {
      date=$1; m=$2; it=$3+0; ot=$4+0; cct=$5+0; crt=$6+0
      if (!(m in p_in) && !(m in warned)) { print "Warning: model " m " not found in pricing" >> log; warned[m]=1 }
      ti[date]   += it;  tic[date]  += it  * (m in p_in  ? p_in[m]  : 0)
      tcc[date]  += cct; tccc[date] += cct * (m in p_cc  ? p_cc[m]  : 0)
      tcr[date]  += crt; tcrc[date] += crt * (m in p_cr  ? p_cr[m]  : 0)
      to[date]  += ot;  toc[date]  += ot  * (m in p_out ? p_out[m] : 0)
    }
    END {
      for (date in ti) {
        d_csv = substr(date,1,4) "-" substr(date,5,2) "-" substr(date,7,2)
        printf "%s,%d,%.10f,%d,%.10f,%d,%.10f,%d,%.10f\n",
          d_csv, ti[date], tic[date], tcc[date], tccc[date],
          tcr[date], tcrc[date], to[date], toc[date]
      }
    }
  '
}

# ── rolling CSV ───────────────────────────────────────────────────────────────

yyyymmdd_to_csv_date() { printf '%s-%s-%s' "${1:0:4}" "${1:4:2}" "${1:6:2}"; }
zero_row() { echo "${1},0,0.0000000000,0,0.0000000000,0,0.0000000000,0,0.0000000000"; }

update_rolling_csv() {
  local i d d_csv row tmp cached_today fresh_row range_tsv all_fresh
  local fetch_since fetch_today csv_exists=0
  tmp="$ROLLING_CSV.tmp"
  fetch_today=$(date +%Y%m%d)
  fetch_since="$fetch_today"  # default: today only
  [ -f "$ROLLING_CSV" ] && csv_exists=1

  # Extend fetch range back to the oldest missing past day
  for i in 1 2 3 4 5 6; do
    d=$(date -v-"${i}"d +%Y%m%d)
    d_csv=$(yyyymmdd_to_csv_date "$d")
    if [ "$csv_exists" -eq 0 ] || ! grep -q "^${d_csv}," "$ROLLING_CSV" 2>/dev/null; then
      fetch_since="$d"
    fi
  done

  echo "$ROLLING_HEADER" > "$tmp"

  range_tsv=$(fetch_ccusage_for_range "$fetch_since" "$fetch_today")
  [ -n "$range_tsv" ] && all_fresh=$(printf '%s\n' "$range_tsv" | _calc_metrics_from_range_tsv)

  for i in 0 1 2 3 4 5 6; do
    d=$(date -v-"${i}"d +%Y%m%d)
    d_csv=$(yyyymmdd_to_csv_date "$d")

    fresh_row=""
    [ -n "$all_fresh" ] && fresh_row=$(printf '%s\n' "$all_fresh" | grep "^${d_csv}," 2>/dev/null || true)

    if [ "$i" -eq 0 ]; then
      cached_today=""
      [ "$csv_exists" -eq 1 ] && cached_today=$(grep "^${d_csv}," "$ROLLING_CSV" 2>/dev/null || true)
      if [ -n "$fresh_row" ]; then
        echo "$fresh_row" >> "$tmp"
      elif [ -n "$cached_today" ]; then
        echo "$cached_today" >> "$tmp"
      else
        zero_row "$d_csv" >> "$tmp"
      fi
    else
      row=""
      [ "$csv_exists" -eq 1 ] && row=$(grep "^${d_csv}," "$ROLLING_CSV" 2>/dev/null || true)
      if [ -n "$row" ]; then
        echo "$row" >> "$tmp"
      elif [ -n "$fresh_row" ]; then
        echo "$fresh_row" >> "$tmp"
      else
        zero_row "$d_csv" >> "$tmp"
      fi
    fi
  done

  mv "$tmp" "$ROLLING_CSV"
}

# ── read metrics ──────────────────────────────────────────────────────────────

read_rolling_metrics() {
  local data
  data=$(tail -n +2 "$ROLLING_CSV" | awk -F',' '
    NR==1 { today=$0 }
    { s2+=$2+0; s3+=$3+0; s4+=$4+0; s5+=$5+0
      s6+=$6+0; s7+=$7+0; s8+=$8+0; s9+=$9+0 }
    END {
      print today
      printf "%d,%.10f,%d,%.10f,%d,%.10f,%d,%.10f\n",
        s2, s3, s4, s5, s6, s7, s8, s9
    }
  ')
  IFS=',' read -r _ TODAY_IN_C TODAY_IN_COST TODAY_CC_C TODAY_CC_COST \
                     TODAY_CR_C TODAY_CR_COST TODAY_OUT_C TODAY_OUT_COST <<< "${data%%$'\n'*}"
  IFS=',' read -r WEEK_IN_C WEEK_IN_COST WEEK_CC_C WEEK_CC_COST \
                  WEEK_CR_C WEEK_CR_COST WEEK_OUT_C WEEK_OUT_COST <<< "${data##*$'\n'}"
}

# ── formatting ────────────────────────────────────────────────────────────────

max_len() { local m=0 l; for l in "$@"; do [ "${#l}" -gt "$m" ] && m="${#l}"; done; echo "$m"; }

format_k() {
  awk -v n="${1:-0}" "$_AWK_COMMIFY"'
    BEGIN {
      if (n >= 1000000) {
        v = n / 1000000
        ip = int(v); dp = int((v - ip) * 10 + 0.5)
        if (dp >= 10) { ip++; dp = 0 }
        printf "%s.%dm", commify(ip), dp
      } else if (n >= 500) {
        v = int(n / 1000 + 0.5)
        printf "%sk", commify(v)
      } else {
        printf "%d", int(n)
      }
    }'
}

format_cost() {
  awk -v v="${1:-0}" "$_AWK_COMMIFY"'
    BEGIN {
      d = int(v); c = int((v - d) * 100 + 0.5)
      if (c >= 100) { d++; c = 0 }
      printf "$%s.%02d", commify(d), c
    }'
}

format_hit_rate() {
  awk -v cr="${1:-0}" -v cc="${2:-0}" 'BEGIN {
    d = cr + cc
    if (d == 0) { printf "N/A"; exit }
    printf "%.1f%%", (cr / d) * 100
  }'
}

format_io_ratio() {
  awk -v i="${1:-0}" -v cr="${2:-0}" -v o="${3:-0}" 'BEGIN {
    if (o == 0) { printf "N/A"; exit }
    printf "%.1fx", (i + cr) / o
  }'
}

# cache hit rate: <0-40% red, 40-70% orange, ≥70% green; empty if no data
_hit_rate_color() {
  awk -v cr="${1:-0}" -v cc="${2:-0}" 'BEGIN {
    d = cr + cc; if (d == 0) exit
    p = (cr / d) * 100
    if (p >= 70) print "green"
    else if (p >= 40) print "orange"
    else print "red"
  }'
}

# i/o ratio: <5 red, 5-10 green, >10 orange; empty if no data
_io_ratio_color() {
  awk -v i="${1:-0}" -v cr="${2:-0}" -v o="${3:-0}" 'BEGIN {
    if (o == 0) exit
    r = (i + cr) / o
    if (r >= 300) print "#FFD700"
    else if (r >= 50) print "#34C759"
    else if (r >= 20) print "orange"
    else print "red"
  }'
}

# ── rendering ─────────────────────────────────────────────────────────────────

render_bar_chart() {
  local SF_CHART="$SF color=#B7470A"
  tail -n +2 "$ROLLING_CSV" | awk -F',' -v w=20 -v sf="$SF_CHART" "$_AWK_COMMIFY$_AWK_FORMAT"'
    {
      rows[NR] = $1
      tok[NR]  = $2+0+$4+0+$6+0+$8+0
      cost[NR] = $3+0+$5+0+$7+0+$9+0
      if (cost[NR] > max) max = cost[NR]
    }
    END {
      if (max == 0) max = 1
      max_tlen = 0; max_clen = 0
      for (r = 1; r <= NR; r++) {
        tlbl[r] = fmt_k(tok[r]);   if (length(tlbl[r]) > max_tlen) max_tlen = length(tlbl[r])
        clbl[r] = fmt_cost(cost[r]); if (length(clbl[r]) > max_clen) max_clen = length(clbl[r])
      }
      for (r = 1; r <= NR; r++) {
        filled = int(cost[r] / max * w + 0.5)
        bar = ""
        for (i = 0; i < filled; i++) bar = bar "█"
        for (i = filled; i < w; i++) bar = bar "░"
        bar = bar "░░░"
        lbl = substr(rows[r], 6, 2) "/" substr(rows[r], 9, 2)
        printf "%s %s %" max_clen "s  %-" max_tlen "s %s\n", lbl, bar, clbl[r], tlbl[r], sf
      }
    }
  '
}

render_menu_bar() {
  echo "CL-Tok: $(format_k "$TODAY_TOK") $(format_cost "$TODAY_COST") | size=12"
}

render_dropdown() {
  render_bar_chart
  echo "---"

  local c1=13

  # Pre-compute all token and cost labels
  local tk_cr_t tk_cc_t tk_in_t tk_out_t tk_tot_t
  local tk_cr_w tk_cc_w tk_in_w tk_out_w tk_tot_w
  tk_cr_t=$(format_k "${TODAY_CR_C:-0}");  tk_cr_w=$(format_k "${WEEK_CR_C:-0}")
  tk_cc_t=$(format_k "${TODAY_CC_C:-0}");  tk_cc_w=$(format_k "${WEEK_CC_C:-0}")
  tk_in_t=$(format_k "${TODAY_IN_C:-0}");  tk_in_w=$(format_k "${WEEK_IN_C:-0}")
  tk_out_t=$(format_k "${TODAY_OUT_C:-0}"); tk_out_w=$(format_k "${WEEK_OUT_C:-0}")
  tk_tot_t=$(format_k "$TODAY_TOK");        tk_tot_w=$(format_k "$WEEK_TOK")

  local ck_cr_t ck_cc_t ck_in_t ck_out_t ck_tot_t
  local ck_cr_w ck_cc_w ck_in_w ck_out_w ck_tot_w
  ck_cr_t=$(format_cost "${TODAY_CR_COST:-0}");  ck_cr_w=$(format_cost "${WEEK_CR_COST:-0}")
  ck_cc_t=$(format_cost "${TODAY_CC_COST:-0}");  ck_cc_w=$(format_cost "${WEEK_CC_COST:-0}")
  ck_in_t=$(format_cost "${TODAY_IN_COST:-0}");  ck_in_w=$(format_cost "${WEEK_IN_COST:-0}")
  ck_out_t=$(format_cost "${TODAY_OUT_COST:-0}"); ck_out_w=$(format_cost "${WEEK_OUT_COST:-0}")
  ck_tot_t=$(format_cost "$TODAY_COST");          ck_tot_w=$(format_cost "$WEEK_COST")

  local max_t max_w max_ct max_cw
  max_t=$(max_len  "$tk_cr_t" "$tk_cc_t" "$tk_in_t" "$tk_out_t" "$tk_tot_t")
  max_w=$(max_len  "$tk_cr_w" "$tk_cc_w" "$tk_in_w" "$tk_out_w" "$tk_tot_w")
  max_ct=$(max_len "$ck_cr_t" "$ck_cc_t" "$ck_in_t" "$ck_out_t" "$ck_tot_t")
  max_cw=$(max_len "$ck_cr_w" "$ck_cc_w" "$ck_in_w" "$ck_out_w" "$ck_tot_w")

  local c2=$(( max_t + 3 + max_ct ))
  local c3=$(( max_w + 3 + max_cw ))

  local fmt='%-*s   %-*s   %-*s %s\n'
  local SF_TOKEN_COUNT="$SF color=#1F5C99"
  local SF_TOTAL="$SF color=#B7470A"
  printf "$fmt" "$c1" ""             "$c2" "Today"                                                   "$c3" "Last 7 Days"                                                    "$SF"
  printf "$fmt" "$c1" "Total"        "$c2" "$(printf "%-${max_t}s" "$tk_tot_t") ($ck_tot_t)" "$c3" "$(printf "%-${max_w}s" "$tk_tot_w") ($ck_tot_w)" "$SF_TOTAL"
  printf "$fmt" "$c1" "Cache read"   "$c2" "$(printf "%-${max_t}s" "$tk_cr_t") ($ck_cr_t)"   "$c3" "$(printf "%-${max_w}s" "$tk_cr_w") ($ck_cr_w)"   "$SF_TOKEN_COUNT"
  printf "$fmt" "$c1" "Cache create" "$c2" "$(printf "%-${max_t}s" "$tk_cc_t") ($ck_cc_t)"   "$c3" "$(printf "%-${max_w}s" "$tk_cc_w") ($ck_cc_w)"   "$SF_TOKEN_COUNT"
  printf "$fmt" "$c1" "Input token"  "$c2" "$(printf "%-${max_t}s" "$tk_in_t") ($ck_in_t)"   "$c3" "$(printf "%-${max_w}s" "$tk_in_w") ($ck_in_w)"   "$SF_TOKEN_COUNT"
  printf "$fmt" "$c1" "Output token" "$c2" "$(printf "%-${max_t}s" "$tk_out_t") ($ck_out_t)" "$c3" "$(printf "%-${max_w}s" "$tk_out_w") ($ck_out_w)" "$SF_TOKEN_COUNT"
  echo "---"

  local eff_chr_t eff_chr_w eff_ior_t eff_ior_w
  eff_chr_t=$(format_hit_rate "${TODAY_CR_C:-0}" "${TODAY_CC_C:-0}")
  eff_chr_w=$(format_hit_rate "${WEEK_CR_C:-0}"  "${WEEK_CC_C:-0}")
  eff_ior_t=$(format_io_ratio "${TODAY_IN_C:-0}" "${TODAY_CR_C:-0}" "${TODAY_OUT_C:-0}")
  eff_ior_w=$(format_io_ratio "${WEEK_IN_C:-0}"  "${WEEK_CR_C:-0}" "${WEEK_OUT_C:-0}")
  local chr_color ior_color chr_sf ior_sf
  chr_color=$(_hit_rate_color "${TODAY_CR_C:-0}" "${TODAY_CC_C:-0}")
  ior_color=$(_io_ratio_color "${TODAY_IN_C:-0}" "${TODAY_CR_C:-0}" "${TODAY_OUT_C:-0}")
  chr_sf="$SF${chr_color:+ color=$chr_color}"
  ior_sf="$SF${ior_color:+ color=$ior_color}"
  printf "$fmt" "$c1" "Cache hit"  "$c2" "$eff_chr_t" "$c3" "$eff_chr_w" "$chr_sf"
  printf "$fmt" "$c1" "I/O ratio"  "$c2" "$eff_ior_t" "$c3" "$eff_ior_w" "$ior_sf"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  if ! fetch_pricing_if_stale; then
    echo "Pricing data unavailable"
    echo "---"
    echo "Failed to download or parse pricing data. Check $LOG"
    exit 0
  fi

  if [ ! -f "$PRICE_CSV" ] || [ ! -s "$PRICE_CSV" ]; then
    echo "Pricing data unavailable"
    echo "---"
    echo "claude_model_prices.csv is missing or empty"
    exit 0
  fi

  update_rolling_csv || { echo "Data update failed"; echo "---"; echo "Check $LOG"; exit 0; }

  read_rolling_metrics
  local cost_pair
  cost_pair=$(awk -v ta="${TODAY_CC_COST:-0}" -v tb="${TODAY_CR_COST:-0}" \
                  -v tc="${TODAY_IN_COST:-0}" -v td="${TODAY_OUT_COST:-0}" \
                  -v wa="${WEEK_CC_COST:-0}"  -v wb="${WEEK_CR_COST:-0}" \
                  -v wc="${WEEK_IN_COST:-0}"  -v wd="${WEEK_OUT_COST:-0}" \
                  'BEGIN{printf "%.10f %.10f", ta+tb+tc+td, wa+wb+wc+wd}')
  TODAY_COST="${cost_pair% *}"
  WEEK_COST="${cost_pair#* }"
  local tok_pair
  tok_pair=$(awk -v ta="${TODAY_CC_C:-0}" -v tb="${TODAY_CR_C:-0}" \
                 -v tc="${TODAY_IN_C:-0}" -v td="${TODAY_OUT_C:-0}" \
                 -v wa="${WEEK_CC_C:-0}"  -v wb="${WEEK_CR_C:-0}" \
                 -v wc="${WEEK_IN_C:-0}"  -v wd="${WEEK_OUT_C:-0}" \
                 'BEGIN{printf "%d %d", ta+tb+tc+td, wa+wb+wc+wd}')
  TODAY_TOK="${tok_pair% *}"
  WEEK_TOK="${tok_pair#* }"
  render_menu_bar
  echo "---"
  render_dropdown
}

main
