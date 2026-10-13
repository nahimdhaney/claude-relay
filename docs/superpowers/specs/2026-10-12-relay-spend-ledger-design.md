# Relay spend ledger: design

Date: 2026-10-12. Target release: v0.3.0.

## Problem

`pick` ranks profiles by the plan usage that the statusline saves. A profile
used only through `forward` never runs the statusline (`claude -p` does not
run it), so it stays "no data" with the neutral score (`unknown_score`, 50).
When two or more profiles have no data, they tie, and `choose_profile` keeps
the first one in pool order. Every relay task then lands on the same account
until it runs out, even though another account sits idle.

## Goal

Spread relay work across accounts without measured usage, using what
`forward` can see itself: the cost and token counts that `claude -p` reports
when asked for JSON output.

Success criteria:

- With two no-data profiles, consecutive `forward` runs alternate between
  them (the one with less recent relay spend wins).
- A profile with real measured usage keeps its measured score. The ledger never
  overrides a real percentage; it only breaks ties.
- `forward` output, exit code and error behavior stay the same for the caller.
- The ledger never stores task or result text.

Non-goals: estimating plan percentages from cost, showing dollar amounts in
the text `status` table, or measuring interactive sessions (the statusline
already does that).

## Part 1: capture in `forward`

`forward` runs the child with `--output-format json` instead of `text`.

- The child no longer `exec`s inside the subshell with its stdout going straight
  to the caller. Its stdout goes to a private temporary file created with
  `mktemp` inside `$STATE_DIR/tasks/` (mode 600, deleted by the same EXIT trap
  that deletes the task file). Its stderr still goes straight to the caller.
- After the child exits, `forward` parses the file with one jq call:
  - Valid JSON object with a string `.result`: print `.result` followed by a
    newline to stdout (this matches what `--output-format text` printed).
  - `.is_error == true`: print `.result` (if any) the same way, and print
    `claude-relay: the child reported an error (<subtype>).` to stderr.
  - Anything else (not JSON, not an object, empty): copy the file to stdout
    unchanged and record nothing.
- `forward` exits with the child's exit code in every case.
- Recording happens for new tasks and for `--continue`, and for `is_error`
  results too (an error run still spent quota). A failure to write the record
  prints a warning to stderr and never changes the exit code or the output.

Timing is unchanged: `text` mode also printed only at the end.

## Part 2: the ledger

One file per run:

```
~/.local/state/claude-relay/spend/<profile>/<session>-<epoch>.json
```

Directories 700 (`private_dir`), files 600 (`atomic_json`). Contents:

```json
{"profile":"personal2","session_id":"2b4c…","at":1791842414,
 "cost_usd":0.0412,"is_error":false,
 "models":{"claude-haiku-5-5":{"in":2,"out":40,"cache_read":11054,"cache_write":17802}}}
```

- `cost_usd` is `.total_cost_usd` when it is a non-negative number, else `null`.
- `models` maps each key of `.modelUsage` to its `inputTokens`, `outputTokens`,
  `cacheReadInputTokens`, `cacheCreationInputTokens` (missing or non-numeric
  values become 0). Missing `.modelUsage` gives `{}`.
- `session_id` is the session `forward` assigned or resumed (not the child's
  self-reported one), so the name is always a validated UUID.
- Only numbers, model names, the profile name and the session ID are stored.
  Never task text, result text, `permission_denials`, or anything else from the
  child's output.

One file per run means concurrent `forward` runs never write the same file.

Pruning: `forward` deletes ledger files older than 7 days (by mtime, with the
`touch -t` cutoff + `find ! -newer` pattern already used by `prune_state`)
before writing its own record. `prune_state` does the same, so the ledger also
shrinks when relay is not used. Symlinked directories and files are skipped,
never followed.

## Part 3: using the ledger in `pick`

New function `relay_spend <profile>` returns, from that profile's ledger files
with `at >= now - 18000` (a rolling 5 hours):

```json
{"cost_usd":0.21,"runs":4}
```

`null` costs add 0 to `cost_usd` but still count in `runs`. Damaged files are
skipped one by one (same fallback as `captures`). No directory gives
`{"cost_usd":0,"runs":0}`.

`choose_profile` keeps its eligibility rule (`score < handoff_at`, not
excluded, directory exists). Among eligible profiles it picks the lowest key:

```
[score, relay cost in the last 5 h, relay runs in the last 5 h, pool position]
```

So a measured 30 % still beats a no-data 50 % regardless of spend; only equal
scores fall through to spend. The comparison is done in jq (costs are
fractional). The rolling window is used because no-data profiles have no known
reset time.

Every caller of `choose_profile` benefits: `forward`, `pick`, `run --pick`, and
the handoff target chosen by `stop-failure` and `guard`.

Exposure: `pick --json` and `status --json` add
`"relay_spend_5h":{"cost_usd":…,"runs":…}` to each row. The text `status`
table does not change. `cost_usd` is documented as a relative weight between
accounts, not a bill: subscription plans do not charge per run.

## Part 4: errors and compatibility

- jq 1.6 and Bash 3.2 compatible: only jq 1.6 builtins, no
  `mapfile`, no associative arrays, empty-array-safe expansions as elsewhere.
- Spend lookup must not slow the hooks noticeably: one jq call per profile over
  that profile's files, only inside `choose_profile`. The `guard` hot path calls
  `choose_profile` only when it is about to request a handoff.
- If `$STATE_DIR/spend` or a profile subdirectory is a symlink, `relay_spend`
  returns zeros and `forward` skips recording with a warning.
- Older Claude Code versions without `total_cost_usd` or `modelUsage` still
  produce records (`cost_usd: null`, `models: {}`), which count as runs.
- `uninstall --purge` already removes the whole state directory, ledger
  included. `doctor` needs no change.

## Part 5: tests

New file `tests/spend-ledger.sh`, wired into `tests/run.sh`. The fake `claude`
used by existing forward tests learns to emit a JSON result when called with
`--output-format json`, controlled by environment variables (cost, models,
`is_error`, exit code, or raw non-JSON output).

Cases:

1. Output: `.result` printed exactly as text mode did; exit code preserved for
   0 and non-zero; `is_error` prints the result plus the stderr note.
2. Non-JSON child output is passed through byte for byte and records nothing.
3. Record contents: fields and types above; no task or result text anywhere in
   `spend/` (grep for a marker string placed in both).
4. Permissions: `spend/`, `spend/<profile>/` are 700, records are 600.
5. `--continue` records under the recorded profile and session.
6. Tie-break: two no-data profiles, spend recorded on the first → `pick`
   returns the second; equal cost → fewer runs wins; all equal → pool order.
7. A real score still wins: a measured 30 % beats a no-data 50 % with zero spend.
8. Window: records older than 5 hours are ignored by `relay_spend`; records
   older than 7 days are pruned.
9. Damaged and symlinked ledger files are ignored; a symlinked `spend/` makes
   `forward` warn and still succeed.
10. `status --json` and `pick --json` include `relay_spend_5h`.
11. Existing forward tests updated for `--output-format json` in the child's
    argv.

Run under both `bash` and `/bin/bash` (3.2) and in CI with jq 1.6.

## Documentation

Update docs/SPEC.md (forward output handling, ledger, tie-break), docs/USAGE.md
(`relay_spend_5h` in JSON output), docs/HOW-IT-WORKS.md (the "Not measured"
note becomes "not measured as a percentage; relay spend is recorded", and the
storage table gains the `spend/` row), README FAQ "Why does an account show
no data?" (mention that relay runs are tracked for tie-breaking), and
SECURITY.md (what the ledger stores).
