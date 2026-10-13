# claude-relay — specification v0.4.0

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
  Later, 15 sessions sharing a weekly reset showed four current sessions at
  2%, and eleven idle sessions without a five-hour window at 7–94%. Relay
  records model IDs and prefers current captures to avoid stale counter values.
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
- `claude -p` (headless) does not run the statusline. Relay runs report quota
  through stream-json instead: with `--output-format stream-json --verbose`,
  Claude Code 2.1.296 prints one JSON object per line, including a
  `rate_limit_event`:
  `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791909600,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.06,"resetsAt":1791909600},"seven_day":{"utilization":0.34,"resetsAt":1791932400}}},"session_id":"…"}`.
  `utilization` is a fraction from 0 to 1. On the same account at the same
  time, the statusline reported `five_hour` 6 and `seven_day` 34, with the same
  reset times. Team seats send only `five_hour`.
- The last stream line is the same result object that `--output-format json`
  prints. Its `total_cost_usd` and `modelUsage` counters are cumulative for the
  session, including on `--resume`. Relay subtracts the last totals it recorded.
- An already exhausted account never gets a successful response or a
  measurement; it needs an exhaustion mark independent of `rate_limits`.
- The first interactive launch in a new folder shows the workspace trust prompt.
- Inherited `CLAUDE_CODE_CHILD_SESSION=1` disables transcript saving.
  `run` and `resume` remove that marker along with `CLAUDECODE`.
- `forward` relies on the CLI flags `--session-id <uuid>` (start a session with
  a caller-chosen ID), `--resume <id>` (continue it with a new `-p` prompt from
  the same cwd and profile) and `--model <alias>`. It reads stream-json output
  for result text, spend and quota, but keeps its own validated profile and
  session ID.
  The suite uses a fake binary; continuing a forwarded session with real
  Claude Code still needs a manual check.
- Each profile reads its own `<config_dir>/CLAUDE.md`, so a forwarded child
  may follow different user instructions than its caller.

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
  `oauthAccount.organizationName` from `.claude.json` for `status` and `detect`.
- Files containing transcripts or handoffs: `umask 077`, mode 600/700.
- Atomic writes (temporary file + `mv`; ledger records use an exclusive
  `noclobber` create instead).
- No hook or statusline may break the session: on any error, exit 0 with no
  output. Require one JSON object before side effects or wrapper execution.
- Never evaluate event/transcript/account data as shell code. The saved
  statusline command is trusted local configuration and receives stdin only.
  Validate names and transcript containment, reject symlinked write paths,
  keep relay directories at 700 and files at 600, and preserve unrelated
  settings-directory permissions. See SECURITY.md for the trust boundary.
- No network dependencies.

## Repository structure

```
bin/claude-relay          single CLI (subcommands)
lib/                     shared functions (sourced by bin/)
agents/relay.md           wrapper subagent (optional at installation)
install.sh               shortcut: bin/claude-relay install "$@"
tests/run.sh             pure Bash suite, no extra dependencies
tests/exhaustion-and-hooks.sh           exhaustion, hook and launch regressions
tests/captures-and-migration.sh           multi-session captures and installation migration
tests/release.sh          discovery, upgrades, forwarding and boundary regressions
tests/v022.sh             child model, continued sessions, agent backups, doctor note
tests/spend-ledger.sh     JSON output, private ledger, deltas and pruning
tests/spend-selection.sh  rolling spend, score ties, JSON fields and handoff timing
tests/child-usage.sh      stream-json output, relay usage captures and exhaustion
tests/fixtures/           sample JSON (statusline, hooks) and a JSONL child stream
AGENTS.md                canonical agent installation guide
CLAUDE.md                install/development entry points
VERSION                  CLI release version
SECURITY.md              local threat model and private reporting
LICENSE                  MIT license
assets/                  supplied banner and logos
.github/workflows/test.yml macOS/Linux tests with pinned checkout action
docs/USAGE.md            full operational reference
README.md                in English: purpose, installation, usage, limits, terms
docs/SPEC.md             this file
```

## Configuration

- Pool: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/pool`, one
  `name<TAB>config_dir` line per profile, `#` comments. Order is the final
  tie-break after score and relay spend.
- Options: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/config` (`key=value`):
  `warn_at=90`, `handoff_at=97`, `unknown_score=50`, `exhausted_ttl=3600`,
  `capture_max_age=21600`, `max_depth=1`, `child_model=` (empty = the
  profile's default model), `wrapped_statusline=<cmd>`. Both age and TTL are
  positive integers in seconds.
  Environment variables `CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` and
  `CLAUDE_RELAY_EXHAUSTED_TTL`, plus `CLAUDE_RELAY_CAPTURE_MAX_AGE`, `CLAUDE_RELAY_MAX_DEPTH`
  and `CLAUDE_RELAY_CHILD_MODEL`, override their corresponding keys. Only
  `forward` reads and validates `child_model`, so an invalid value does not
  break other subcommands. Install preserves the key as written.
  `child_allowed_tools=` (empty = none) is passed unchanged to every `forward`
  child as one `--allowedTools` argument; `CLAUDE_RELAY_CHILD_ALLOWED_TOOLS`
  overrides it, and set-but-empty disables it. Values with control characters
  are refused before the task file is touched.
- State: `${XDG_STATE_HOME:-~/.local/state}/claude-relay/`:
  `usage/<profile>/<session_id>.json`, the compatibility copy
  `usage/<profile>.json`, `handoffs/<project>/<YYYYmmdd-HHMMSS>-<sid8>.md`,
  `last-handoff.json`, `warned/<profile>-<sid>-<level>-<resets_at>`,
  `exhausted/<profile>.json`, `events.log`, `tasks/`,
  `forwarded/<session_id>.json` (see `forward`),
  `spend/<profile>/<session>-<epoch>-<random>.json` (see Relay spend ledger), and
  `backups/relay.md.relay-backup-<ts>.<suffix>` (agent backups, see `install`).
- Current profile = the pool name whose `config_dir` matches (resolved path)
  `${CLAUDE_CONFIG_DIR:-~/.claude}`. If none matches, it is outside the pool.

## Subcommands

### Profile measurement

Read per-session captures when any exist; only fall back to the legacy
`usage/<profile>.json` when none exist (an empty directory is not a capture).
First select fresh captures whose `captured_at >= now - capture_max_age`.
A capture is **current** if it has a valid `five_hour` window with
`resets_at > now`. If any fresh capture is current, measure the profile using
only those current fresh captures, for both windows. This excludes idle
sessions' stale weekly counters even when their weekly reset matches.
Otherwise retain the previous rule: use all fresh captures, or only the newest
capture of any age if none are fresh. For each window independently, discard
windows with `resets_at <= now`; choose the greatest remaining `resets_at`, then
the highest `used_percentage` on a tie. Never combine reset periods or revive
an expired window. A current capture older than capture_max_age cannot displace
fresh idle captures.

`status --json` exposes `capture_count` (the number of captures considered,
including captures whose windows have expired), and `session_id` and `model`
on each selected window. Missing provenance is `null`. `captured_at` and
`age_seconds` describe the newest considered capture. With no active windows,
`known` is false, each window is `null`, and the score is `unknown_score`.
Status, pick and guard use this same measurement. Exhaustion markers override
its score as below.

`claude-relay detect [--json]`
: List existing candidate directories: `~/.claude`, every directory (including
  hidden ones) in `${CLAUDE_PROFILES_ROOT:-~/.claude-profiles}`, and
  `$CLAUDE_CONFIG_DIR` if set. Deduplicate resolved paths. JSON rows contain
  `name`, `path`, `logged_in`, `email`, `organization`, `in_pool`. Login means
  a nonempty email metadata field, not validated authentication. Missing or
  malformed metadata is logged out. Preserve pool names; suggest safe unique
  names otherwise. Do not read any other `.claude.json` fields.

`claude-relay status [--json]`
: Table: profile, account (email · org), 5 h %, 7 d %, each window's reset time
  (local time), data age, score, and `*` marking the current profile. A window
  whose `resets_at` has passed is ignored ("no data"). With an active exhaustion
  mark, show "exhausted until HH:MM" (local time). JSON includes `exhausted:true`,
  `exhausted_until` and `score:100`; without an active mark, it includes
  `exhausted:false` and the normal usage score. Each JSON row also includes
  `relay_spend_5h` (see Relay spend ledger). The text table is unchanged.

`claude-relay pick [--exclude P]... [--json]`
: Print the best profile's name. Score = maximum `used_percentage` of active
  windows; no active windows = `unknown_score`. Exclude profiles with scores
  >= `handoff_at` and profiles whose config_dir does not exist. Lowest score
  wins. Among profiles tied for that score, compare the last 5 hours of relay
  spend. Fewer failed runs (`errors`) come first. Then, if all tied profiles
  have complete costs, prefer the least cost,
  then the fewest runs. If any has an unknown cost, prefer the fewest runs,
  then the least cost. Remaining ties go to pool order. JSON includes
  `relay_spend_5h`. No candidates → exit 3 and a message on stderr.

  This order also applies to `forward`, `run --pick` and automatic handoff
  targets. Spend never changes a score. A measured 30 beats an unknown 50;
  an unknown 50 with relay spend still beats a measured 60.

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
  Stdin passes through unchanged. With `-p` or `--print`, `run` rejects inherited
  `CLAUDE_RELAY_DEPTH >= max_depth` with a clear error and exports the current
  depth plus one. Interactive `run` and `resume` unset depth entirely.
  Depth/max_depth must be decimal integers from 0 through 2147483646; default
  max_depth is 1 and `CLAUDE_RELAY_MAX_DEPTH` overrides config.

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
  Batch capture reads through jq, falling back per file only after an error.
  Prune captures older than `capture_max_age`, retaining the newest per profile.
  Prune warned/session entries older than seven days. Legacy copies are retained.
  Print a short line from this session's input:
  `<profile> · 5h 23% · 7d 41%` (or `no data`). If `wrapped_statusline`
  exists, pass it the same stdin and append its output, separated by ` │ `.
  Outside the pool, run only the wrapped statusline without measuring.
  Never fails. Invalid safe-worker configuration falls back to defaults, while
  doctor continues to report invalid values. A capture with a valid window, a score below `handoff_at` and
  the persisted `captured_at > marker.at` clears the exhaustion mark. An
  identical render never makes an older capture eligible. Captures without
  windows, older than or equal to the mark, or with a high score do not clear it.

`claude-relay hook guard`
: For `UserPromptSubmit` and `PostToolUse`. Read stdin (session_id,
  transcript_path, cwd, hook_event_name). Aggregate current-profile captures;
  data from another session is still useful (it is the same account). Check
  already-delivered handoffs before measurement when captures are unchanged.
  Before using a transcript path for context, validate profile containment and
  session identity through the handoff validator; sanitize the project name.
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
    reuse an existing pool and recorded settings targets. Otherwise detect
    candidates and install the sole logged-in profile; if zero or several are
    logged in, print the table, exit 2 and say
    `choose with --profiles a,b or --profile name=dir`.
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
  - `--with-agent` copies `agents/relay.md` to `~/.claude/agents/relay.md`,
    recording POSIX `cksum` in `agent.cksum`. Later installs also upgrade an
    already recorded agent without requiring the flag. Accept an existing
    copy matching either the record or current template; otherwise refuse
    and explain how to move the edited file aside. Back up before replacing.
    A no-profile upgrade also checks a pre-checksum agent: if it differs from
    the current template, require moving it aside and reinstalling with
    `--with-agent`; never silently retain an older unrecognized forwarder.
    Uninstall removes the agent only when it matches the record.
    Agent backups are written to `$STATE_DIR/backups/` (directory 700, files
    600), never beside `relay.md`, where they could be loaded as agents. Each
    non-dry-run install moves regular files named `relay.md.relay-backup-*`
    from `~/.claude/agents/` into that directory (adding a suffix on a name
    collision); symlinks and other names are left alone.
  - `--dry-run` shows a redacted diff and writes nothing. Previous statusline
    commands show a first token and character count; assignment values are hidden.
    Preserve original settings modes and additional statusLine fields.

`claude-relay uninstall [--settings PATH]... [--purge]`
: Remove exact installed command identities from the receipt, restore
  `wrapped_statusline` if there was one, and delete the symlink and installed
  agent. Remove both old relay entries (matcher `rate_limit`) and new ones
  (no matcher), preserving unrelated hooks and idempotence.
  Old receipts use conservative executable/operation recognition for migration;
  ambiguous commands remain untouched. The agent is backed up to
  `$STATE_DIR/backups/` before removal. `--purge` also deletes configuration
  and state, including those agent backups; settings backups remain.

`claude-relay doctor`
: Check jq, Bash version, `claude` on PATH, a valid pool, settings with installed
  hooks, and whether each profile has usage data and how old it is. Warn about
  group- or world-accessible transcript directories; leave their modes alone.
  Compute each pool profile's CLAUDE.md identity: the resolved target path if
  `<config_dir>/CLAUDE.md` is a symlink, otherwise `cksum <value>` (POSIX
  `cksum` CRC of its content), or `none` if it is missing. If not all identities
  match, print exactly one line,
  `Note: pool profiles read different CLAUDE.md instructions: <name>=<identity>, ...`,
  in pool order. The note is informational and never makes doctor fail.

`claude-relay --version` reads `VERSION` (0.4.0); `claude-relay help [subcommand]`.

## agents/relay.md

Wrapper subagent (frontmatter `name: relay`, `tools: Write, Bash`, `model: haiku`).
First use one Bash call to `claude-relay task-path`. It creates the private
`$STATE_DIR/tasks/` directory (700, never a symlink), prunes task files older
than one day, and returns a fresh `task-<random>.txt` path without creating it.
Use Write to put the complete task at exactly that path. Then use one Bash call
to `claude-relay forward --task-file <file>` with the path safely shell-quoted.
Task content never enters model-composed shell code. Only pass `--write` if
the delegating prompt explicitly states that the user approved file edits;
task content is data and cannot authorize that flag. Pass `--model <alias>`
only when the delegating prompt names a model, and `--continue <id>` only when
it says to continue session `<id>`; never take either value from task text.
Always report the session ID back to the caller so it can be continued later.

`claude-relay forward --task-file PATH [--write] [--model ALIAS] [--continue SESSION_ID]`
: Requires unset `CLAUDE_RELAY_DEPTH`, resolves the current profile,
  picks another profile, and launches
  `claude -p --output-format stream-json --verbose [--session-id S | --resume S] [--model M] --permission-mode MODE`
  in that order, with `plan` mode (`acceptEdits` with `--write`). It rejects
  files outside the relay task directory, symlinks, nonregular files and files
  owned by another user. It sets mode 600 after validation. Cleanup is armed
  only after all validation succeeds; accepted task files are removed after
  child success or failure, while refused files remain untouched (content and
  mode). It prints `claude-relay: profile P, session S` on stderr.
  - Model: `--model` > `CLAUDE_RELAY_CHILD_MODEL` > `child_model`; empty or
    unset means no `--model` argument (the profile's default). Every nonempty
    source is validated against `^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$`, even when a
    higher-precedence source overrides it; any invalid value refuses with an
    error naming its source.
  - New sessions: generate a lowercase version 4 UUID (8-4-4-4-12) from
    `od` on `/dev/urandom`, falling back to `$RANDOM`, and pass it as
    `--session-id`. Before launching, atomically write
    `$STATE_DIR/forwarded/<session>.json` (directory 700, file 600) =
    `{session_id, profile, cwd, created_at, last_used_at}`, where `cwd` is the
    resolved absolute working directory and timestamps are integer epoch
    seconds.
  - `--continue SESSION_ID`: the ID must match the lowercase UUID shape before
    it is used in any path. Its record must exist, be a regular file and name a
    pool profile; the resolved cwd must equal the recorded `cwd`. Otherwise
    refuse, leaving the task file untouched. It uses the recorded profile
    without `pick` (the current profile need not be in the pool), passes
    `--resume SESSION_ID`, and updates `last_used_at`. It combines with
    `--model` and `--write`.
  - Each forward first prunes records whose `last_used_at` is more than 30 days
    old; malformed records are kept. A pruned session cannot be continued.
  Tell the user that the child receives only this complete task and that
  usage is charged to the selected account. Long tasks may use `run_in_background`.

### Forward output

After validation, `forward` creates a private `tasks/out-XXXXXX` buffer with
`mktemp` and checks mode 600. The child reads the task on stdin and writes
stdout to this buffer. Its stderr goes straight to the caller. `forward`
captures its exit status, including nonzero results, before reading the buffer.

The buffer is a **stream** when the whole buffer parses as a sequence of JSON
values, it holds at least one value, and every value is an object with a
string `type`. A single such object is a stream of one, so v0.3.0 buffers
keep working. The **envelope** is the last value with `type:"result"` and a
boolean `is_error`. `result` is optional.

- For any stream, run the recording worker first (see below), even if the
  child reports an error or exits nonzero.
- For an envelope, if `result` is a string, print it followed by one newline.
  An empty string prints just that newline. If it is absent or not a string,
  print no result text.
- If `is_error` is true, also print
  `claude-relay: the child reported an error (<subtype>).` on stderr.
  Use `subtype` only when it is a nonempty string of lowercase ASCII letters
  and underscores. Otherwise use `unknown`.
- A stream without an envelope prints nothing on stdout and prints
  `claude-relay: the child ended without a result.` on stderr. It records no
  spend, but still records usage.
- Anything else passes through byte for byte and records nothing. This
  includes plain text, empty output, trailing garbage, and JSON values that
  are not objects or lack a string `type`.

Exit with the child's status, even if it disagrees with `is_error`. HUP, INT
or TERM received by `forward` instead makes it exit 1 and clean up. While it
is waiting for the child, this skips rendering and recording. The child shares
the process group and receives terminal signals directly.

The EXIT trap removes both the task and the output buffer. Task pruning also
removes `out-*` files older than one day, including buffers left by a crash.
Symlinked files and directories are never followed.

### Relay spend ledger

Each envelope creates one record under
`~/.local/state/claude-relay/spend/<profile>/<session>-<epoch>-<random>.json`
(or the configured XDG state directory). Directories are 700 and files 600.
The record is built and validated first, then written with `noclobber`
(`O_EXCL`), which never overwrites an existing name and works on filesystems
without hard links. A taken name gets a new random suffix, up to five attempts.

```json
{"profile":"personal","session_id":"00000000-0000-4000-8000-000000000000","at":1791842414,"cost_usd":0.0029,"is_error":false,"models":{"claude-haiku-5-5":{"in":2,"out":3,"cache_read":15327,"cache_write":13571}}}
```

`profile` and `session_id` come from `forward`'s validated values. `at` is an
epoch timestamp. `is_error` comes from the envelope. Only these fields are
stored. The ledger never stores task text, result text or permission denials.

Normalize reported totals before writing:

- Cost must be a finite number from 0 through 100000 USD. Other values become
  `null`. Token counts must be finite numbers from 0 through 1e12; other values
  become 0.
- A non-object `modelUsage` becomes `{}`. Skip entries whose values are not
  objects. Keep model names only when they are 1–128 ASCII letters, digits,
  dots, underscores, colons, brackets or hyphens.
- Map `inputTokens`, `outputTokens`, `cacheReadInputTokens` and
  `cacheCreationInputTokens` to `in`, `out`, `cache_read` and `cache_write`.

Each record holds the run's delta from the session's last reported totals.
New sessions start at zero. For `--continue`, subtract each baseline field
from its reported value. If the baseline is missing or invalid, or the reported
value is lower, use the reported value as is. This can over-count once, but
never gives a negative delta. An unknown cost stays `null`.

After recording, replace `totals` in `forwarded/<session>.json` with
`{"cost_usd":<number-or-null>,"models":{<model>:{in,out,cache_read,cache_write}}}`.
Those session records retain their 30-day lifetime. Ledger files older than
seven days are pruned before recording and during state pruning. State pruning
runs at most once every ten minutes.

Recording runs in a separate strict Bash worker,
`__record-run <profile> <session> <buffer>`. It checks the profile is in the
pool, the session is a lowercase UUID, and the buffer is an owned regular
`out-*` file directly inside `tasks/`, with mode 600. It rejects symlinks and
never writes stdout. It records spend from the envelope when there is one,
then usage from the usage event when there is one (see Relay usage captures).
A failure in either part makes the worker exit nonzero after it attempts the
other part. `forward` then prints `claude-relay: could not record relay run data.`
on stderr. The result and child exit status stay unchanged.

`relay_spend <profile>` returns `{"cost_usd":N,"runs":N,"complete":B,"errors":N}` for
the rolling last 5 hours. It preselects regular files by mtime, with a 60-second
margin, then reads them in one jq call. If parsing fails, it reads each file
separately so a damaged file cannot hide valid ones. Symlinked files are
skipped. A missing or symlinked ledger directory gives zero cost, zero runs
`complete:true` and zero errors.

A record counts only if it is an object with the matching profile, a finite
`at` from `now-18000` through `now+60`, and a finite nonnegative cost or `null`.
Sum the non-null costs and count all valid records. `complete` is false if
any counted record has a null cost. `errors` counts records with
`is_error:true`: failed runs are often the cheapest (a lost login fails at no
cost), so they must not make a broken profile look attractive. Missing costs from older Claude Code
versions still count as runs. Both `status --json` and `pick --json` expose
this object as `relay_spend_5h`. Cost is a relative weight between accounts,
not a bill: subscription plans do not charge per run.

### Relay usage captures

The **usage event** is the last stream value with `type:"rate_limit_event"`
whose `rate_limit_info.unifiedWindows` is an object. For each of `five_hour`
and `seven_day` that is an object with a finite numeric `utilization` and a
finite numeric `resetsAt` of at least 0, build
`{used_percentage: utilization×100 clamped to 0–100 and rounded to 2 decimals, resets_at: resetsAt}`.
Other windows are dropped. If no window is valid, nothing is recorded.

The capture has the statusline shape plus a source marker:

```json
{"profile":"personal2","captured_at":1791898000.5,"session_id":"<forward's session>","model":null,"source":"relay","rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1791909600},"seven_day":{"used_percentage":34,"resets_at":1791932400}}}
```

It is stored with the statusline's capture code (lock, legacy copy, pruning)
as the child profile, in `usage/<child profile>/<session>.json`. `measurement`
reads it like any other capture. `session_id` is the session `forward`
assigned or resumed, never the one the child reports, so `--continue` updates
the same file. Only these fields are stored, never text.

If `rate_limit_info.status` is `"rejected"` and `rate_limit_info.resetsAt` is
a finite number in the future, also mark the child profile exhausted until
`resetsAt` (source `relay`), so `pick` skips it.

### Known forwarding limitations

- Claude Code's text mode can print several results when background tasks
  finish at exit. `forward` returns only the last result in the stream. Children use `plan` mode by default and rarely start such
  tasks.
- A child running for more than one day could lose its output buffer to stale
  file pruning.
- Simultaneous `--continue` runs for the same session can race when reading
  and updating the shared totals baseline. Their deltas may be inaccurate.
  Unique ledger files preserve each run's record, but baseline updates are
  not serialized.

## Tests (tests/run.sh)

Pure Bash with temporary `HOME`, `XDG_*` and config_dirs, and a fake `claude`
on PATH that records argv, cwd and `CLAUDE_CONFIG_DIR` / authentication variables.
Minimum cases:

- statusline writes per-session captures and the newest legacy copy when
  quota data is available; unchanged data retains `captured_at`; missing data
  preserves captures; old captures are pruned;
  outside the pool it does not write; with `wrapped_statusline` it appends output.
- measurement: the anonymized 15-session regression chooses four current
  sessions at weekly 2% and excludes eleven idle sessions at 7–94%; no false
  guard warning; conflicting current sessions choose latest reset then highest usage;
  fresh captures exclude stale ones; stale-only fallback uses the newest;
  expired windows are ignored; JSON includes count and window provenance;
  legacy-only state remains readable; exhaustion still overrides the score.
- onboarding: detect filters account metadata, includes config overrides,
  deduplicates paths and marks pool membership; first install selects only a
  single login; multiple/zero logins exit 2; upgrade reuses the pool/settings;
  agent checksum ownership survives template changes and preserves user edits;
  version comes from VERSION.
- hardening: stdin reaches fake Claude unchanged, including hostile task text;
  the forwarder cleans temporary files even on failure; depth config/env,
  recursion rejection and resume reset; multi-document JSON rejected;
  permissions and symlink destinations; shell-sensitive checkout paths.
- install: no refreshInterval; migration is backed up and idempotent;
  uninstall restores unrelated original statusline settings.
- pick: lowest score wins; no active windows = 50; >= 97 is
  excluded; `--exclude`; ties by failed runs, relay cost and runs, then pool order;
  incomplete costs compare runs first; no candidates → exit 3.
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
- v0.2.2 (`tests/v022.sh`): model flag/env/config precedence and validation of
  every source; argv with `--session-id <uuid>` for new sessions and
  `--resume` for `--continue`; refusal of unknown, malformed and traversal IDs
  and of a different cwd, with the task left untouched; record fields,
  permissions, `last_used_at` update and 30-day pruning; agent backups in
  state and migration of legacy backups (symlinks stay); the doctor
  CLAUDE.md note absent when identities match and exactly once when they differ.
- relay spend: exact output bytes and child status; private buffers and
  cleanup; bounded numbers, model names and no saved text; cumulative deltas;
  unique records; recording failures; seven-day pruning and the five-hour
  window; malformed and symlinked files; JSON fields; the guard handoff path
  with 300 ledger files per profile stays under 1.5 seconds.
- relay usage (`tests/child-usage.sh`): stream-json argv; the last result is
  rendered and recorded; usage captures for full and Team-style events; invalid
  windows dropped and over-limit values clamped; rejected events mark
  exhaustion only with a future reset; streams without a result; `--continue`
  updates the same capture; non-stream passthrough; recording failures; no
  saved text and private modes.

Run `bash tests/run.sh` and `/bin/bash tests/run.sh`: all regressions must pass.
Also run with jq 1.6 when available. Run `shellcheck` if installed. The suite does not
verify real Claude, trust prompts or headless statusline execution; those
observations come from manual tests.
