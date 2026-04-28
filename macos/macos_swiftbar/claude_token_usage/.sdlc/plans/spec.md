## Outcome ##
Create a SwiftBar plugin (bash script) that shows key metrics on Claude token usage and estimated inference cost for the current day.

---

## Sections

**Group A — Infrastructure**
- 1. Scaffolding
- 2. Error Handling

**Group B — Data Pipeline**
- 3. Model Pricing
- 4. ccusage Data Fetch
- 5. Price Calculation
- 6. Metrics Storage
- 7. Metric Reading

**Group C — Utilities**
- 8. Number Formatting
- 9. Efficiency Calculations

**Group D — Display**
- 10. Display Constants
- 11. Display — Bar Chart
- 12. Display — Metrics Table
- 13. Menu Bar + Main

---

## Group A — Infrastructure

### 1. Scaffolding

#### Project Layout

```
<repo-root>/
├── src/
│   └── claude_token_usage.1m.sh   ← the SwiftBar plugin script
├── price/
│   ├── model_prices_and_context_window.json
│   └── claude_model_prices.csv
└── data/
    ├── rolling_metrics_7_days.csv
    └── widget.log
```

The script resolves its own directory at runtime (`SCRIPT_DIR`) and derives all paths relative to it:
- `PRICE_DIR      = $SCRIPT_DIR/../price`
- `DATA_DIR       = $SCRIPT_DIR/../data`
- `PRICE_JSON     = $PRICE_DIR/model_prices_and_context_window.json`
- `PRICE_CSV      = $PRICE_DIR/claude_model_prices.csv`
- `ROLLING_CSV    = $DATA_DIR/rolling_metrics_7_days.csv`
- `ROLLING_CSV_TMP= $ROLLING_CSV.tmp`
- `LOG            = $DATA_DIR/widget.log`

Register a trap to remove `ROLLING_CSV_TMP` on exit:
```bash
trap 'rm -f "$ROLLING_CSV_TMP"' EXIT
```

#### SwiftBar Plugin Requirements

The script must begin with these SwiftBar metadata directives:
```bash
#!/bin/bash
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
```

SwiftBar attribute syntax: append `| key=value key2=value2` to any output line.
- The first line of output becomes the menu bar text.
- A line containing only `---` is a separator; everything after it appears in the dropdown.
- Multiple `---` lines create visual separators within the dropdown.

PATH must be exported early so that `ccusage`, `jq`, and `curl` are found on macOS:
```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
```

Enable strict error handling:
```bash
set -euo pipefail
```

All error paths must still `exit 0` (not non-zero) so SwiftBar renders the error text rather than showing an error badge. See Section 2 for the full error table.

#### Configuration
- Refresh interval: encoded in the filename per SwiftBar convention. Default: `claude_token_usage.1m.sh` (1 minute).

#### macOS-Specific Commands
This script targets macOS exclusively (SwiftBar is macOS-only). Use macOS BSD variants throughout:
- File mtime: `stat -f %m "$file"` (Linux equivalent would be `stat -c %Y`)
- Date arithmetic: `date -v-Nd +%Y%m%d` for N days ago (Linux: `date -d "N days ago" +%Y%m%d`)

#### Defensive Variable Defaults
With `set -u` active, all shell variable references used in arithmetic or passed to external commands must use `${var:-0}` (or `${var:-}`) to avoid unbound variable errors. Apply this consistently to all metric variables (`TODAY_*`, `WEEK_*`) at their point of use.

#### Log Rotation
Rotate `data/widget.log` to the last 500 lines on every run, before any other operations, using an atomic `tail → .tmp → mv` pattern. Rotation errors are silently ignored (`2>/dev/null || true`).

---

### 2. Error Handling

| Condition | Menu bar output | Dropdown output | Script exit |
|-----------|----------------|-----------------|-------------|
| Pricing download fails | `Pricing data unavailable` | `Failed to download or parse pricing data. Check $LOG` | `exit 0` |
| Pricing CSV missing or empty | `Pricing data unavailable` | `claude_model_prices.csv is missing or empty` | `exit 0` |
| `update_rolling_csv` fails | `Data update failed` | `Check $LOG` | `exit 0` |
| Model not in pricing CSV | *(no effect on display)* | *(warning logged to `data/widget.log`)* | continues |

All error exits use `exit 0` so SwiftBar renders the text output rather than an error badge.

Log file path: `data/widget.log`

---

## Group B — Data Pipeline

### 3. Model Pricing

#### Setup
`mkdir -p "$PRICE_DIR"` to ensure the directory exists before any file operations.

#### Fetch Condition
Re-fetch `model_prices_and_context_window.json` if any of the following are true:
- File does not exist
- File mtime is older than 86400 seconds (24 hours)
- File exists but `claude_model_prices.csv` is missing or empty

#### Download
Use an atomic write (download to `.tmp`, then `mv` on success):
```bash
curl -sL --max-time 10 \
  https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json \
  -o "$PRICE_JSON.tmp"
mv "$PRICE_JSON.tmp" "$PRICE_JSON"
```
On curl failure: log the error, remove the `.tmp` file, and return failure.

#### Extract to CSV
Delete the old CSV, then write fresh:
```bash
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
' "$PRICE_JSON" > "$PRICE_CSV"
```
`// 0` guards against null fields. If the jq step fails, delete the partial CSV and return failure.

CSV column order: `model_name, cache_creation_cost, cache_read_cost, input_cost, output_cost`

---

### 4. ccusage Data Fetch

#### Get Data for a Date Range
```bash
ccusage daily --since "$SINCE" --until "$UNTIL" --mode=display --json --breakdown \
  | jq -r '
      .daily // []
      | .[]
      | (.date | gsub("-"; "")) as $date
      | .modelBreakdowns // []
      | .[]
      | [$date, .modelName,
         (.inputTokens // 0), (.outputTokens // 0),
         (.cacheCreationTokens // 0), (.cacheReadTokens // 0)]
      | @tsv
    ' 2>/dev/null || true
```
Output TSV columns: `YYYYMMDD, modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens`

---

### 5. Price Calculation

Process the ccusage TSV through awk:

1. Load `claude_model_prices.csv` into lookup arrays keyed by model name (strip surrounding quotes from the model name field).
2. For each TSV row, multiply:
   - `input_cost    = inputTokens          * input_cost_per_token`
   - `cc_cost       = cacheCreationTokens  * cache_creation_cost`
   - `cr_cost       = cacheReadTokens      * cache_read_cost`
   - `output_cost   = outputTokens         * output_cost_per_token`
3. Accumulate per date across all model rows.
4. Output one CSV row per date (sorted by whatever order awk iterates — the rebuild loop handles ordering):
   ```
   YYYY-MM-DD,in_count,in_cost,cc_count,cc_cost,cr_count,cr_cost,out_count,out_cost
   ```
   with costs formatted as `%.10f`.

If a model name is not found in the pricing lookup, log a warning to `data/widget.log` and treat its costs as 0. Log each unknown model name **at most once per run** (deduplicate warnings within the same awk pass).

---

### 6. Metrics Storage

#### File: `data/rolling_metrics_7_days.csv`
Header (row 0):
```
date,total_input_count,total_input_cost,total_cache_created_count,total_cache_created_cost,total_cache_read_count,total_cache_read_cost,total_output_count,total_output_cost
```

Cost values are stored with 10 decimal places (`%.10f`) to preserve precision across aggregation.
Dates are stored as `YYYY-MM-DD`.

#### Setup
`mkdir -p "$DATA_DIR"` to ensure the directory exists before any file operations.

#### Update Logic (runs every refresh)

1. Determine `fetch_since`: start with today. Walk back days 1–6; for **every** day not present in the existing CSV (or if the CSV doesn't exist), update `fetch_since` to that day. Do **not** stop early — iterate all 6 days so that `fetch_since` ends up set to the **oldest** missing day, not merely the first one found.
2. Fetch all ccusage data from `fetch_since` to today in a single call (see Section 4).
3. Calculate per-day metrics from the fetched TSV (see Section 5).
4. Rebuild the CSV from scratch, writing a fresh header, then one row per day for `i = 0..6` (today to 6 days ago):
   - **Today (i=0)**: use fresh-calculated row if available; else use cached row from old CSV; else write a zero row.
   - **Past days (i=1–6)**: use cached row from old CSV if available (past data does not change); else use fresh-calculated row if available; else write a zero row.
5. Discard any rows older than 7 days (the rebuild loop naturally enforces this).

#### Zero Row Format
```
YYYY-MM-DD,0,0.0000000000,0,0.0000000000,0,0.0000000000,0,0.0000000000
```

---

### 7. Metric Reading

After rebuilding the CSV, read it in a single awk pass (skip header row):
- Row 1 (today): extract all 8 metric fields as today's values.
- All rows: accumulate sums for the 7-day weekly totals.

Expose as shell variables:
```
TODAY_IN_C, TODAY_IN_COST, TODAY_CC_C, TODAY_CC_COST
TODAY_CR_C, TODAY_CR_COST, TODAY_OUT_C, TODAY_OUT_COST
WEEK_IN_C,  WEEK_IN_COST,  WEEK_CC_C,  WEEK_CC_COST
WEEK_CR_C,  WEEK_CR_COST,  WEEK_OUT_C, WEEK_OUT_COST
```

Then compute totals via awk (to preserve floating-point precision):
```
TODAY_COST = TODAY_CC_COST + TODAY_CR_COST + TODAY_IN_COST + TODAY_OUT_COST
WEEK_COST  = WEEK_CC_COST  + WEEK_CR_COST  + WEEK_IN_COST  + WEEK_OUT_COST
TODAY_TOK  = TODAY_CC_C + TODAY_CR_C + TODAY_IN_C + TODAY_OUT_C
WEEK_TOK   = WEEK_CC_C  + WEEK_CR_C  + WEEK_IN_C  + WEEK_OUT_C
```

#### Pre-compute Table Labels and Column Widths

After reading metrics, format all token and cost labels once and compute shared column widths used by Sections 11 and 12. Store results in global variables:

Token labels (`format_k`): `LBL_T_TOT`, `LBL_T_CR`, `LBL_T_CC`, `LBL_T_IN`, `LBL_T_OUT`, and weekly equivalents `LBL_W_*`.

Cost labels (`format_cost`): `COST_T_TOT`, `COST_T_CR`, `COST_T_CC`, `COST_T_IN`, `COST_T_OUT`, and weekly equivalents `COST_W_*`.

Column widths (used by both metrics table and efficiency rows):
- `TABLE_MT_TOK` — max token label width across today's rows
- `TABLE_MT_COST` — max cost label width across today's rows
- `TABLE_MW_TOK` — max token label width across weekly rows
- `TABLE_MW_COST` — max cost label width across weekly rows
- `TABLE_CT_W = TABLE_MT_TOK + 3 + TABLE_MT_COST` — full today column width
- `TABLE_CW_W = TABLE_MW_TOK + 3 + TABLE_MW_COST` — full weekly column width

---

## Group C — Utilities

### 8. Number Formatting

#### Token Counts (`format_k`)
- ≥ 1,000,000 → `#.#m` (1 decimal rounded half-up, lowercase `m`, comma thousands separator on the integer part). Example: `1,234,567` → `1.2m`
- ≥ 500 → rounded to nearest thousand (half-up), lowercase `k`, comma thousands separator. Example: `750` → `1k`, `15,300` → `15k`, `1,500,000` → `1,500k` is wrong — millions rule takes precedence
- < 500 → raw integer. Example: `42` → `42`
- K values are never shown with a decimal — always integers

#### Costs (`format_cost`)
- Format: `$#,###.##` (always 2 decimal places, comma thousands separator, cents rounded half-up)
- Carry propagation: if rounded cents reach 100, increment dollars. Example: `$0.999` → `$1.00`
- Example: `1234.5` → `$1,234.50`

#### Efficiency Display Formats
- Cache Hit Rate: `%.1f%%` — 1 decimal place followed by `%`. Example: `72.3%`
- I/O Ratio: `%.1fx` — 1 decimal place followed by `x`. Example: `14.7x`
- Both display `N/A` (no color) when the denominator is zero

---

### 9. Efficiency Calculations

#### Cache Hit Rate
```
Cache Hit Rate = Cache Read Tokens / (Cache Read Tokens + Cache Write Tokens) × 100
```
Display: `%.1f%%` (e.g. `72.3%`). Display `N/A` when `(cache_read + cache_write) == 0`.

Color thresholds (applied to the row):
- ≥ 70% → `green`
- ≥ 40% → `orange`
- < 40% → `red`
- Zero denominator → no color

#### I/O Ratio
```
I/O Ratio = (Input Tokens + Cache Read Tokens) / Output Tokens
```
Display: `%.1fx` (e.g. `14.7x`). Display `N/A` when `output == 0`.

Color thresholds:
- ≥ 300x → `#FFD700` (gold)
- ≥ 50x  → `#34C759` (green)
- ≥ 20x  → `orange`
- < 20x  → `red`
- Zero denominator → no color

---

## Group D — Display

### 10. Display Constants

#### SwiftBar Font String
Define once and reuse:
```bash
SF="| font=Menlo size=11 trim=false"
```
Append to every dropdown output line.

Menu bar line uses `size=12` (no Menlo, no trim).

#### Table Row Colors (appended after `$SF`)
| Row | Color |
|-----|-------|
| Bar chart rows | `#B7470A` |
| Table header (Today / Last 7 Days) | no color (default) |
| Total row | `#B7470A` |
| Cache read / Cache create / Input token / Output token | `#1F5C99` |
| Cache hit rate | dynamic — see Section 9 |
| I/O ratio | dynamic — see Section 9 |

---

### 11. Display — Bar Chart

Read directly from `data/rolling_metrics_7_days.csv` (skip the header row). One row per day for the past 7 days, today first (descending). For each CSV row, compute:
- `tok  = col2 + col4 + col6 + col8` (in_count + cc_count + cr_count + out_count)
- `cost = col3 + col5 + col7 + col9` (in_cost + cc_cost + cr_cost + out_cost)

Format per row:
```
MM/DD <bar><trailing> <right-aligned-cost>  <left-aligned-tokens> | font=Menlo size=11 trim=false color=#B7470A
```
- `MM/DD`: month and day extracted from the stored `YYYY-MM-DD` date
- `<bar>`: exactly 20 characters of `█` (filled) and `░` (empty), where `filled = int(cost / max_cost * 20 + 0.5)` (round-half-up); if `max_cost == 0` treat as 1 to avoid division by zero
- `<trailing>`: 3 additional `░` characters appended after the 20-char bar
- One space between `MM/DD` and the bar; one space between bar and cost
- Cost: right-aligned to the width of the longest cost label across all 7 rows
- Two spaces between cost and tokens
- Tokens: left-aligned to the width of the longest token label across all 7 rows

The caller (Section 13) prints a `---` separator line after invoking this function.

---

### 12. Display — Metrics Table

#### Column Layout
printf `%-*s   %-*s   %-*s %s\n` — 3 spaces between each column:
- Column 1: row label, left-aligned to 13 characters
- Column 2 (Today): cell content is `token_count (cost)` — token count **left-aligned** (right-padded with spaces) to `max_today_tok_width`, then the literal ` (`, then the cost string, then `)`. The cost is **not** independently padded; the outer `%-*s` left-aligns the whole cell to column width = `max_today_tok_width + 3 + max_today_cost_width` (the `+3` accounts for ` (` and `)`)
- Column 3 (Last 7 Days): same structure, widths from weekly maxima

#### Header Row (no color)
```
             Today                    Last 7 Days
```

#### Data Rows

| Label (13 chars) | Today cell | Last 7 Days cell |
|---|---|---|
| `Total` | all-type token sum + all-type cost | weekly aggregates |
| `Cache read` | cache read tokens + cost | weekly |
| `Cache create` | cache creation tokens + cost | weekly |
| `Input token` | input tokens + cost | weekly |
| `Output token` | output tokens + cost | weekly |

Row colors: Total = `#B7470A`, all others = `#1F5C99`.

The caller (Section 13) prints a `---` separator line after invoking this function.

#### Efficiency Rows
Same column widths as the metrics table above. No repeated header.

| Label (13 chars) | Today | Last 7 Days |
|---|---|---|
| `Cache hit` | cache hit rate | weekly cache hit rate |
| `I/O ratio` | I/O ratio | weekly I/O ratio |

Colors: dynamic per thresholds (based on today's values for both columns' color).

---

### 13. Menu Bar + Main

#### Menu Bar Output (closed state)
```
CL-Tok: <tokens> <cost> | size=12
```
- `<tokens>`: sum of all 4 token types (cache create + cache read + input + output) for today, formatted with `format_k`
- `<cost>`: sum of all 4 cost types for today, formatted with `format_cost`

This is the first line of script output and becomes the SwiftBar menu bar text.

#### Main Execution Flow
Call all functions in dependency order:
1. Rotate log (Section 1)
2. `update_pricing` (Section 3) — exit with error display on failure
3. Verify `PRICE_CSV` is non-empty — exit with error display on failure
4. `update_rolling_csv` (Section 6, uses Sections 4 and 5) — exit with error display on failure
5. Initialize all `TODAY_*` / `WEEK_*` vars to 0, call `read_rolling_metrics` (Section 7)
6. Initialize cost/token totals to 0, call `compute_totals` (Section 7)
7. Initialize `CHR_TODAY`, `CHR_WEEK`, `IOR_TODAY`, `IOR_WEEK` to `"NA"`, call `compute_efficiency` (Section 9)
8. Pre-compute all formatted labels and shared column widths via `compute_table_widths`
9. Print menu bar line (this section)
10. Print `---` to open the dropdown
11. Render bar chart (Section 11), then print `---`
12. Render metrics table (Section 12), then print `---`
13. Render efficiency rows (Section 12)
