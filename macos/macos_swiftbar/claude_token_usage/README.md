# Claude Token Usage — SwiftBar Widget

A macOS menu bar widget that tracks your daily Claude token usage and estimated inference costs, updated every minute.
Useful to estimate Claude API costs through Claude Pro and Claude Max.

<img width="433" height="495" alt="CL-Tok" src="https://github.com/user-attachments/assets/56027734-b990-4aec-9e98-d69341d50238" />

## Why use this?

Claude's web and desktop interfaces don't show token counts or cost breakdowns in real time. If you're a heavy user on Claude Pro or Max, it can be hard to know how much of your context budget you're burning — or whether a heavy agentic session is costing significantly more than a typical day.

This widget gives you:

- **Instant visibility** — cost and token count always visible in your menu bar, no app switching required
- **Daily spend awareness** — see at a glance if today is trending higher than usual
- **Token type breakdown** — understand the split between cache reads, cache creates, input, and output so you can reason about where cost is coming from
- **7-day trend** — spot patterns across the week, not just the current session
- **Efficiency signals** — cache hit rate and I/O ratio show whether your prompts are well-structured for caching; low cache hit rate or low I/O ratio means you're paying more per token than you could be

## What it shows

**Menu bar:** Total tokens used today and today's cost at a glance.

**Dropdown:**
- 7-day bar chart of daily spend
- Per-category breakdown (cache read, cache create, input, output) with token counts and costs
- Today vs. last 7 days comparison table
- Cache hit rate and I/O ratio with color-coded efficiency indicators

## Dependencies

| Tool | What it does |
|---|---|
| **SwiftBar** | Runs bash scripts on a schedule and renders their output in the macOS menu bar |
| **ccusage** | Reads Claude's local conversation logs and outputs token usage statistics as JSON |
| **jq** | Parses and transforms JSON on the command line |

## Install

**1. Install Homebrew** (skip if already installed):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**2. Install dependencies:**

```bash
brew install --cask swiftbar
brew install ccusage
brew install jq
```

Or run the included setup script:

```bash
chmod +x setup_with_brew.sh
./setup_with_brew.sh
```

## Add to SwiftBar

1. Open SwiftBar — it will prompt you to choose a **plugin folder** (a directory SwiftBar watches for scripts).
   Already running? Find the folder via **⚡ menu → Open Plugin Folder**.
2. Copy or symlink the script into that folder:
   ```bash
   cp src/claude_token_usage.1m.sh ~/path/to/swiftbar/plugins/
   # or
   ln -s "$(pwd)/src/claude_token_usage.1m.sh" ~/path/to/swiftbar/plugins/
   ```
3. Optionally set a plugin data directory in SwiftBar preferences (**⚡ menu → Preferences → Plugin Data Path**). SwiftBar sets `SWIFTBAR_PLUGIN_DATA_PATH` for the plugin; if it is missing, the script uses its own directory.
4. Make sure the script is executable:
   ```bash
   chmod +x src/claude_token_usage.1m.sh
   ```
5. Click **Refresh All** in SwiftBar — the widget appears in your menu bar within a minute

> The `1m` in the filename tells SwiftBar to refresh every 1 minute. Rename to `claude_token_usage.5m.sh` for a 5-minute interval, etc.

## How it works

On each refresh the script:

1. Refreshes model pricing from [litellm](https://github.com/BerriAI/litellm) when the price file is older than 24 hours. If the download fails, the last good price file is used.
2. Calls `ccusage` once for the last 7 days and reads the per-model token counts (`modelBreakdowns`)
3. Calculates each model's cost by multiplying its token counts against that model's price. A dated model name with no exact price (for example `claude-sonnet-5-5-20261101`) uses the longest price key that is a prefix of the name.
4. Renders the menu bar line and dropdown

Every refresh reprices all 7 days, so there is no cached history to go stale.

Files are written under `$SWIFTBAR_PLUGIN_DATA_PATH/claude_token_usage/`:

- `price/claude_model_prices.csv`: the Claude rows of the litellm price list
- `data/widget.log`: download failures, models priced by prefix, and models with no price

All data is local — nothing is sent anywhere beyond the pricing JSON fetch from GitHub.

## Configuration

Tunable values are variables in the `# ── config ──` section at the top of `src/claude_token_usage.1m.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `DAYS` | `7` | Days shown in the chart and summed in the totals column |
| `BAR_WIDTH` | `20` | Width of each bar in the chart |
| `LABEL_WIDTH` | `13` | Width of the label column in the dropdown |
| `PRICE_TTL` | `86400` | Seconds before the price file is refreshed |
| `PRICE_URL` | litellm price list | Source of model prices |
| `HIT_RATE_ORANGE`, `HIT_RATE_GREEN` | `40`, `70` | Cache hit rate percent where the color turns orange and green |
| `IO_RATIO_ORANGE`, `IO_RATIO_GREEN`, `IO_RATIO_GOLD` | `20`, `50`, `300` | I/O ratio where the color turns orange, green and gold |

## Metrics Goals

The dropdown colors each metric by these cutoffs, which are set in the config section.

| Metric | Red | Orange | Green | Gold |
|---|---|---|---|---|
| **Cache hit rate** | < 40% | 40% to 70% | ≥ 70% | n/a |
| **I/O ratio** | < 20:1 | 20:1 to 50:1 | 50:1 to 300:1 | ≥ 300:1 |

**Cache hit rate** measures what fraction of your cache-eligible tokens were served from cache rather than reprocessed. At ≥ 70%, the bulk of your context is reused across turns, which directly lowers cost — cached reads are 10× to 20× cheaper than regular input tokens, depending on the model.

**I/O ratio** is (input + cache read tokens) ÷ output tokens. Output tokens are the most expensive, so a high ratio — 50:1 or above — means you're getting focused responses from a well-cached context, which is the most cost-efficient operating point. Below 20:1, output is dominating and cost rises fast.

At 300:1 and above, the widget shows the ratio in gold.
