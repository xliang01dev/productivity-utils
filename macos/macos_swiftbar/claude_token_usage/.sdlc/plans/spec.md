## Outcome ##
Create a SwiftBar widget that shows key metrics on token usage and cost for daily Claude usage.

## Configuration
- Refresh interval: configurable via the script filename (SwiftBar convention). Default is 1 minute (e.g. `claude_token_usage.1m.sh`).

# Menu behavior
When menu is closed the following metrics are displayed on the menu bar:
CL-Tok: #.#k $#.##

- Total token count for today displayed with K (thousands) or M (millions) suffix
- Total cost for all tokens used today, formatted as $#.##

Refer to [Get usage data for today](#get-usage-data-for-today)

When menu is open, the following charts and metrics are shown:
- Bar graph (generated from ascii text) on daily cost for all tokens used in the past 7 days

- A table that has 2 columns with 2 headers: (Today, Last 7 Days)
    - Daily cost of all tokens for today with | total cost of all tokens in the past 7 days
    - cc: created cache input token count displayed as K for today | aggregate created cache input token for all past 7 days including today
    - cr: cached token count displayed as K for today | aggregate cached token count for all past 7 days including today
    - in: input token count displayed as K for today | aggregate input token count for all past 7 days including today
    - out: output token count displayed as K for today | aggregate output token count for all past 7 days including today

## Model Pricing Data
Run the following only if price/model_prices_and_context_window.json does not exist, or has not been updated in the past 24 hours 
```bash
curl -L https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json -o price/model_prices_and_context_window.json
```

Extract the model costs using:
```bash
    jq -r '
    to_entries[]
    | select(.key | startswith("claude"))
    | [.key,
       .value.cache_creation_input_token_cost,
       .value.cache_read_input_token_cost,
       .value.input_cost_per_token,
       .value.output_cost_per_token]
    | @csv
    ' model_prices_and_context_window.json > ./price/claude_model_prices.csv
```
and write to /price/claude_model_prices.csv. Remove the older .csv file if it exists.

## Metrics Storage Rules
Metrics are stored in a rolling log file in data/rolling_metrics_7_days.csv that can store up to 7 days of data.
`rolling_metrics_7_days.csv` should contain the following columns on row 0:
- date
- total_input_count,
- total_input_cost,
- total_cache_created_count,
- total_cache_created_cost,
- total_cache_read_count,
- total_cache_read_cost,
- total_output_count,
- total_output_cost

Values in the csv are calcuated using numbers from `ccusage` and `model_prices_and_context_window.json`
- `ccusage` is used for aggregating token counts, NOT pricing
- `pricing` per model is determined by downloading and parsing model_prices_and_context_window.json
- Rules on how to calculate is listed under [How to Calculate](#How-to-Calculate-Model-Cost)

data/rolling_metrics_7_days.csv is either generated or updated with the following rules:
- Dates are sorted in descending order
- If file does not exist, calculate all 7 days and generate file
- If file already exists, check if there are gaps between the most recent date (top line) and today. Fill missing gaps by calculating each missing day using ccusage and `claude_model_prices.csv`. For example, if the top line indicates 3 days ago, calculate and insert rows for each of the 3 missing days until the top is today. Days with no ccusage data are inserted with zero counts and costs.
- If all 7 days exist and the top line matches today, just update this line with newly calculated metrics for the day
- Any dates that is older than 7 days are discarded

## Error Handling
- If `ccusage` fails or returns no data: Display last known metrics from rolling CSV file. If no historical data exists, display "No data available"
- If pricing file is missing or corrupted: Display error state in the widget and skip metrics calculation until file is repaired or re-downloaded
- If a model returned by ccusage is not found in `claude_model_prices.csv`: Log a warning and treat that model's cost as 0

### How to Calculate Model Cost ###

**Multi-model Aggregation**
- The total token cost per day is the sum of all token types across all models used
- The total tokens per day is the sum of all token types across all models used

# Get usage data for today
```bash
TODAY=$(date +%Y%m%d)
ccusage daily --since "$TODAY" --until "$TODAY" --mode=display --json --breakdown | jq '
    .daily // []
    | .[]
    | .date as $date
    | .modelBreakdowns // []
    | .[]
    | {
        date: $date,
        modelName,
        inputTokens,
        outputTokens,
        cacheCreationTokens,
        cacheReadTokens
      }
  '
```

# Get data for past 7 days
```bash
LAST_7_DAYS=$(date -v-6d +%Y%m%d)
ccusage daily --order desc --since "$LAST_7_DAYS" --mode=display --json --breakdown | jq '
    .daily // []
    | .[]
    | .date as $date
    | .modelBreakdowns // []
    | .[]
    | {
        date: $date,
        modelName,
        inputTokens,
        outputTokens,
        cacheCreationTokens,
        cacheReadTokens
      }
  '
```

# Calculate actual price
1. Parse the cost values per model from `/price/claude_model_prices.csv` into a dictionary
2. Get usage data from [today](#get-usage-data-for-today) or [past 7 days](#get-data-for-past-7-days) and parse as `dictionary`
3. Multiply to get the following cost:
    - total_cache_created_cost = cacheCreationTokens * cache_creation_input_token_cost
    - total_cache_read_cost = cacheReadTokens * cache_read_input_token_cost
    - total_input_cost = inputTokens * input_cost_per_token
    - total_output_cost = outputTokens * output_cost_per_token
4. Insert costs into rolling 7 day metrics, using rules from [metrics storage rules](#metrics-storage-rules)
    - Ensure all columns are present