# Relay child usage: design

Date: 2026-10-13. Target release: v0.4.0.

## Problem

Profiles used only through `forward` stay "no data" (score 50), because quota
percentages were believed to reach only the interactive statusline. The v0.3.0
spend ledger only breaks ties between them.

## Fact (verified with Claude Code 2.1.296)

`claude -p --output-format stream-json --verbose` prints one JSON object per
line. Among them is a `rate_limit_event`:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791909600,
 "rateLimitType":"five_hour","unifiedWindows":{
   "five_hour":{"utilization":0.06,"resetsAt":1791909600},
   "seven_day":{"utilization":0.34,"resetsAt":1791932400}}},"session_id":"…"}
```

`utilization` is a fraction from 0 to 1. On the same account at the same time,
the statusline reported `five_hour.used_percentage` 6 and `seven_day` 34, with
identical reset times. Team seats send only `five_hour`. The last line is the
same `result` object that `--output-format json` prints.

## Goal

Every relay run updates the child profile's measured quota exactly as an
interactive reply would. `pick` then compares real percentages, and the spend
ledger stays as the tie-break. Output, exit status and the spend ledger behave
as in v0.3.0.

## Design

### 1. Child output format

`forward` passes `--output-format stream-json --verbose` instead of
`--output-format json`. Nothing else in the argv changes.

### 2. Parsing the buffer

The buffer is a **stream** when the whole buffer parses as a sequence of JSON
values (`jq -s` succeeds), it holds at least one value, and every value is an
object with a string `.type`. A single JSON object with a string `.type` is
therefore a stream of one, so v0.3.0 single-envelope buffers keep working.

- The **envelope** is the last value with `.type=="result"` and a boolean
  `.is_error`. Rendering, the stderr error note and spend recording are exactly
  as in v0.3.0, applied to that value.
- A stream without an envelope prints nothing on stdout, prints
  `claude-relay: the child ended without a result.` on stderr, records no spend,
  and still records usage (see 3).
- Not a stream: byte-identical passthrough, record nothing (as v0.3.0).
- `forward` always exits with the child's status.

### 3. Recording usage

The **usage event** is the last value with `.type=="rate_limit_event"` whose
`.rate_limit_info.unifiedWindows` is an object. From it, for each of
`five_hour` and `seven_day` that is an object with a finite numeric
`utilization` and a finite numeric `resetsAt ≥ 0`, build
`{used_percentage: clamp(utilization*100, 0, 100) rounded to 2 decimals,
resets_at: resetsAt}`. Windows that fail validation are omitted. If neither
window is valid, nothing is recorded.

The capture has the same shape as a statusline capture, plus a source marker:

```json
{"profile":"personal2","captured_at":<now>,"session_id":"<forward's session>",
 "model":null,"source":"relay","rate_limits":{"five_hour":{…},"seven_day":{…}}}
```

It is stored with the existing `store_capture` (lock, legacy copy, pruning),
with `CURRENT_PROFILE` set to the child profile, so it lands in
`usage/<child profile>/<session>.json` and is read by `measurement` like any
other capture. `session_id` is the session `forward` assigned or resumed (a
validated UUID), never the child's self-reported one.

If `.rate_limit_info.status` is `"rejected"` and `resetsAt` is a finite number
in the future, also mark the child profile exhausted until `resetsAt` (the
existing `mark_exhausted <profile> relay until <epoch>`), so `pick` skips it.

### 4. The worker

The v0.3.0 worker `__record-spend` becomes `__record-run <profile> <session>
<buffer>` (internal command, no compatibility needed). It keeps every v0.3.0
validation and the strict-process rule, records spend from the envelope when
there is one, then records usage from the usage event when there is one. A
failure in either part makes the worker exit non-zero after attempting the
other part; `forward` prints `claude-relay: could not record relay run data.`
and its output and status stay unchanged. The worker never writes stdout.
`forward` calls the worker whenever the buffer is a stream (with or without an
envelope).

### 5. Privacy

The stream buffer can contain tool inputs and outputs, not just the final
text. It stays the same private, transient `tasks/out-*` file (600, removed at
exit, stale ones pruned after a day). Captures store only the fields above.

### 6. Docs

Update SPEC.md, USAGE.md, HOW-IT-WORKS.md (the "claude -p is not measured"
statements become "relay runs report quota through stream-json"), README (the
"Good to know" bullet and the "no data" FAQ: an account now gets data after
its first interactive reply **or relay run**), SECURITY.md (the buffer can
hold tool output), and the plan-mode note stays. VERSION becomes 0.4.0 and the
README install line `git checkout v0.4.0`.

## Tests (new file `tests/child-usage.sh`, sourced from `tests/run.sh`)

The fake Claude already prints `$FAKE_CLAUDE_OUTPUT` verbatim; fixtures are
JSONL files.

1. Argv contains `--output-format stream-json --verbose` (update existing
   expectations that say `json`).
2. A stream of init + assistant + rate_limit_event + result renders the result
   byte for byte, exit status preserved, and spend recorded from that result.
3. Multiple result events: the last one is rendered and recorded.
4. A rate_limit_event with five_hour 0.06 and seven_day 0.34 creates
   `usage/b/<session>.json` with 6 and 34, `source:"relay"`, and then
   `status --json` shows profile b `known:true` with score 34.
5. A Team-style event with only five_hour records only five_hour.
6. Invalid windows (string utilization, negative, NaN-like 1e999, missing
   resetsAt) are dropped; utilization 1.7 is clamped to 100; no valid window
   records no capture.
7. `status:"rejected"` with a future `resetsAt` marks the profile exhausted
   until then; a past `resetsAt` does not.
8. A stream with a rate_limit_event but no result: empty stdout, the stderr
   note, usage recorded, no spend.
9. `--continue` updates the same capture file for that session.
10. Not-a-stream buffers (plain text, `{}`, `[1]`, an object without `.type`,
    trailing garbage) still pass through byte for byte and record nothing.
11. A recording failure (symlinked `usage/` directory) prints the new warning
    and leaves stdout and the exit status unchanged.
12. Captures and the buffer never contain the task or result text (marker
    grep), and capture files are 600 in a 700 directory.

All existing tests keep passing under `bash tests/run.sh` and
`/bin/bash tests/run.sh`.
