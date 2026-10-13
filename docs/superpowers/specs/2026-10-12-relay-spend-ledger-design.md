# Relay spend ledger: design

Date: 2026-10-12. Target release: v0.3.0. Revised after a Codex review the
same day.

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

- Among profiles with equal scores, `forward` chooses the one with the least
  relay spend in the last 5 hours (not strict alternation: unequal task costs
  can send several tasks in a row to the same profile).
- A profile with a measured score keeps it. The ledger only orders profiles
  whose scores are equal.
- `forward` keeps its stdout contract (the child's final result text), its exit
  code and its refusal behavior. Known narrowing: see "Background results".
- The ledger never stores task or result text.

Non-goals: estimating plan percentages from cost, showing dollar amounts in
the text `status` table, or measuring interactive sessions (the statusline
already does that).

Accepted policy (from the tie-break-only design): an unknown profile (score 50)
with heavy relay spend still beats a measured 60 %. The ledger never raises a
score.

## Facts about `claude -p --output-format json`

Observed with Claude Code 2.1.296 (a new session, then `--resume` of it):

- stdout is one JSON object with `type:"result"`, `subtype` (`"success"` or an
  error subtype), `is_error` (boolean), `result` (string; may be absent on
  error subtypes), `session_id`, `total_cost_usd`, `usage` and `modelUsage`.
- On `--resume`, `total_cost_usd` and every `modelUsage.<model>` counter are
  **cumulative for the whole session**, not for the run. Example: first run
  0.00367, resumed run reported 0.00654 (its own share about 0.00287), and
  `modelUsage` input tokens went 2 → 4. `usage` is per run but has no cost.

The design therefore records per-run deltas (Part 2).

## Part 1: running the child and reading its output

### Launch

- `launch_claude` is not changed and keeps `exec` inside its nested subshell.
- `forward` adds `--output-format json` instead of `text`, and runs:

  ```bash
  status=0
  (launch_claude "$profile" child "${args[@]}") < "$task" > "$out" || status=$?
  ```

  The `|| status=$?` is required because the CLI runs under
  `set -euo pipefail`; without it a non-zero child would abort `forward` before
  the output is handled. The child's stderr still goes straight to the caller.
- `$out` is a private buffer created with `mktemp "$STATE_DIR/tasks/out-XXXXXX"`
  (mode 600 checked) after validation succeeds, and removed by the same EXIT
  trap that removes the task file. `prune_task_files` also removes `out-*`
  files older than one day, so a buffer left behind by SIGKILL or a crash does
  not keep result text for long. A child running for more than a day could lose
  its buffer; this is accepted and documented.
- Signals keep today's behavior: HUP, INT and TERM make `forward` exit 1, the
  EXIT trap removes the task and the buffer, and nothing is printed or
  recorded. The child is in the same process group and receives terminal
  signals directly. "Exit with the child's status" applies whenever `forward`
  itself was not interrupted.

### Parsing (one jq pass over the whole buffer)

The buffer is an **envelope** only when the whole stream is exactly one JSON
value (`jq -s 'length==1'`; valid JSON followed by more data is not an
envelope), that value is an object, `.type=="result"`, and `.is_error` is a
boolean. `.result` is not required.

Precedence:

1. **Envelope:** record spend (Part 2), whatever `is_error` and the exit status
   say. Then render:
   - `.result` is a string: print it followed by one newline to stdout (what
     text mode printed). An empty string prints just the newline.
   - `.is_error` is true: also print to stderr
     `claude-relay: the child reported an error (<subtype>).`, where `<subtype>`
     is `.subtype` when it is a string of `[a-z_]` characters, else `unknown`.
   - Envelope says error but exit status is 0, or says success but status is
     non-zero: render as above and exit with the status anyway.
2. **Not an envelope** (not JSON, several values, trailing garbage, wrong
   shape, empty): copy the buffer to stdout byte for byte and record nothing.

`forward` then exits with `status`.

### Background results

With `text` output, a child whose background tasks finish at exit could print
more than one result (behavior added in Claude Code 2.1.295). JSON output keeps
only the last one. Relay children run in `plan` mode by default and rarely
start background tasks, so this narrowing is accepted and documented in
USAGE.md and SPEC.md.

## Part 2: the ledger

### Per-run delta

The run's own spend is the reported cumulative totals minus the totals already
seen for that session:

- `forward` keeps the last seen totals in the session's existing record
  `forwarded/<session>.json` as
  `"totals":{"cost_usd":<n|null>,"models":{<model>:{in,out,cache_read,cache_write}}}`.
- New session: the baseline is zero, so the delta is the reported total.
- `--continue`: the delta is reported − baseline, field by field. If a field is
  missing from the baseline (older record, crash before update) or the reported
  value is lower than the baseline (counter reset, or a Claude Code version that
  reports per run), the reported value is used as is. This can over-count once;
  it never goes negative.
- After the run, the record's `totals` is replaced with the reported values.
  Records keep their existing 30-day lifetime, longer than the ledger's 7 days.

### Files

One file per run, with a unique name:

```
~/.local/state/claude-relay/spend/<profile>/<session>-<epoch>-<random>.json
```

`<random>` comes from `mktemp`, and the file is created exclusively, so two
continuations of the same session ending in the same second never overwrite
each other. Directories are 700 and files 600. Contents:

```json
{"profile":"personal2","session_id":"2b4c…","at":1791842414,
 "cost_usd":0.0029,"is_error":false,
 "models":{"claude-haiku-5-5":{"in":2,"out":3,"cache_read":15327,"cache_write":13571}}}
```

Normalization rules, applied before anything is written:

- Numbers must be finite (`isinfinite`/`isnan` are false) and in
  `0 ≤ cost ≤ 100000` USD, `0 ≤ tokens ≤ 1e12`. A cost outside those bounds
  becomes `null`, and a token count outside them becomes 0.
- `modelUsage` that is not an object gives `{}`. Entries whose value is not an
  object are skipped, and model names are kept only if they match
  `^[A-Za-z0-9._:\[\]-]{1,128}$`.
- `is_error` is copied as a boolean (the envelope guarantees it).
- `session_id` and `profile` are the values `forward` validated, never the
  child's self-reported ones.
- Only these fields are written: never task text, result text,
  `permission_denials`, or any other part of the child's output.

### Writing without errexit

Recording must not change `forward`'s output or exit status, so `forward`
calls it as `"$BASH" "$RELAY_BIN" __record-spend <profile> <session> <buffer>
>&2 || warn`. Inside an `||` context Bash disables errexit for in-process code,
which would let a failed check fall through to the rename. A separate Bash
process (the same technique as the existing `__safe` worker) starts with
`set -euo pipefail` intact, so every step (`private_dir`, building and
validating the JSON, `chmod 600`, the final link) stops the worker on its
first failure. The worker re-validates its arguments: the profile must be in
the pool, the session a lowercase UUID, and the buffer an owned regular
`out-*` file directly inside the tasks directory. It never writes to stdout.
It also updates `totals` in `forwarded/<session>.json`. When the worker fails,
`forward` prints `claude-relay: could not record relay spend.` to stderr, and
its output and exit status stay the same.

The record is written to a temporary file in the same directory and then
hard-linked (`ln`, which never overwrites) to its final name. On a name
collision the worker retries with a new random suffix, up to 5 times.

### Pruning

`record_spend` deletes ledger files older than 7 days (the `touch -t` cutoff +
`find ! -newer` pattern from `prune_state`) before writing. `prune_state`,
which is already throttled to once per 10 minutes, does the same, so the
ledger shrinks even when relay is unused. Symlinked directories and files are
skipped, never followed.

## Part 3: using the ledger in `pick`

### `relay_spend <profile>`

It returns `{"cost_usd":<n>,"runs":<n>,"complete":<bool>}` for that profile's
records from the last 5 hours (a rolling window, because no-data profiles have
no known reset time).

- Files are preselected with `find -newer <5-hour cutoff>`, so old files are
  never read. All selected files are read in one jq call, and only if that call
  fails is each file read separately (the same fallback as `captures`).
- A record counts only if it is an object, `.profile` equals the directory's
  profile, `.at` is a finite number with `now-18000 ≤ at ≤ now+60`, and
  `.cost_usd` is a finite number ≥ 0 or `null`.
- `cost_usd` sums the non-null costs. `runs` counts every valid record.
  `complete` is false when any counted record has a `null` cost.
- A missing or symlinked `spend/` or profile directory gives
  `{"cost_usd":0,"runs":0,"complete":true}`.

### Choosing

`choose_profile` keeps its eligibility rule: `score < handoff_at`, not
excluded, and the directory exists. Among eligible profiles:

1. The lowest score wins, as today.
2. If several share the lowest score: when all of them have
   `complete:true`, the lowest `cost_usd` wins, then the fewest `runs`. When any
   of them has `complete:false`, costs are not comparable, so the fewest `runs`
   wins, then the lowest `cost_usd`.
3. Remaining ties go to the first profile in pool order.

The comparison happens in jq because costs are fractional. Every caller
benefits: `forward`, `pick`, `run --pick`, and the handoff target chosen by
`guard` and `stop-failure`.

### Exposure

`pick --json` and `status --json` add
`"relay_spend_5h":{"cost_usd":…,"runs":…,"complete":…}` to each row.
`status` calls `relay_spend` itself, since it does not go through
`choose_profile`. The text `status` table does not change. The docs describe
`cost_usd` as a relative weight between accounts, not a bill: subscription
plans do not charge per run.

## Part 4: compatibility and performance

- Bash 3.2 and jq 1.6: only jq 1.6 builtins (`isinfinite`, `isnan`, `test`
  exist there), no `mapfile`, no associative arrays, and empty-array-safe
  expansions as elsewhere.
- Hot path: `guard` calls `choose_profile` only when it is about to request a
  handoff, and the ordinary guard test (score 20) does not reach it. Part 5 adds
  a benchmark of the handoff path with a populated ledger.
- Claude Code versions without `total_cost_usd` or `modelUsage` still produce
  records (`cost_usd:null`, `models:{}`). These count as runs and set
  `complete:false`.
- `uninstall --purge` already removes the whole state directory, ledger
  included. `doctor` needs no change.

## Part 5: tests

New file `tests/spend-ledger.sh`, wired into `tests/run.sh`.

Fake Claude: the existing fixture behavior (stdin capture, `exit 7` probes in
`forward-and-preview.sh` and `v022.sh`) stays exactly as it is. JSON mode is
used only when the test sets `FAKE_CLAUDE_JSON` (the envelope to print,
or a raw file) and `FAKE_CLAUDE_STATUS`. Existing forward tests are updated
only to expect `--output-format json` in the child's argv.

Tests that pick between two targets need three pool profiles, because
`forward` always excludes the current one.

Cases:

1. Output bytes: `.result` plus a newline, compared byte for byte, including an
   empty result, embedded newlines and a trailing newline in the result.
2. Exit status preserved for 0 and non-zero, including both disagreement cases
   (error envelope + status 0, success envelope + status 3).
3. An error envelope without `.result`: nothing on stdout, the stderr note,
   spend recorded.
4. Not an envelope (plain text, text without a final newline, two JSON objects,
   JSON + garbage, `{}`): byte-identical passthrough, no record.
5. Record contents and normalization: the fields above; NaN-free, bounded
   numbers; malformed `modelUsage` and entries; an invalid model name dropped.
   A marker string placed in both the task and the result appears nowhere under
   `spend/` or `forwarded/`.
6. Permissions: `spend/` and `spend/<profile>/` are 700, records are 600, and
   the buffer is 600 while it exists.
7. Deltas: a new session records the reported total. `--continue` with
   cumulative totals records reported − baseline. A missing baseline and a
   reported value below the baseline record the reported value. `totals` is
   updated after each run.
8. Unique files: two back-to-back records for the same session both survive,
   and so do two concurrent `forward` runs to the same profile.
9. Recording failure (spend directory replaced by a symlink, or an unwritable
   directory) prints the warning, and the child's stdout and status are
   unchanged.
10. Tie-break: equal scores with spend on one profile choose the other; equal
    cost goes to fewer runs; incomplete costs go to fewer runs; all equal goes
    to pool order.
11. A measured 30 % beats a no-data 50 % with zero spend, and a no-data 50 %
    with spend still beats a measured 60 %.
12. Window and pruning: records older than 5 hours are ignored, future
    timestamps and wrong-profile records are ignored, and files older than 7
    days are pruned by `forward` and by `prune_state`.
13. Damaged and symlinked ledger files are ignored without hiding valid ones.
14. Buffer cleanup: a stale `out-*` older than a day is pruned, and a fresh
    one is kept. When the child is killed by a signal (the fake runs
    `kill -TERM $$`), `forward` exits 143 and leaves no task or buffer behind.
15. `status --json` and `pick --json` include `relay_spend_5h`.
16. Benchmark: the guard handoff path with 3 profiles and 300 ledger files each
    (mostly older than 5 h) stays under 1.5 s. The existing 300 ms guard test is
    kept.

Run under both `bash` and `/bin/bash` (3.2), and in CI with jq 1.6.

## Documentation

- docs/SPEC.md: forward output handling, background-results narrowing, the
  ledger and deltas, the tie-break.
- docs/USAGE.md: `relay_spend_5h` in JSON output, the narrowing.
- docs/HOW-IT-WORKS.md: the "Not measured" note becomes "not measured as a
  percentage; relay spend is recorded and used to break ties", and the storage
  table gains the `spend/` row and the `out-*` buffers.
- README FAQ "Why does an account show no data?": mention that relay runs are
  tracked for tie-breaking.
- SECURITY.md: what the ledger stores and what it never stores.
