---
name: clean-bash-scripting
description: Use when writing, reviewing, or refactoring bash scripts that run unattended (cron, background processes, daemons), use awk for formatting or calculation, or produce visual/tabular output in monospace fonts. Apply when code has duplicated awk blocks, repeated file reads, multiple awk spawns on the same inputs, hardcoded column widths, or dead functions.
---

# Clean Bash Scripting

## Overview

Unattended scripts have no interactive error channel — silent failures show stale output. Clean scripts fail loudly, deduplicate logic via shared helpers, avoid subshell traps, and derive visual alignment from data rather than hardcoded widths.

---

## Strict Mode

Add near the top of every script. Prepend tool directories first if the script runs outside a login shell (cron, launchd, daemons):

```bash
export PATH="/usr/local/bin:$PATH"   # omit if tools are on the default PATH
set -euo pipefail
```

Guard intentional non-zero exits with `|| true` or `|| { handler; }`.

**`set -e` exemptions** (these do NOT trigger exit even on failure):
- Commands inside `if` / `while` conditions
- Non-final commands in `&&` / `||` lists
- Commands negated with `!`

---

## Quoting

Always double-quote variable expansions. Unquoted `$var` causes word splitting and glob expansion.

```bash
# ✗ — breaks on spaces or globs
for f in $files; do cp $f $dest; done

# ✓
for f in "${files[@]}"; do cp "$f" "$dest"; done
```

---

## `printf` over `echo`

`echo` behavior with `-e`, `-n` flags varies across shells and macOS/Linux. Use `printf` for all formatted output.

```bash
# ✗
echo -e "line1\nline2"

# ✓
printf 'line1\nline2\n'
```

---

## Integer Arithmetic — Avoid awk for Simple Math

`$(( ))` is arithmetic expansion — it runs in the current shell, unlike `$(command)` which spawns a subshell:

```bash
# ✗ — spawns awk for addition
total=$(awk -v a="$X" -v b="$Y" 'BEGIN{print a+b}')

# ✓ — builtin
total=$(( X + Y ))
```

Use awk only for float arithmetic or when already in an awk context.

---

## Atomic Writes

Never write directly to files read by other processes:

```bash
tmp="$TARGET.tmp"
generate_content > "$tmp"
mv "$tmp" "$TARGET"   # atomic — no partial-read window
```

---

## Trap for Tmp File Cleanup

`set -e` can exit mid-write, leaving `.tmp` files. Register cleanup upfront:

```bash
TMP_FILE="$DATA_DIR/output.tmp"
trap 'rm -f "$TMP_FILE"' EXIT

# Now tmp is always cleaned up, even on error
generate > "$TMP_FILE" && mv "$TMP_FILE" "$TARGET"
```

---

## Process Substitution — Avoid Subshell Variable Loss

Variables set inside a pipeline subshell are lost after the pipe:

```bash
# ✗ — $result is empty after this; the read ran in a subshell
command | read -r result

# ✓ — read runs in the current shell
read -r result < <(command)
```

Same issue with `while read` loops that need to set outer variables.

---

## Combining awk Spawns

Multiple awk calls on the same inputs → one call, split with parameter expansion:

```bash
# ✗ — two processes
A=$(awk -v x="$X" 'BEGIN{printf "%d", x+1}')
B=$(awk -v y="$Y" 'BEGIN{printf "%d", y+1}')

# ✓ — one process, split on space
pair=$(awk -v x="$X" -v y="$Y" 'BEGIN{printf "%d %d", x+1, y+1}')
A="${pair% *}"   # everything before the space
B="${pair#* }"   # everything after the space
```

---

## Eliminating Duplicate File Reads

Two sequential passes over the same file → one awk pass, two outputs:

```bash
# ✗ — two separate tail reads of the same file
read_first_row() { IFS=',' read -r id name val < <(tail -n +2 "$CSV" | head -1); }
read_totals()    { tail -n +2 "$CSV" | awk '{ s+=$2 } END { print s }'; }

# ✓ — one read, two outputs separated by newline
read_metrics() {
  local data
  data=$(tail -n +2 "$CSV" | awk -F',' '
    NR==1 { first=$0 }
    { s+=$2+0 }
    END { print first; printf "%d\n", s }
  ')
  # $() strips trailing newlines — these reliably split line 1 and line 2
  IFS=',' read -r id name val <<< "${data%%$'\n'*}"   # first line
  total="${data##*$'\n'}"                              # last line
}
```

---

## Shared Awk Functions (Injection Pattern)

When the same awk logic appears in multiple `awk` invocations, extract to a shell variable and inject:

```bash
_AWK_HELPERS='
function fmt_number(n,   v,ip,dp) {
  if (n >= 1000000) {
    v = n / 1000000; ip = int(v); dp = int((v - ip) * 10 + 0.5)
    if (dp >= 10) { ip++; dp = 0 }
    return ip "." dp "m"        # add commify(ip) if thousands separator needed
  } else if (n >= 500) {
    return int(n / 1000 + 0.5) "k"
  } else { return int(n) }
}
function fmt_currency(v,   d,c) {
  d = int(v); c = int((v - d) * 100 + 0.5)
  if (c >= 100) { d++; c = 0 }
  return "$" d "." sprintf("%02d", c)  # use commify(d) for thousands separator
}
'

# Inject into any awk program — extra params after actual args are awk function-locals
awk "$_AWK_HELPERS"' NF { print fmt_number($2), fmt_currency($3) }'
```

---

## Repeated Pattern Helper

Four near-identical loops → one function:

```bash
max_len() { local m=0 l; for l in "$@"; do [ "${#l}" -gt "$m" ] && m="${#l}"; done; echo "$m"; }

max_a=$(max_len "$lbl1" "$lbl2" "$lbl3")
max_b=$(max_len "$lbl4" "$lbl5" "$lbl6")
```

---

## Visual Alignment — Two-Pass Pattern

Column widths must come from actual data — never hardcoded. Use two passes: compute labels and max widths first, render second.

```bash
# Pass 1 — compute labels and widths
lbl_a=$(format_number "$VAL_A"); cost_a=$(format_currency "$COST_A")
lbl_b=$(format_number "$VAL_B"); cost_b=$(format_currency "$COST_B")
max_n=$(max_len "$lbl_a" "$lbl_b")
max_c=$(max_len "$cost_a" "$cost_b")
col_width=$(( max_n + 3 + max_c ))   # "42k ($0.05)" = n + " (" (2) + cost + ")" (1)

# Pass 2 — render with exact padding
printf '%-*s  %-*s\n' "$c1" "Row A" \
  "$col_width" "$(printf "%-${max_n}s" "$lbl_a") ($cost_a)"
```

### Alignment Reference

| Situation | Format |
|---|---|
| Left-align label | `%-${max_n}s` |
| Right-align currency | `%${max_c}s` |
| Derive column width | `col=$(( max_n + 3 + max_c ))` — count separator chars literally |
| Bar chart right padding | Append fixed empty-fill chars after proportional fill |

### Two-Pass in Awk

```awk
END {
  for (r = 1; r <= NR; r++) {          # Pass 1: compute + track max
    lbl[r] = fmt_number(val[r])
    if (length(lbl[r]) > maxl) maxl = length(lbl[r])
  }
  for (r = 1; r <= NR; r++) {          # Pass 2: render with padding
    printf "%-" maxl "s\n", lbl[r]
  }
}
```

---

## Global Constants vs Per-Function Locals

Strings reused across functions belong at the top level:

```bash
# ✓
DATE_FMT='+%Y-%m-%d'
SEPARATOR='──────────────'

# ✗ — duplicated in every function that uses them
render_a() { local sep='──────────────'; printf '%s\n' "$sep"; ... }
render_b() { local sep='──────────────'; printf '%s\n' "$sep"; ... }
```

---

## SCRIPT_DIR Pattern

For scripts that may be symlinked or called from any working directory:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
```

Never use relative paths directly — they resolve from the caller's `$PWD`.

---

## Error Output to Stderr

Error and warning messages must go to stderr, not stdout. Stdout is for data; mixing them corrupts captured output.

```bash
# ✗ — pollutes stdout capture
echo "Error: file not found"

# ✓
printf 'Error: file not found\n' >&2
printf 'Warning: %s\n' "$msg" >&2
```

---

## Dead Code Checklist

Remove immediately:

- Functions defined but never called
- Variables assigned but never referenced
- `local var=""` inside a function — `local var` already initializes to `""` (redundant only in function scope; resetting in a loop body is still needed if the assignment is conditional)
- `BEGIN { x=0 }` in awk — awk zero-initializes numeric variables
- Redundant `2>/dev/null` on commands guaranteed to succeed

---

## Tooling

Run [ShellCheck](https://www.shellcheck.net) before committing. It catches quoting issues, subshell variable loss, unset variable references, and `set -e` interaction bugs that are easy to miss in review.

```bash
shellcheck script.sh
```
