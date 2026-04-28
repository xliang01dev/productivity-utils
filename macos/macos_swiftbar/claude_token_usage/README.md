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
3. Set a plugin data directory in SwiftBar preferences (**⚡ menu → Preferences → Plugin Data Path**), or leave it unset to use the script's own directory as the default.
4. Make sure the script is executable:
   ```bash
   chmod +x src/claude_token_usage.1m.sh
   ```
5. Click **Refresh All** in SwiftBar — the widget appears in your menu bar within a minute

> The `1m` in the filename tells SwiftBar to refresh every 1 minute. Rename to `claude_token_usage.5m.sh` for a 5-minute interval, etc.

## How it works

On each refresh the script:

1. Downloads model pricing from [litellm](https://github.com/BerriAI/litellm) (cached for 24 hours)
2. Calls `ccusage` to fetch today's token usage by model
3. Calculates costs by multiplying token counts against the pricing data
4. Stores a rolling 7-day CSV in the SwiftBar plugin data directory (`$SWIFTBAR_PLUGIN_DATA_PATH/claude_token_usage/data/`), falling back to the script's own directory
5. Renders the menu bar line and dropdown

All data is local — nothing is sent anywhere beyond the pricing JSON fetch from GitHub.

## Metrics Goals

| Metric | Target |
|---|---|
| **Cache hit rate** | ≥ 90% |
| **I/O ratio** | ≥ 100:1 |

**Cache hit rate** measures what fraction of your cache-eligible tokens were served from cache rather than reprocessed. At ≥ 90%, the bulk of your context is reused across turns, which directly lowers cost — cached reads are roughly 10× cheaper than regular input tokens on most Claude models.

**I/O ratio** is (input + cache read tokens) ÷ output tokens. Output tokens are the most expensive, so a high ratio — 100:1 or above — means you're getting focused responses from a well-cached context, which is the most cost-efficient operating point. Below 50:1, output is dominating and cost rises fast.

Above 300:1, the ratio flips to a different problem: the context window is oversized. You're paying for more cached input than the task needs — trimming prompts would reduce cost without sacrificing output quality.
