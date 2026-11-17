#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${SWIFTBAR_PLUGIN_DATA_PATH:-$SCRIPT_DIR}/claude_token_usage"
PRICE_DIR="$BASE_DIR/price"
DATA_DIR="$BASE_DIR/data"
PRICE_JSON="$PRICE_DIR/model_prices_and_context_window.json"
PRICE_CSV="$PRICE_DIR/claude_model_prices.csv"
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

# Refresh claude_model_prices.csv when it is older than 24 hours. On failure the
# existing CSV is kept; main reports an error only when no CSV exists.
fetch_pricing_if_stale() {
  if [ -s "$PRICE_CSV" ] && [ $(( $(date +%s) - $(stat -f %m "$PRICE_CSV") )) -le 86400 ]; then
    return 0
  fi

  curl -sL --max-time 10 \
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
    -o "$PRICE_JSON" 2>>"$LOG" \
    || { echo "$(date): curl failed" >> "$LOG"; rm -f "$PRICE_JSON"; return 0; }

  jq -r '
    to_entries[]
    | select(.key | startswith("claude"))
    | [.key,
       (.value.cache_creation_input_token_cost // 0),
       (.value.cache_read_input_token_cost // 0),
       (.value.input_cost_per_token // 0),
       (.value.output_cost_per_token // 0)]
    | @csv
  ' "$PRICE_JSON" > "$PRICE_CSV.tmp" 2>>"$LOG" && [ -s "$PRICE_CSV.tmp" ] \
    && mv "$PRICE_CSV.tmp" "$PRICE_CSV" \
    || echo "$(date): price parse failed" >> "$LOG"
  rm -f "$PRICE_JSON" "$PRICE_CSV.tmp"
}

# ── ccusage ───────────────────────────────────────────────────────────────────

# fetch_ccusage_for_range <since_YYYYMMDD> <until_YYYYMMDD>
# outputs TSV: YYYYMMDD\tmodelName\tinputTokens\toutputTokens\tcacheCreationTokens\tcacheReadTokens
fetch_ccusage_for_range() {
  ccusage daily --since "$1" --until "$2" --json 2>/dev/null \
    | jq -r '
        .daily // []
        | .[]
        | (.period | gsub("-"; "")) as $date
        | (.modelBreakdowns // [])[]
        | [$date,
           (.modelName // "unknown"),
           (.inputTokens // 0),
           (.outputTokens // 0),
           (.cacheCreationTokens // 0),
           (.cacheReadTokens // 0)]
        | @tsv
      '
}

# ── cost calculation ──────────────────────────────────────────────────────────

# _calc_metrics_from_range_tsv <dates> — reads TSV from stdin (date as first field)
# <dates> is a space separated YYYYMMDD list, newest first
# outputs one CSV row per listed date: YYYY-MM-DD,in_count,in_cost,cc_count,cc_cost,...
_calc_metrics_from_range_tsv() {
  awk -F'\t' -v price_csv="$PRICE_CSV" -v logf="$LOG" -v dates="$1" '
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
      if (!(m in res)) {
        k = ""
        if (m in p_in) k = m
        else for (c in p_in) if (length(c) > length(k) && index(m, c) == 1) k = c
        res[m] = k
        if (k == "") print "Warning: model " m " not found in pricing" >> logf
        else if (k != m) print "Priced by prefix: " m " -> " k >> logf
      }
      k = res[m]
      ti[date]   += it;  tic[date]  += it  * (k != "" ? p_in[k]  : 0)
      tcc[date]  += cct; tccc[date] += cct * (k != "" ? p_cc[k]  : 0)
      tcr[date]  += crt; tcrc[date] += crt * (k != "" ? p_cr[k]  : 0)
      to[date]  += ot;  toc[date]  += ot  * (k != "" ? p_out[k] : 0)
    }
    END {
      n = split(dates, D, " ")
      for (i = 1; i <= n; i++) {
        date = D[i]
        d_csv = substr(date,1,4) "-" substr(date,5,2) "-" substr(date,7,2)
        printf "%s,%d,%.10f,%d,%.10f,%d,%.10f,%d,%.10f\n",
          d_csv, ti[date], tic[date], tcc[date], tccc[date],
          tcr[date], tcrc[date], to[date], toc[date]
      }
    }
  '
}

# ── read metrics ──────────────────────────────────────────────────────────────

# read_metrics — sets TODAY_* and WEEK_* counts, costs, TOK and COST from $ROWS
read_metrics() {
  local data
  data=$(printf '%s\n' "$ROWS" | awk -F',' '
    NR==1 { for (i = 2; i <= 9; i++) t[i] = $i }
    { for (i = 2; i <= 9; i++) w[i] += $i }
    END {
      printf "%d %.10f %d %.10f %d %.10f %d %.10f %d %.10f\n",
        t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9],
        t[2]+t[4]+t[6]+t[8], t[3]+t[5]+t[7]+t[9]
      printf "%d %.10f %d %.10f %d %.10f %d %.10f %d %.10f\n",
        w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9],
        w[2]+w[4]+w[6]+w[8], w[3]+w[5]+w[7]+w[9]
    }
  ')
  read -r TODAY_IN_C TODAY_IN_COST TODAY_CC_C TODAY_CC_COST \
          TODAY_CR_C TODAY_CR_COST TODAY_OUT_C TODAY_OUT_COST TODAY_TOK TODAY_COST <<< "${data%%$'\n'*}"
  read -r WEEK_IN_C WEEK_IN_COST WEEK_CC_C WEEK_CC_COST \
          WEEK_CR_C WEEK_CR_COST WEEK_OUT_C WEEK_OUT_COST WEEK_TOK WEEK_COST <<< "${data##*$'\n'}"
}

# ── formatting ────────────────────────────────────────────────────────────────

max_len() { local m=0 l; for l in "$@"; do [ "${#l}" -gt "$m" ] && m="${#l}"; done; echo "$m"; }

format_k() {
  awk -v n="${1:-0}" "$_AWK_COMMIFY$_AWK_FORMAT"'
    BEGIN { printf "%s", fmt_k(n) }'
}

format_cost() {
  awk -v v="${1:-0}" "$_AWK_COMMIFY$_AWK_FORMAT"'
    BEGIN { printf "%s", fmt_cost(v) }'
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

# i/o ratio: <20 red, 20-50 orange, 50-300 green, ≥300 gold; empty if no data
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
  printf '%s\n' "$ROWS" | awk -F',' -v w=20 -v sf="$SF_CHART" "$_AWK_COMMIFY$_AWK_FORMAT"'
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
  local fmt='%-*s   %-*s   %-*s %s\n'
  local SF_TOKEN_COUNT="$SF color=#1F5C99"
  local SF_TOTAL="$SF color=#B7470A"

  local names=("Total" "Cache read" "Cache create" "Input token" "Output token")
  local tok_t=("$TODAY_TOK" "$TODAY_CR_C" "$TODAY_CC_C" "$TODAY_IN_C" "$TODAY_OUT_C")
  local tok_w=("$WEEK_TOK"  "$WEEK_CR_C"  "$WEEK_CC_C"  "$WEEK_IN_C"  "$WEEK_OUT_C")
  local cost_t=("$TODAY_COST" "$TODAY_CR_COST" "$TODAY_CC_COST" "$TODAY_IN_COST" "$TODAY_OUT_COST")
  local cost_w=("$WEEK_COST"  "$WEEK_CR_COST"  "$WEEK_CC_COST"  "$WEEK_IN_COST"  "$WEEK_OUT_COST")

  local i lk_t=() lk_w=() lc_t=() lc_w=()
  for i in 0 1 2 3 4; do
    lk_t[i]=$(format_k "${tok_t[i]}");    lk_w[i]=$(format_k "${tok_w[i]}")
    lc_t[i]=$(format_cost "${cost_t[i]}"); lc_w[i]=$(format_cost "${cost_w[i]}")
  done

  local max_t max_w max_ct max_cw
  max_t=$(max_len  "${lk_t[@]}")
  max_w=$(max_len  "${lk_w[@]}")
  max_ct=$(max_len "${lc_t[@]}")
  max_cw=$(max_len "${lc_w[@]}")

  local c2=$(( max_t + 3 + max_ct ))
  local c3=$(( max_w + 3 + max_cw ))

  printf "$fmt" "$c1" "" "$c2" "Today" "$c3" "Last 7 Days" "$SF"
  local sf
  for i in 0 1 2 3 4; do
    sf="$SF_TOKEN_COUNT"
    [ "$i" -eq 0 ] && sf="$SF_TOTAL"
    printf "$fmt" "$c1" "${names[i]}" \
      "$c2" "$(printf "%-${max_t}s" "${lk_t[i]}") (${lc_t[i]})" \
      "$c3" "$(printf "%-${max_w}s" "${lk_w[i]}") (${lc_w[i]})" "$sf"
  done
  echo "---"

  local eff_chr_t eff_chr_w eff_ior_t eff_ior_w
  eff_chr_t=$(format_hit_rate "$TODAY_CR_C" "$TODAY_CC_C")
  eff_chr_w=$(format_hit_rate "$WEEK_CR_C"  "$WEEK_CC_C")
  eff_ior_t=$(format_io_ratio "$TODAY_IN_C" "$TODAY_CR_C" "$TODAY_OUT_C")
  eff_ior_w=$(format_io_ratio "$WEEK_IN_C"  "$WEEK_CR_C"  "$WEEK_OUT_C")
  local chr_color ior_color chr_sf ior_sf
  chr_color=$(_hit_rate_color "$TODAY_CR_C" "$TODAY_CC_C")
  ior_color=$(_io_ratio_color "$TODAY_IN_C" "$TODAY_CR_C" "$TODAY_OUT_C")
  chr_sf="$SF${chr_color:+ color=$chr_color}"
  ior_sf="$SF${ior_color:+ color=$ior_color}"
  printf "$fmt" "$c1" "Cache hit"  "$c2" "$eff_chr_t" "$c3" "$eff_chr_w" "$chr_sf"
  printf "$fmt" "$c1" "I/O ratio"  "$c2" "$eff_ior_t" "$c3" "$eff_ior_w" "$ior_sf"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  fetch_pricing_if_stale
  if [ ! -s "$PRICE_CSV" ]; then
    echo "Pricing data unavailable"
    echo "---"
    echo "Failed to download or parse pricing data. Check $LOG"
    exit 0
  fi

  local dates i tsv
  dates=$(date +%Y%m%d)
  for i in 1 2 3 4 5 6; do dates="$dates $(date -v-"${i}"d +%Y%m%d)"; done

  tsv=$(fetch_ccusage_for_range "${dates##* }" "${dates%% *}") \
    || { echo "Data update failed"; echo "---"; echo "Check $LOG"; exit 0; }
  ROWS=$(printf '%s\n' "$tsv" | _calc_metrics_from_range_tsv "$dates")

  read_metrics
  render_menu_bar
  echo "---"
  render_dropdown
}

main
