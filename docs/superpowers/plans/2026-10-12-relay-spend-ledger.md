# Relay Spend Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `forward` reads the child's JSON result, records per-run relay spend per profile, and `choose_profile` uses the last 5 hours of that spend to break ties between equal scores.

**Architecture:** `forward` buffers the child's stdout in a private `out-*` file, renders the final result exactly as text mode did, and hands the buffer to a strict worker process (`__record-spend`) that writes one ledger file per run under `spend/<profile>/`. A new `lib/spend.sh` owns recording, reading (`relay_spend`) and pruning. `choose_profile` collects eligible candidates and picks one in a single jq expression.

**Tech Stack:** Bash 3.2+, jq 1.6+, the existing sandboxed test harness (`tests/run.sh` plus sourced files).

**Spec:** `docs/superpowers/specs/2026-10-12-relay-spend-ledger-design.md` (read it first; this plan follows it).

## Global Constraints

- Bash 3.2 (`/bin/bash` on macOS) and jq 1.6 compatible: no `mapfile`, no associative arrays, no `${var,,}`, only jq 1.6 builtins; use `${arr[@]+"${arr[@]}"}` for possibly empty arrays.
- The CLI runs under `set -euo pipefail` and `umask 077`; library files do not set options.
- State directories 700, files 600; never follow a symlinked state directory or file.
- Never store task text or result text anywhere except the transient `out-*` buffer.
- The ledger path is `~/.local/state/claude-relay/spend/<profile>/<session>-<epoch>-<random>.json`.
- The rolling window is 18000 s (5 h). Ledger retention is 7 days (604800 s). Stale `out-*` buffers are pruned after 1 day.
- Bounds: `0 ≤ cost_usd ≤ 100000`, `0 ≤ tokens ≤ 1e12`; the model name regex is `^[A-Za-z0-9._:\[\]-]{1,128}$`.
- Commits: identity already configured; no AI co-author trailers; never `--no-verify`.
- Every test runs with both `bash tests/run.sh` and `/bin/bash tests/run.sh`.
- The version becomes `0.3.0`, and the README install line must read `git checkout v0.3.0`.

## Review Focus

1. A very large child result (about 2 MB) must come out byte-identical and not be truncated by command substitution (Task 1 adds this test).
2. A result with emoji, other multibyte UTF-8 and embedded tabs must come out byte-identical (Task 1).
3. Two `forward` runs to the same profile at the same time must both be recorded, and neither may break the other's output (Task 2).
4. A result that is only whitespace, or a `total_cost_usd` given as a string, must not crash anything: the whitespace prints as is, and the string cost becomes `null` (Tasks 1 and 2).
5. When the pool changes between the start of a run and its recording (the profile was removed), the worker warns, `forward` still exits with the child's status, and nothing is written (Task 2).

---

### Task 1: JSON child output, rendering and buffer

**Files:**
- Modify: `tests/run.sh` (fake Claude JSON mode; source the new test file at the end)
- Modify: `lib/profiles.sh` (`cmd_forward`)
- Modify: `lib/common.sh` (`prune_task_files`)
- Modify: `tests/forward-and-preview.sh`, `tests/v022.sh` (expect `json` instead of `text` in argv)
- Create: `tests/spend-ledger.sh`

**Interfaces:**
- Produces: `forward` launches the child with `-p --output-format json`; buffer `$STATE_DIR/tasks/out-XXXXXX` (600) removed at EXIT; render rules from spec Part 1.
- Produces (test helpers in `tests/spend-ledger.sh`): `envelope <file> <json>` writes a fixture, and `fwd <args...>` runs a forward from `$SANDBOX/project space` and sets `rc`, `$SANDBOX/out` and `$SANDBOX/err`.

- [ ] **Step 1: Fake Claude JSON mode.** In `tests/run.sh`, append to the fake (inside the heredoc, after the `jq ... > "$FAKE_LOG"` line):

```bash
if [ -n "${FAKE_CLAUDE_OUTPUT:-}" ]; then
  [ "${FAKE_CLAUDE_SIGNAL:-}" != TERM ] || kill -TERM $$
  cat "$FAKE_CLAUDE_OUTPUT"
  exit "${FAKE_CLAUDE_STATUS:-0}"
fi
```

The exit is conditional, so the probes that `forward-and-preview.sh` appends (stdin capture, `exit 7`) still run when the variable is unset.

- [ ] **Step 2: Write failing tests** in `tests/spend-ledger.sh` (sourced by `run.sh` after `v022.sh`):

```bash
#!/usr/bin/env bash
# Sourced by run.sh: v0.3.0 JSON child output and the relay spend ledger.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
rm -rf "$STATE/forwarded" "$STATE/exhausted" "$STATE/spend"
usage a 98; usage b 10; usage c 20
envelope() { printf '%s' "$2" > "$1"; }
fwd() {
  local t
  t=$(relay task-path)
  printf 'TASKMARKER-31\n' > "$t"
  rc=0; (cd "$SANDBOX/project space" && relay forward --task-file "$t" "$@") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
}
export FAKE_CLAUDE_OUTPUT="$SANDBOX/child.json"

# 1: argv uses json; .result + newline, byte for byte.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"line one\nline\ttwo ✓ 🐄\n","total_cost_usd":0.5,"modelUsage":{}}'
fwd
check equals "$rc" 0
check jq -e '.args[0:3]==["-p","--output-format","json"]' "$FAKE_LOG"
printf 'line one\nline\ttwo ✓ 🐄\n\n' > "$SANDBOX/expect"
check cmp -s "$SANDBOX/out" "$SANDBOX/expect"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":""}'
fwd; printf '\n' > "$SANDBOX/expect"; check cmp -s "$SANDBOX/out" "$SANDBOX/expect"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"  \n\t "}'
fwd; printf '  \n\t \n' > "$SANDBOX/expect"; check cmp -s "$SANDBOX/out" "$SANDBOX/expect"

# 2: exit status preserved, including disagreement with is_error.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
FAKE_CLAUDE_STATUS=3 fwd; check equals "$rc" 3; check equals "$(cat "$SANDBOX/out")" ok
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"partial"}'
fwd; check equals "$rc" 0
check equals "$(cat "$SANDBOX/out")" partial
check grep -qxF 'claude-relay: the child reported an error (error_max_turns).' "$SANDBOX/err"

# 3: error envelope without .result: empty stdout, stderr note; odd subtype -> unknown.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"Bad Subtype;rm","is_error":true,"total_cost_usd":0.1}'
FAKE_CLAUDE_STATUS=1 fwd
check equals "$rc" 1; check test ! -s "$SANDBOX/out"
check grep -qxF 'claude-relay: the child reported an error (unknown).' "$SANDBOX/err"

# 4: not an envelope -> byte-identical passthrough.
for raw in 'plain text' 'no newline at end' '{"type":"result","is_error":false}{"x":1}' '{"type":"result","is_error":false} garbage' '{}' '[1]'; do
  printf '%s' "$raw" > "$FAKE_CLAUDE_OUTPUT"
  fwd
  check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
done
: > "$FAKE_CLAUDE_OUTPUT"; fwd; check test ! -s "$SANDBOX/out"

# Review focus 1: about 2 MB result, byte-identical.
jq -n '{type:"result",subtype:"success",is_error:false,result:([range(0;40000)]|map("row \(.) ✓ 0123456789abcdef")|join("\n"))}' > "$FAKE_CLAUDE_OUTPUT"
fwd
jq -j .result "$FAKE_CLAUDE_OUTPUT" > "$SANDBOX/expect"; printf '\n' >> "$SANDBOX/expect"
check cmp -s "$SANDBOX/out" "$SANDBOX/expect"

# 6 (buffer part) + 14: no buffer left; killed child -> 143, task and buffer gone.
check equals "$(find "$STATE/tasks" -name 'out-*' | wc -l | tr -d ' ')" 0
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"x"}'
FAKE_CLAUDE_SIGNAL=TERM fwd
check equals "$rc" 143
check equals "$(find "$STATE/tasks" -type f | wc -l | tr -d ' ')" 0
mkdir -p "$STATE/tasks"; : > "$STATE/tasks/out-OLD123"; : > "$STATE/tasks/out-NEW123"
touch -t 200001010000 "$STATE/tasks/out-OLD123"
relay task-path > /dev/null
check test ! -e "$STATE/tasks/out-OLD123"
check test -e "$STATE/tasks/out-NEW123"
rm -f "$STATE/tasks/out-NEW123"
```

Add `source "$ROOT/tests/spend-ledger.sh"` (with a `# shellcheck source=` comment) after the `v022.sh` line in `run.sh`. Note: `fwd` with an inline `FAKE_CLAUDE_STATUS=3 fwd` sets the variable for the function call only. Bash 3.2 applies it to the function, and the fake inherits it because the variable is exported by that assignment. Verify this under `/bin/bash`; if it does not hold, use `export FAKE_CLAUDE_STATUS=3; fwd; unset FAKE_CLAUDE_STATUS`.

- [ ] **Step 3: Run and confirm the failures.** Run `bash tests/run.sh 2>&1 | grep -E 'not ok|Summary'`. Expected: the new checks fail (argv still `text`, and the stderr notes are missing).

- [ ] **Step 4: Implement in `cmd_forward`.**
  - Change `local args=(-p --output-format text)` to `local args=(-p --output-format json)`, and add `out status kind` to the `local` list.
  - Replace the tail (from `printf -v cleanup` through the launch) with:

```bash
  out=$(mktemp "$STATE_DIR/tasks/out-XXXXXX") || die 'Could not create the output buffer.'
  [ "$(file_mode "$out")" = 600 ] || { rm -f "$out"; die 'Output buffer must have mode 600.'; }
  # Cleanup begins only after all validation succeeds. Refusals retain input.
  printf -v cleanup 'rm -f %q %q' "$task" "$out"
  trap "$cleanup" EXIT
  trap 'exit 1' HUP INT TERM
  printf 'claude-relay: profile %s, session %s\n' "$profile" "$session" >&2
  status=0
  # launch_claude execs inside this nested subshell; capture its status explicitly
  # because errexit would otherwise abort before the output is handled.
  (launch_claude "$profile" child "${args[@]}") < "$task" > "$out" || status=$?
  kind=$(jq -sr '
    if length==1 and (.[0]|type)=="object" and .[0].type=="result" and (.[0].is_error|type)=="boolean"
    then .[0] | [ "envelope", ((.result|type)=="string"|tostring), (.is_error|tostring),
                  (.subtype | if type=="string" and test("^[a-z_]+$") then . else "unknown" end) ] | @tsv
    else "raw" end' "$out" 2>/dev/null) || kind=raw
  case "$kind" in
    envelope*)
      IFS=$'\t' read -r _ has_result is_error subtype <<< "$kind"
      if [ "$has_result" = true ]; then jq -sj '.[0].result' "$out"; printf '\n'; fi
      [ "$is_error" != true ] || printf 'claude-relay: the child reported an error (%s).\n' "$subtype" >&2 ;;
    *) cat "$out" ;;
  esac
  exit "$status"
```

  Declare `has_result is_error subtype` as locals too. `jq -sj` streams the string without command substitution, so large results and trailing newlines stay intact.
  - In `lib/common.sh` `prune_task_files`, change the loop to `for file in "$STATE_DIR/tasks/"task-*.txt "$STATE_DIR/tasks/"out-*; do`.

- [ ] **Step 5: Update the existing argv expectations.** `grep -rn '"text"' tests/forward-and-preview.sh tests/v022.sh` finds them; replace `"--output-format","text"` with `"--output-format","json"` in every expected argv (7 occurrences across the test files, including any in `tests/run.sh`).

- [ ] **Step 6: Run** `bash tests/run.sh` and `/bin/bash tests/run.sh`. Expected: everything passes (Summary with 0 failed).

- [ ] **Step 7: Commit.** `git add -A lib tests && git commit -m "forward: read the child's JSON result, keep the text output contract"`

### Task 2: Recording worker and ledger files

**Files:**
- Create: `lib/spend.sh`
- Modify: `bin/claude-relay` (route `__record-spend`)
- Modify: `lib/profiles.sh` (`source "$RELAY_ROOT/lib/spend.sh"` at the top; call the worker from `cmd_forward`)
- Modify: `lib/hooks.sh` (`prune_state` calls `prune_spend`)
- Test: `tests/spend-ledger.sh`

**Interfaces:**
- Consumes: the `$out` buffer and `$session` / `$profile` from Task 1's `cmd_forward`.
- Produces: `cmd_record_spend <profile> <session> <buffer>` (exit 0 when written or when the buffer is not an envelope, non-zero on failure, never writes stdout), `prune_spend` (no arguments, returns 0), and the record schema `{profile,session_id,at,cost_usd,is_error,models}`. It also updates `forwarded/<session>.json` with `.totals={cost_usd,models}` holding the reported cumulative values.

- [ ] **Step 1: Write failing tests** (append to `tests/spend-ledger.sh`):

```bash
# 5: record contents, normalization, no text anywhere.
rm -rf "$STATE/spend" "$STATE/forwarded"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"RESULTMARKER-31","total_cost_usd":0.25,
 "modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":40,"cacheReadInputTokens":11054,"cacheCreationInputTokens":17802,"costUSD":0.25},
   "bad name; rm":{"inputTokens":1},"weird":5,"neg":{"inputTokens":-3,"outputTokens":"9","cacheReadInputTokens":1e13}}}'
fwd
SIDL=$(jq -r '.args[4]' "$FAKE_LOG")
check equals "$(find "$STATE/spend/b" -name '*.json' | wc -l | tr -d ' ')" 1
RECL=$(find "$STATE/spend/b" -name '*.json')
check jq -e --arg s "$SIDL" '.profile=="b" and .session_id==$s and .cost_usd==0.25 and .is_error==false and (.at|type)=="number" and .at<=now
  and .models=={"claude-haiku-5-5":{"in":2,"out":40,"cache_read":11054,"cache_write":17802},"neg":{"in":0,"out":0,"cache_read":0,"cache_write":0}}
  and (keys==["at","cost_usd","is_error","models","profile","session_id"])' "$RECL"
check equals "$(basename "$RECL" | grep -cE "^$SIDL-[0-9]+-[A-Za-z0-9]+\.json$")" 1
check test "$(grep -rl 'TASKMARKER-31\|RESULTMARKER-31' "$STATE/spend" "$STATE/forwarded" | wc -l | tr -d ' ')" -eq 0
check jq -e '.totals.cost_usd==0.25 and .totals.models["claude-haiku-5-5"].in==2' "$STATE/forwarded/$SIDL.json"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"r","total_cost_usd":"0.5"}'
fwd
check jq -se 'map(select(.cost_usd==null and .models=={}))|length==1' "$STATE/spend/b/"*.json

# 6: permissions.
check equals "$(LC_ALL=C ls -ld "$STATE/spend" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -ld "$STATE/spend/b" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -l "$RECL" | cut -c1-10)" -rw-------

# 7: deltas on --continue.
rm -rf "$STATE/spend"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"one","total_cost_usd":1.0,"modelUsage":{"m":{"inputTokens":10,"outputTokens":5,"cacheReadInputTokens":100,"cacheCreationInputTokens":50}}}'
fwd; SIDD=$(jq -r '.args[4]' "$FAKE_LOG")
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"two","total_cost_usd":1.25,"modelUsage":{"m":{"inputTokens":14,"outputTokens":7,"cacheReadInputTokens":180,"cacheCreationInputTokens":50}}}'
fwd --continue "$SIDD"
check jq -se 'sort_by(.cost_usd)|.[0].cost_usd==0.25 and .[0].models.m=={"in":4,"out":2,"cache_read":80,"cache_write":0} and .[1].cost_usd==1' "$STATE/spend/b/"*.json
check jq -e '.totals.cost_usd==1.25 and .totals.models.m.in==14' "$STATE/forwarded/$SIDD.json"
# Lower than baseline (per-run reporting) -> reported value as is.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"three","total_cost_usd":0.1,"modelUsage":{"m":{"inputTokens":3}}}'
fwd --continue "$SIDD"
check jq -se 'map(select(.cost_usd==0.1 and .models.m.in==3))|length==1' "$STATE/spend/b/"*.json
# Missing baseline (record without totals) -> reported value.
jq 'del(.totals)' "$STATE/forwarded/$SIDD.json" > "$SANDBOX/rec" && mv "$SANDBOX/rec" "$STATE/forwarded/$SIDD.json"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"four","total_cost_usd":2.5}'
fwd --continue "$SIDD"
check jq -se 'map(select(.cost_usd==2.5))|length==1' "$STATE/spend/b/"*.json

# 8 + review focus 3: back-to-back and concurrent runs all recorded.
rm -rf "$STATE/spend"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"c","total_cost_usd":0.01}'
t1=$(relay task-path); printf 'x\n' > "$t1"; t2=$(relay task-path); printf 'y\n' > "$t2"
(cd "$SANDBOX/project space" && relay forward --task-file "$t1" > "$SANDBOX/c1" 2>/dev/null) &
(cd "$SANDBOX/project space" && relay forward --task-file "$t2" > "$SANDBOX/c2" 2>/dev/null) &
wait
check equals "$(cat "$SANDBOX/c1")$(cat "$SANDBOX/c2")" cc
check equals "$(find "$STATE/spend" -name '*.json' | wc -l | tr -d ' ')" 2

# 9 + review focus 5: recording failures warn, never change output or status.
rm -rf "$STATE/spend"; mkdir -p "$SANDBOX/elsewhere"; ln -s "$SANDBOX/elsewhere" "$STATE/spend"
FAKE_CLAUDE_STATUS=4 fwd
check equals "$rc" 4; check equals "$(cat "$SANDBOX/out")" c
check grep -qxF 'claude-relay: could not record relay spend.' "$SANDBOX/err"
check test -z "$(ls -A "$SANDBOX/elsewhere")"
rm -f "$STATE/spend"
rc=0; relay __record-spend zz "$SIDD" "$STATE/tasks/out-nope" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0; check test ! -s "$SANDBOX/out"; check test ! -e "$STATE/spend/zz"
rc=0; relay __record-spend b "$SIDD" "$SANDBOX/child.json" 2>/dev/null || rc=$?
check test "$rc" -ne 0

# 12 (pruning part): files older than 7 days are pruned by forward and prune_state.
mkdir -p "$STATE/spend/c"; printf '{}' > "$STATE/spend/c/old.json"; touch -t 200001010000 "$STATE/spend/c/old.json"
fwd; check test ! -e "$STATE/spend/c/old.json"
printf '{}' > "$STATE/spend/c/old2.json"; touch -t 200001010000 "$STATE/spend/c/old2.json"
rm -f "$STATE/prune.json"; relay statusline < "$ROOT/tests/fixtures/statusline.json" > /dev/null
check test ! -e "$STATE/spend/c/old2.json"
```

- [ ] **Step 2: Run and confirm the failures** (no `spend/` is written, and `__record-spend` is an unknown subcommand).

- [ ] **Step 3: Create `lib/spend.sh`:**

```bash
#!/usr/bin/env bash
# Relay spend ledger: one private record per forward run, used to break ties.
SPEND_WINDOW=18000 SPEND_RETENTION=604800

# Delete ledger files (and stale temporaries) older than the retention period.
prune_spend() (
  local cutoff
  [ -d "$STATE_DIR/spend" ] && [ ! -L "$STATE_DIR/spend" ] || return 0
  cutoff=$(mktemp "$STATE_DIR/.spend-prune.XXXXXX") || return 0
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr --argjson r "$SPEND_RETENTION" 'now-$r | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff"
  find "$STATE_DIR/spend" -mindepth 2 -maxdepth 2 -type f ! -newer "$cutoff" -exec rm -f {} + 2>/dev/null || true
)

# Runs as its own strict process (bin/claude-relay __record-spend), so errexit
# holds even though forward calls it in an || context. Never writes stdout.
cmd_record_spend() {
  [ "$#" -eq 3 ] || die 'Usage: __record-spend <profile> <session> <buffer>'
  local profile=$1 session=$2 buffer=$3 tasks parent dir record base tmp final epoch tries=0 entry totals
  exec 1>&2
  load_pool
  profile_dir "$profile" >/dev/null
  valid_session_id "$session" || die 'Invalid session ID.'
  tasks=$(resolve_dir "$STATE_DIR/tasks") || die 'No tasks directory.'
  parent=$(resolve_dir "${buffer%/*}") || die 'Invalid buffer.'
  [ "$parent" = "$tasks" ] || die 'Buffer must be inside the tasks directory.'
  case "${buffer##*/}" in out-*) ;; *) die 'Invalid buffer name.' ;; esac
  buffer="$parent/${buffer##*/}"
  [ ! -L "$buffer" ] && [ -f "$buffer" ] && [ -O "$buffer" ] || die 'Buffer must be an owned regular file.'
  jq -se 'length==1 and (.[0]|type)=="object" and .[0].type=="result" and (.[0].is_error|type)=="boolean"' "$buffer" >/dev/null 2>&1 || return 0
  [ ! -L "$STATE_DIR/forwarded" ] || die 'Symlink directory rejected.'
  record="$STATE_DIR/forwarded/$session.json"
  totals='null'
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    totals=$(jq -c '.totals // null' "$record" 2>/dev/null) || totals='null'
  fi
  epoch=$(jq -nr 'now|floor')
  # entry = [ledger record, new cumulative totals]
  entry=$(jq -sc --arg p "$profile" --arg s "$session" --argjson at "$epoch" --argjson base "$totals" '
    def num($max): if type=="number" and (isinfinite|not) and (isnan|not) and .>=0 and .<=$max then . else null end;
    def tok: num(1e12) // 0;
    def less($b): if ($b|type)=="number" and . >= $b then . - $b else . end;
    .[0] as $r |
    {cost_usd:($r.total_cost_usd|num(100000)),
     models:(($r.modelUsage | if type=="object" then . else {} end) | to_entries
       | map(select((.key|test("^[A-Za-z0-9._:\\[\\]-]{1,128}$")) and (.value|type)=="object")
             | {key, value:{in:(.value.inputTokens|tok),out:(.value.outputTokens|tok),
                            cache_read:(.value.cacheReadInputTokens|tok),cache_write:(.value.cacheCreationInputTokens|tok)}})
       | from_entries)} as $now |
    ($base // {}) as $b |
    [{profile:$p, session_id:$s, at:$at,
      cost_usd:(if $now.cost_usd==null then null else ($now.cost_usd|less($b.cost_usd)) end),
      is_error:$r.is_error,
      models:($now.models | with_entries(.key as $k | .value |= with_entries(.key as $f | .value |= less($b.models[$k][$f]))))},
     $now]' "$buffer")
  dir="$STATE_DIR/spend/$profile"
  private_dir "$dir"
  prune_spend
  tmp=$(mktemp "$dir/.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s' "$entry" | jq -c '.[0]' > "$tmp"
  jq -e 'type=="object"' "$tmp" >/dev/null
  chmod 600 "$tmp"
  while :; do
    final="$dir/$session-$epoch-$RANDOM$RANDOM.json"
    if ln "$tmp" "$final" 2>/dev/null; then break; fi
    tries=$((tries+1)); [ "$tries" -lt 5 ] || die 'Could not allocate a ledger file name.'
  done
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    jq -c --argjson t "$(printf '%s' "$entry" | jq -c '.[1]')" 'select(type=="object") | .totals=$t' "$record" | atomic_json "$record"
  fi
}
```

  The `$b.models[$k][$f]` lookup in `less` works because `less` receives the baseline value as an argument. A missing baseline gives `null`, and `less(null)` returns the reported value. Verify this on jq 1.6 (`$JQ16` in the scratchpad, or CI).

- [ ] **Step 4: Wire it up.**
  - In `bin/claude-relay`, add a case before `*)`: `__record-spend) source "$RELAY_ROOT/lib/profiles.sh"; cmd_record_spend "$@" ;;`. `profiles.sh` sources `spend.sh`, and `init_config` already runs for every command except `forward`.
  - At the top of `lib/profiles.sh`, after the shebang: `# shellcheck source=lib/spend.sh` and `source "$RELAY_ROOT/lib/spend.sh"`.
  - In `cmd_forward`, between the `case "$kind"` block and `exit "$status"`:

```bash
  # Recording never changes the child's output or exit status.
  "$BASH" "$RELAY_BIN" __record-spend "$profile" "$session" "$out" >&2 ||
    printf 'claude-relay: could not record relay spend.\n' >&2
```

  `$RELAY_BIN` is set by `bin/claude-relay`. The worker exits 0 without writing when the buffer is not an envelope, so raw output records nothing.
  - In `lib/hooks.sh` `prune_state`, call `prune_spend` right after `prune_task_files`.

- [ ] **Step 5: Run** both Bash versions. Expected: all pass.

- [ ] **Step 6: Commit.** `git add -A lib bin tests && git commit -m "Record per-run relay spend in a private ledger"`

### Task 3: `relay_spend`, the tie-break, and JSON exposure

**Files:**
- Modify: `lib/spend.sh` (add `relay_spend`)
- Modify: `lib/profiles.sh` (`choose_profile`, `cmd_status`)
- Test: `tests/spend-ledger.sh`

**Interfaces:**
- Consumes: ledger files from Task 2.
- Produces: `relay_spend <profile>` prints `{"cost_usd":N,"runs":N,"complete":B}`. After `choose_profile`, `PICKED_METRICS` contains `relay_spend_5h`. Every `status --json` row has `relay_spend_5h`.

- [ ] **Step 1: Write failing tests** (append):

```bash
# Helper: write a ledger record for profile $1 with cost $2 (or null) at age $3 seconds.
spend_rec() {
  mkdir -p "$STATE/spend/$1"; chmod 700 "$STATE/spend" "$STATE/spend/$1"
  jq -n --arg p "$1" --argjson c "$2" --argjson age "$3" '{profile:$p,session_id:"00000000-0000-4000-8000-000000000000",at:(now-$age|floor),cost_usd:$c,is_error:false,models:{}}' \
    > "$STATE/spend/$1/r-$RANDOM$RANDOM.json"
}
rm -rf "$STATE/spend" "$STATE/usage"; mkdir -p "$STATE/usage"
# a is current (excluded by forward); b and c have no data (score 50).
usage a 98
rm -f "$STATE/usage/b.json" "$STATE/usage/c.json"
# 10: tie-break.
spend_rec b 0.30 60
check equals "$(relay pick --exclude a)" c
spend_rec c 0.30 60
check equals "$(relay pick --exclude a)" b
spend_rec b 0.0 60
check equals "$(relay pick --exclude a)" c
spend_rec c null 60
check equals "$(relay pick --exclude a)" b
rm -rf "$STATE/spend"; check equals "$(relay pick --exclude a)" b
# 11: a measured score wins over the ledger.
usage c 30; spend_rec c 5 60
check equals "$(relay pick --exclude a)" c
usage c 60; rm -f "$STATE/usage/b.json"; spend_rec b 9 60
check equals "$(relay pick --exclude a)" b
rm -f "$STATE/usage/c.json"
# 12 (window) + 13: old, future, wrong-profile, damaged and symlinked records are ignored.
rm -rf "$STATE/spend"
spend_rec b 1 20000
spend_rec b 1 -3600
mkdir -p "$STATE/spend/b"; jq -n '{profile:"c",at:now,cost_usd:1}' > "$STATE/spend/b/wrong.json"
printf '{broken' > "$STATE/spend/b/broken.json"
printf '{"profile":"b","at":1e999,"cost_usd":1}' > "$STATE/spend/b/huge.json"
jq -n '{profile:"b",at:now,cost_usd:1}' > "$SANDBOX/outside.json"; ln -s "$SANDBOX/outside.json" "$STATE/spend/b/link.json"
spend_rec b 0.2 60
relay status --json > "$SANDBOX/st"
check jq -e '.[] | select(.profile=="b") | .relay_spend_5h=={"cost_usd":0.2,"runs":1,"complete":true}' "$SANDBOX/st"
check jq -e '.[] | select(.profile=="c") | .relay_spend_5h=={"cost_usd":0,"runs":0,"complete":true}' "$SANDBOX/st"
# 15: pick --json carries it.
relay pick --exclude a --json > "$SANDBOX/pk"
check jq -e '.profile=="c" and .relay_spend_5h.runs==0' "$SANDBOX/pk"
# Symlinked spend directory -> zeros.
mv "$STATE/spend" "$SANDBOX/spend-real"; ln -s "$SANDBOX/spend-real" "$STATE/spend"
relay status --json > "$SANDBOX/st"
check jq -e 'all(.[]; .relay_spend_5h.runs==0)' "$SANDBOX/st"
rm -f "$STATE/spend"; rm -rf "$SANDBOX/spend-real"
```

- [ ] **Step 2: Run and confirm the failures.**

- [ ] **Step 3: Add `relay_spend` to `lib/spend.sh`:**

```bash
# Relay spend of one profile over the last 5 hours: {cost_usd, runs, complete}.
relay_spend() (
  local profile=$1 dir="$STATE_DIR/spend/$1" cutoff file files=() count=0 data
  local zero='{"cost_usd":0,"runs":0,"complete":true}'
  local filter='def ok: type=="object" and .profile==$p and (.at|type)=="number" and .at>=now-$w and .at<=now+60
      and (.cost_usd==null or ((.cost_usd|type)=="number" and .cost_usd>=0 and .cost_usd<=100000));'
  if [ -L "$STATE_DIR/spend" ] || [ -L "$dir" ] || [ ! -d "$dir" ]; then printf '%s\n' "$zero"; return 0; fi
  cutoff=$(mktemp "$STATE_DIR/.spend-window.XXXXXX") || { printf '%s\n' "$zero"; return 0; }
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr --argjson w "$SPEND_WINDOW" 'now-$w-60 | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff"
  while IFS= read -r -d '' file; do
    [ ! -L "$file" ] || continue
    files[$count]=$file; count=$((count+1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.json' -newer "$cutoff" -print0 2>/dev/null)
  if [ "$count" -eq 0 ]; then printf '%s\n' "$zero"; return 0; fi
  if ! data=$(jq -cn --arg p "$profile" --argjson w "$SPEND_WINDOW" "$filter"'[inputs|select(ok)]' "${files[@]}" 2>/dev/null); then
    data=$(for file in "${files[@]}"; do
      jq -c --arg p "$profile" --argjson w "$SPEND_WINDOW" "$filter"'select(ok)' "$file" 2>/dev/null || true
    done | jq -cs .)
  fi
  printf '%s' "$data" | jq -c '{cost_usd:(map(.cost_usd // 0)|add // 0), runs:length, complete:all(.[]; .cost_usd!=null)}'
)
```

  `find -type f` without `-L` never follows symlinks. The mtime preselection uses a cutoff 60 s older than the window, and `.at` is the authoritative filter.

- [ ] **Step 4: Replace `choose_profile` in `lib/profiles.sh`:**

```bash
choose_profile() {
  local i=0 name dir m x skip cands='[]' spend picked
  while [ "$i" -lt "$POOL_COUNT" ]; do
    name=${POOL_NAMES[$i]} dir=${POOL_DIRS[$i]} i=$((i+1))
    [ -d "$dir" ] || continue
    skip=false
    for x in "$@"; do [ "$name" != "$x" ] || skip=true; done
    $skip && continue
    m=$(measurement "$name")
    jq -en --argjson m "$m" --argjson h "$HANDOFF_AT" '$m.score<$h' >/dev/null || continue
    spend=$(relay_spend "$name")
    cands=$(jq -cn --argjson c "$cands" --arg n "$name" --argjson m "$m" --argjson s "$spend" --argjson i "$i" \
      '$c+[{name:$n,i:$i,m:($m+{relay_spend_5h:$s})}]')
  done
  # Lowest score; ties by relay spend in the last 5 h (runs first when a cost is missing); then pool order.
  picked=$(printf '%s' "$cands" | jq -c '
    if length==0 then empty else
      (map(.m.score)|min) as $low | map(select(.m.score==$low)) as $t |
      ($t|all(.[]; .m.relay_spend_5h.complete)) as $costs |
      $t | min_by(.m.relay_spend_5h as $s | if $costs then [$s.cost_usd,$s.runs,.i] else [$s.runs,$s.cost_usd,.i] end)
    end')
  [ -n "$picked" ] || { printf 'claude-relay: no eligible profiles.\n' >&2; return 3; }
  PICKED=$(printf '%s' "$picked" | jq -r .name)
  PICKED_METRICS=$(printf '%s' "$picked" | jq -c .m)
}
```

  In `cmd_status`, change the row builder to add `relay_spend_5h`: compute `spend=$(relay_spend "$name")` (declare `spend` local) and append `+{relay_spend_5h:$s}` with `--argjson s "$spend"`.

- [ ] **Step 5: Add the benchmark test** (review item 16 in the spec). Append it, reusing the guard setup that `tests/exhaustion-and-hooks.sh` uses to reach the handoff branch (score ≥ 97 for profile `a`, with a transcript at `$SOURCE`). Read that file for the exact setup lines and copy them instead of inventing new ones:

```bash
# 16: guard handoff path with a populated ledger stays fast.
rm -rf "$STATE/spend" "$STATE/warned"
for p in a b c; do
  mkdir -p "$STATE/spend/$p"; n=0
  while [ "$n" -lt 300 ]; do
    jq -n --arg p "$p" '{profile:$p,at:(now-90000),cost_usd:0.1}' > "$STATE/spend/$p/old-$n.json"; n=$((n+1))
  done
  touch -t 200001010000 "$STATE/spend/$p/"old-*.json
  spend_rec "$p" 0.1 60
done
usage a 98
guard_input > "$SANDBOX/guard16"
started=$(jq -nr now)
relay hook guard < "$SANDBOX/guard16" > "$SANDBOX/out16"
elapsed=$(jq -nr --argjson start "$started" '(now-$start)*1000')
check jq -e '.hookSpecificOutput.additionalContext|test("handoff")' "$SANDBOX/out16"
check jq -en --argjson ms "$elapsed" --argjson budget "${CLAUDE_RELAY_TEST_HANDOFF_MS:-1500}" '$ms<$budget'
rm -rf "$STATE/spend"
```

  If `guard` needs other setup to reach the handoff branch (for example `SOURCE` pointing at an existing transcript), copy it from `exhaustion-and-hooks.sh`. The first check confirms that the handoff branch really ran.

- [ ] **Step 6: Run** both Bash versions, plus the jq 1.6 binary when available: `PATH="<dir containing jq 1.6>:$PATH" bash tests/run.sh`. Expected: all pass, except possibly the known 300 ms latency check under Rosetta.

- [ ] **Step 7: Commit.** `git add -A lib tests && git commit -m "pick: break score ties by relay spend in the last 5 hours"`

### Task 4: Docs and version 0.3.0

**Files:**
- Modify: `VERSION` (`0.3.0`), `README.md` (install line `v0.3.0`, FAQ "Why does an account show no data?")
- Modify: `docs/SPEC.md`, `docs/USAGE.md`, `docs/HOW-IT-WORKS.md`, `SECURITY.md`, `AGENTS.md` (only if it names the version tag)
- Test: the existing release/README tests in `tests/release.sh`

- [ ] **Step 1: Write the docs,** following the "Documentation" section of the spec. The text must cover:
  - SPEC.md: `forward` runs the child with `--output-format json`; the render rules (envelope definition, result plus newline, the stderr error note, raw passthrough); the background-results narrowing; the ledger path, schema, deltas, retention and window; the `choose_profile` order; `relay_spend_5h` in the JSON output.
  - USAGE.md: `relay_spend_5h` in `status --json` and `pick --json`, described as a relative weight between accounts, not a bill; the narrowing.
  - HOW-IT-WORKS.md: in "What `claude -p` is", replace the "Not measured" bullet with "Not measured as a percentage: the statusline does not run, but `forward` records each run's cost and uses it to break ties between accounts with equal scores." Add the rows `spend/<profile>/*.json` ("Cost and token counts of each relay run; never text", "7 days") and `tasks/out-*` ("The child's output while forward runs", "Deleted when forward ends; stale ones after a day") to the storage table. In the relay sequence diagram, change `C-->>F: result text` to `C-->>F: JSON result (text, cost)` and add `F->>F: record cost in spend/` after it.
  - README FAQ: add "Relay runs are not measured as a percentage either, but their cost is recorded, so `pick` spreads relay work across accounts without data."
  - SECURITY.md: the ledger stores only the profile, the session ID, a timestamp, the cost, the error flag and token counts per model; it never stores task or result text; the `out-*` buffer holds the result text only while `forward` runs.
- [ ] **Step 2: Bump the version.** `printf '0.3.0\n' > VERSION`, and update the README install line to `git checkout v0.3.0`.
- [ ] **Step 3: Run** both Bash versions. Expected: all pass, including the README/version tests.
- [ ] **Step 4: Commit.** `git add -A && git commit -m "v0.3.0: document the relay spend ledger"`
