# claude-relay — specification v0.1

A tool for using multiple Claude Code accounts (profiles with different
`CLAUDE_CONFIG_DIR` values) without losing work when one runs out of quota:

1. **Measure** each profile's plan quota usage (5 hours and 7 days).
2. **Select** the profile with the most remaining capacity (`pick`) and launch
   Claude there (`run`).
3. **Warn** the model when the current profile's quota usage crosses a threshold,
   so it can write a handoff before running out of tokens.
4. **Transfer** the session to another profile: copy the transcript and resume
   it with `claude --resume` (manually verified in Claude Code 2.1.296), along
   with the handoff.

The tool must be shareable: anyone should be able to clone it, run
`./install.sh` and use it, with or without `claude-profile`.

## Claude Code facts this relies on

Live observations from 2026-10-12 with Claude Code 2.1.296 are included below.

- The JSON received by the `statusLine` command on stdin contains
  `rate_limits.five_hour.{used_percentage,resets_at}` and
  `rate_limits.seven_day.{used_percentage,resets_at}` (`used_percentage` 0–100,
  `resets_at` in epoch seconds). Available only for claude.ai subscribers and
  only after the session's first response; either window may be missing.
  Verified with Team seats: they receive `five_hour`, without `seven_day`.
  No hook receives `rate_limits`, so the statusline saves it to a file.
  The input also includes `session_id`, `transcript_path`, `cwd`, `model`.
- Multiple sessions in one profile receive independent snapshots. With
  `refreshInterval:60`, idle sessions re-render their last `rate_limits` each
  minute, potentially hours later; after `five_hour.resets_at`, Claude Code
  drops that window and may report only `seven_day`. Relay installs without
  `refreshInterval` and timestamps only changed per-session quota data.
- Two live sessions on the same account reported `seven_day.used_percentage`
  values of **14 and 2 for the same `resets_at`**. The cause is unexplained;
  a per-model weekly bucket is a hypothesis, not a confirmed explanation.
  Relay records model IDs and chooses conservatively across sessions.
- Hook input (JSON on stdin) includes `session_id`, `transcript_path`, `cwd`,
  `hook_event_name`. Hooks inherit the environment, so `CLAUDE_CONFIG_DIR`
  identifies the running profile (defaulting to `~/.claude` when unset).
- `UserPromptSubmit` and `PostToolUse` can inject context into the model with
  `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}`
  on stdout and exit code 0.
- `StopFailure` runs when a turn ends with an API error. It is unconfirmed
  whether the plan error "You've hit your session limit · resets 2:10pm"
  arrives with matcher `rate_limit`; relay installs without a matcher and
  logs events to investigate. Its output is ignored.
- Transcripts: `<config>/projects/<project>/<session_id>.jsonl` (plus a sibling
  `<session_id>/` directory containing subagent transcripts, if present).
  `<project>` is the cwd with every non-alphanumeric character replaced by `-`.
  Use the source directory name as-is; do not recalculate it.
  `claude --resume <id>` in the destination profile, with the original cwd,
  resumes the conversation. The format is internal and may change: document it.
- Authentication variables to remove from the environment when launching
  another profile:
  `ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  ANTHROPIC_BASE_URL`.
- `claude -p` (headless) does not run the statusline: its usage is not measured.
- An already exhausted account never gets a successful response or a
  measurement; it needs an exhaustion mark independent of `rate_limits`.
- The first interactive launch in a new folder shows the workspace trust prompt.
- Inherited `CLAUDE_CODE_CHILD_SESSION=1` disables transcript saving.
  `run` and `resume` remove that marker along with `CLAUDECODE`.

## Constraints

- Bash compatible with **bash 3.2** (the macOS version): no associative arrays,
  `mapfile`, `${var,,}`, `declare -A`. `#!/usr/bin/env bash`, `set -euo pipefail`.
- Dependencies: `jq` (>= 1.6) and POSIX core utilities. No GNU-only or BSD-only
  flags (`date -d`, `stat -c`, `sed -i` without a suffix…); use `jq now` for dates.
  Must run on macOS and Linux.
- Fast hooks and statusline (target < 100 ms): exit early if the profile is
  outside the pool or there is no data.
- Never read, copy or print credentials (`.credentials.json`, keychain,
  the complete `.claude.json`). Only read `oauthAccount.emailAddress` and
  `oauthAccount.organizationName` from `.claude.json` for `status`.
- Files containing transcripts or handoffs: `umask 077`, mode 600/700.
- Atomic writes (temporary file + `mv`).
- No hook may break the session: on any error, exit 0 with no output.
- No network dependencies.

## Repository structure

```
bin/claude-relay          single CLI (subcommands)
lib/                     shared functions (sourced by bin/)
agents/relay.md           wrapper subagent (optional at installation)
install.sh               shortcut: bin/claude-relay install "$@"
tests/run.sh             pure Bash suite, no extra dependencies
tests/round2.sh           exhaustion, hook and launch regressions
tests/round4.sh           multi-session captures and installation migration
tests/fixtures/           sample JSON (statusline, hooks)
README.md                in English: purpose, installation, usage, limits, terms
docs/SPEC.md             this file
```

## Configuration

- Pool: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/pool`, one
  `name<TAB>config_dir` line per profile, `#` comments. Order = tie-break priority.
- Options: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/config` (`key=value`):
  `warn_at=90`, `handoff_at=97`, `unknown_score=50`, `exhausted_ttl=3600`,
  `capture_max_age=21600`, `wrapped_statusline=<cmd>`. Both age and TTL are
  positive integers in seconds.
  Environment variables `CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` and
  `CLAUDE_RELAY_EXHAUSTED_TTL`, plus `CLAUDE_RELAY_CAPTURE_MAX_AGE`, override
  their corresponding keys.
- State: `${XDG_STATE_HOME:-~/.local/state}/claude-relay/`:
  `usage/<profile>/<session_id>.json`, the compatibility copy
  `usage/<profile>.json`, `handoffs/<project>/<YYYYmmdd-HHMMSS>-<sid8>.md`,
  `last-handoff.json`, `warned/<profile>-<sid>-<level>-<resets_at>`,
  `exhausted/<profile>.json`, `events.log`.
- Current profile = the pool name whose `config_dir` matches (resolved path)
  `${CLAUDE_CONFIG_DIR:-~/.claude}`. If none matches, it is outside the pool.

## Subcommands

### Profile measurement

Read per-session captures when any exist; only fall back to the legacy
`usage/<profile>.json` when none exist (an empty directory is not a capture).
Consider captures whose `captured_at >= now - capture_max_age`. If none are
fresh, use only the newest capture of any age. For each window independently,
discard windows with `resets_at <= now`; choose the greatest remaining
`resets_at`, then the highest `used_percentage` on a tie. This conservative
rule intentionally avoids understating conflicting reports. Do not combine
an older reset period with the latest period or revive an expired window.

`status --json` exposes `capture_count` (the number of captures considered,
including captures whose windows have expired), and `session_id` and `model`
on each selected window. Missing provenance is `null`. `captured_at` and
`age_seconds` describe the newest considered capture. With no active windows,
`known` is false, each window is `null`, and the score is `unknown_score`.
Status, pick and guard use this same measurement. Exhaustion markers override
its score as below.

`claude-relay status [--json]`
: Table: profile, account (email · org), 5 h %, 7 d %, each window's reset time
  (local time), data age, score, and `*` marking the current profile. A window
  whose `resets_at` has passed is ignored ("no data"). With an active exhaustion
  mark, show "exhausted until HH:MM" (local time). JSON includes `exhausted:true`,
  `exhausted_until` and `score:100`; without an active mark, it includes
  `exhausted:false` and the normal usage score.

`claude-relay pick [--exclude P]... [--json]`
: Print the best profile's name. Score = maximum `used_percentage` of active
  windows; no active windows = `unknown_score`. Exclude profiles with scores
  >= `handoff_at` and profiles whose config_dir does not exist. Lowest score
  wins; ties → pool order. No candidates → exit 3 and a message on stderr.

`claude-relay exhausted <profile> [--for DURATION | --until EPOCH] [--clear]`
: Atomically write `exhausted/<profile>.json` (mode 600) =
  `{profile, at, until, source}`. `at` and `until` are epoch seconds;
  `source` is `manual` or `stop-failure`. By default, `until` is the last known
  `five_hour.resets_at` if it is in the future; otherwise, `now + exhausted_ttl`.
  `--for` accepts positive integers with suffix `s`, `m` or `h` (3600s, 90m, 4h).
  `--until` accepts a non-negative integer epoch. `--clear` removes the mark
  idempotently; these three options are mutually exclusive. Requires a profile
  in the pool. While `until > now`, `measurement()` reports score 100 and
  `exhausted:true`, even without measurements, preventing automatic selection.
  An expired mark stops affecting the score without deleting prior measurements.

`claude-relay run [--profile P | --pick] [--exclude P]... -- <claude args>`
: `exec` `claude` with the profile's `CLAUDE_CONFIG_DIR` and without
  authentication variables or `CLAUDECODE` / `CLAUDE_CODE_CHILD_SESSION`; this
  allows the separate process's transcripts to be saved. Also applies to
  `resume`. The binary is configurable with `CLAUDE_RELAY_CLAUDE_BIN` (for tests).

`claude-relay handoff [--from P] [--to P|auto] [--session ID | --transcript PATH] [--cwd DIR] [--quiet] [--json]`
: Copy the session transcript to the destination profile (`auto` = `pick
  --exclude <source>`). Without `--session`/`--transcript`: the most recent
  session (mtime) in the cwd's project in the source profile (default: current
  profile). Also copy the sibling `<sid>/` directory if present. Do not
  overwrite a destination file newer than the source. Record `last-handoff.json`
  (`from`, `to`, `session_id`, `cwd`, `transcript`, `handoff_md` if one exists for
  that session, `at`). Print the resume command: `claude-relay resume --last`
  and its direct equivalent
  `cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <sid>`.

`claude-relay resume [--last | --session ID] [--to P|auto]`
: Perform the `handoff` (if needed), then `cd <cwd>` + `exec claude --resume
  <sid>` in the destination profile. If a handoff `.md` exists for the session,
  show its path before launching.

`claude-relay statusline`
: Command for `statusLine`. Read stdin; if `rate_limits` contains a valid
  window and the profile is in the pool, save
  `usage/<profile>/<session_id>.json` =
  `{profile, session_id, model, captured_at, rate_limits}` (atomically, mode 600).
  `model` is the input's `.model.id`, or `null` when absent. Session IDs must
  satisfy the same safe-name rules as profile names. Only replace a session
  capture when its parsed `rate_limits` content changes: identical idle
  renders (even with reordered JSON keys or a different model ID) retain the
  entire previous capture and its timestamp. Missing/invalid windows do not
  erase the previous capture. Keep `usage/<profile>.json` as a copy of the
  newest capture, never the most recent renderer's stale snapshot. Serialize
  updates with a directory lock and bounded contention; errors remain silent.
  Prune session captures older than 604800 seconds (7 days), by `captured_at`,
  across profiles whenever writing. Legacy copies are retained.
  Print a short line from this session's input:
  `<profile> · 5h 23% · 7d 41%` (or `no data`). If `wrapped_statusline`
  exists, pass it the same stdin and append its output, separated by ` │ `.
  Never fails. A capture with a valid window, a score below `handoff_at` and
  the persisted `captured_at > marker.at` clears the exhaustion mark. An
  identical render never makes an older capture eligible. Captures without
  windows, older than or equal to the mark, or with a high score do not clear it.

`claude-relay hook guard`
: For `UserPromptSubmit` and `PostToolUse`. Read stdin (session_id,
  transcript_path, cwd, hook_event_name). Aggregate current-profile captures;
  data from another session is still useful (it is the same account).
  Level = score as in `pick`.
  - level >= `warn_at` and not yet warned (mark in `warned/` per profile,
    session, level and `resets_at` of the triggering window) → soft context:
    quota usage at X%, start wrapping up, do not start long tasks.
  - level >= `handoff_at` and not yet warned → strong context: stop starting
    new work; write the handoff NOW at the exact path
    `handoffs/<project>/<ts>-<sid8>.md` with sections: Goal; Status (done / in
    progress / pending); Files and branches touched; Decisions and why;
    Concrete next steps; Commands to verify; Risks/open questions; write it
    in the language of the conversation; then tell the user to run
    `claude-relay resume --last` (or `--to <best profile>`, naming the profile
    returned by `pick` at that moment) in their terminal. The hook also records
    that path as the session's handoff so `handoff`/`resume` can find it.
  - JSON output with `hookSpecificOutput.hookEventName` matching the received event.
  - Outside the pool, no data or error → exit 0 with no output.

`claude-relay hook stop-failure`
: For all `StopFailure` events, without a matcher. In this order:
  1. Append a sanitized JSON line to `events.log` (mode 600): ISO UTC `at`,
     `profile`, `session_id`, `keys` (sorted top-level keys), and any present
     values among `error`, `error_type`, `error_details`, `matcher`, `reason`,
     `message`. Replace control characters in values with spaces and truncate
     each value and session_id to 200 characters. Do not log transcripts or
     any other input values.
  2. Detect a limit if any of those six fields equals `rate_limit` or its full
     text matches, case-insensitively,
     `rate.?limit|usage limit|session limit|weekly limit|hit your .*limit|limit reached`.
     Other errors are only logged; they do not mark, copy or notify.
  3. Mark the current profile as exhausted before attempting to copy.
  4. Attempt `handoff --to auto` with the received transcript. Notify with the
     destination profile and `claude-relay resume --last` on success; if the
     transcript is missing or copying/selection fails, notify "account X
     exhausted; could not copy the session". Use `osascript` on macOS or
     `notify-send` on Linux if available.
  Outside the pool or with invalid input, produce no output; always exit 0.
  Copying runs in a separate process to preserve Bash error handling.

`claude-relay install [--profiles a,b,c | --profile name=dir]... [--settings PATH]... [--with-agent] [--warn-at N] [--handoff-at N] [--dry-run]`
: - Write the pool. `--profiles a,b` resolves each name to
    `${CLAUDE_PROFILES_ROOT:-~/.claude-profiles}/<name>` (must exist);
    `--profile name=dir` supports arbitrary paths. With no profiles specified,
    use `default=~/.claude`.
  - Symlink `~/.local/bin/claude-relay` → the repo's `bin/claude-relay` (warn if
    `~/.local/bin` is not on PATH).
  - Target settings: the supplied `--settings` paths; otherwise,
    `~/.claude/settings.json` when `claude-profile` is on PATH (because it
    re-synchronizes from there); otherwise, `settings.json` in each pool config_dir.
  - Merge with jq, **additively and idempotently**: add a group whose command
    is `<absolute path>/claude-relay hook ...` to `hooks.UserPromptSubmit`,
    `hooks.PostToolUse` (no matcher = all tools) and `hooks.StopFailure`
    (no matcher). Migrate old relay entries with matcher `rate_limit`; leave
    other hooks and their matchers untouched, even if they shared a group
    with relay. If a non-relay `statusLine` already exists, save it in
    `wrapped_statusline` and set
    `{"type":"command","command":"<path>/claude-relay statusline"}`.
    Reinstall removes a relay statusline's old `refreshInterval:60`
    idempotently, retaining the receipt for the original statusline. Uninstall
    restores that original, including its own refresh interval if any.
  - Back up to `settings.json.relay-backup-<ts>` before writing. Validate the
    resulting JSON before `mv`.
  - `--with-agent` copies `agents/relay.md` to `~/.claude/agents/relay.md`.
  - `--dry-run` shows the diff and writes nothing.

`claude-relay uninstall [--settings PATH]... [--purge]`
: Remove only entries with `claude-relay` in the command, restore
  `wrapped_statusline` if there was one, and delete the symlink and installed
  agent. Remove both old relay entries (matcher `rate_limit`) and new ones
  (no matcher), preserving unrelated hooks and idempotence.
  `--purge` also deletes configuration and state.

`claude-relay doctor`
: Check jq, Bash version, `claude` on PATH, a valid pool, settings with installed
  hooks, and whether each profile has usage data and how old it is.

`claude-relay --version`, `claude-relay help [subcommand]`.

## agents/relay.md

Wrapper subagent (frontmatter `name: relay`, `tools: Bash`, `model: haiku`),
acting as a forwarder: it does not investigate or solve the task, only forwards
it in full with **one** Bash call to
`claude-relay run --pick --exclude <current profile> -- -p "<task>" --output-format text`
(current profile: `claude-relay status --json`). Read-only by default
(`--permission-mode plan`); if the task requires writing, `--permission-mode
acceptEdits`. Tell the user that the child does not see the conversation (the
task must be complete), that usage is charged to the selected account, and
which account was used. Long tasks: `run_in_background`.

## Tests (tests/run.sh)

Pure Bash with temporary `HOME`, `XDG_*` and config_dirs, and a fake `claude`
on PATH that records argv, cwd and `CLAUDE_CONFIG_DIR` / authentication variables.
Minimum cases:

- statusline writes per-session captures and the newest legacy copy when
  quota data is available; unchanged data retains `captured_at`; missing data
  preserves captures; old captures are pruned;
  outside the pool it does not write; with `wrapped_statusline` it appends output.
- measurement: conflicting sessions choose latest reset then highest usage;
  fresh captures exclude stale ones; stale-only fallback uses the newest;
  expired windows are ignored; JSON includes count and window provenance;
  legacy-only state remains readable; exhaustion still overrides the score.
- install: no refreshInterval; migration is backed up and idempotent;
  uninstall restores unrelated original statusline settings.
- pick: lowest score wins; no active windows = 50; >= 97 is
  excluded; `--exclude`; ties by order; no candidates → exit 3.
- guard: < 90 no output; 90 → soft warning once per session; 97 → strong warning
  with the handoff path; valid JSON with the correct `hookEventName`;
  outside the pool / broken JSON → exit 0 with no output.
- handoff: copies jsonl and sibling directory to `projects/<same name>/`,
  mode 600, records `last-handoff.json`, preserves a newer destination, selects
  the most recent session for the cwd when none is specified.
- run/resume: fake claude receives the correct `CLAUDE_CONFIG_DIR`, without
  authentication variables, with `--resume <sid>` and the original cwd.
- install/uninstall on a settings.json with unrelated hooks (such as Superset's):
  idempotent (two installs = same result), preserves unrelated entries,
  uninstall returns to the original byte for byte except for jq formatting;
  previous statusLine wrapped and restored; `--dry-run` writes nothing.
- exhaustion: excluded without a measurement; TTL from config/env, future reset,
  manual deadlines, expiration, idempotent clearing and recovery only with a
  newer capture below the threshold.
- stop-failure: sanitized private logging, classification of all six fields,
  unrelated errors without handoff, marking before copying, notification even
  without a transcript or on copy failure; no failure without a notifier.
- StopFailure migration from the old matcher, including mixed groups.
- fake claude receives `CLAUDE_CODE_CHILD_SESSION` unset in both run and resume.
  The Team sample without `seven_day` is measured correctly.

Run `bash tests/run.sh` and `/bin/bash tests/run.sh`: the previous 106 tests plus
new regressions must pass. Run `shellcheck` if installed. The suite does not
verify real Claude, trust prompts or headless statusline execution; those
observations come from manual tests.
