# claude-relay usage

`claude-relay` helps you continue Claude Code work across profiles that use
separate accounts. Each profile has its own `CLAUDE_CONFIG_DIR`. The tool saves
quota usage received by the statusline, selects the profile with the most
remaining capacity, and copies a conversation so you can continue it with
`claude --resume`.

Before the quota runs out, hooks ask the model to write a handoff describing
the state of the work. You switch accounts from your terminal; the hook does
not start another interactive session on its own.

## Quick start

With Claude Code installed and signed in, Bash 3.2+ and `jq` 1.6+ available,
clone this repository, enter its directory, and run:

```bash
./install.sh --dry-run
./install.sh
export PATH="$HOME/.local/bin:$PATH"
claude-relay doctor
claude-relay status
```

This reuses an existing pool, or detects a single logged-in profile on a first
install. If several (or none) are logged in, choose profiles explicitly using
the options below. Run `./bin/claude-relay detect` to see candidates.

## Requirements and installation

You need Claude Code installed and authenticated separately in each profile
you plan to use, Bash 3.2 or later, and `jq` 1.6 or later. The tool uses standard
macOS/Linux utilities. It has no network dependencies and does not query quota
endpoints.

Clone this repository, enter its directory, and run:

```bash
./install.sh --dry-run
./install.sh
export PATH="$HOME/.local/bin:$PATH"
claude-relay doctor
```

With no profile options, an existing pool and its recorded settings targets
are reused. Otherwise, the only logged-in candidate is selected automatically;
zero or multiple logins print the discovery table and exit 2 without installing.
Add the PATH line to your shell configuration to make it persistent.
Keep the checkout in place: the installed executable is a symlink to the
repository. Prefer `~/.local/share/claude-relay`, writable only by you, and
check out the latest release tag as described in [AGENTS.md](../AGENTS.md).
For an existing checkout following a branch, `git pull && ./install.sh` reuses
your pool, settings targets and recorded agent. For a pinned checkout, fetch
and review the new release tag, check it out, then run `./install.sh`.

`claude-relay detect [--json]` lists `~/.claude`, every directory under
`${CLAUDE_PROFILES_ROOT:-~/.claude-profiles}`, and `$CLAUDE_CONFIG_DIR` when set.
Resolved paths are deduplicated. Each candidate includes a suggested name,
path, login status (email metadata present), email, organization and pool
membership. This is not a check that a saved login is still valid. Generated
names may need `--profile name=dir` when they differ from the directory name.

If you already use `claude-profile`:

```bash
./install.sh --profiles personal,work --with-agent
```

Names resolve under `${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}`.
You can also specify arbitrary directories, including paths with spaces:

```bash
./install.sh \
  --profile "personal=$HOME/.claude" \
  --profile "work=$HOME/profiles/Claude work" \
  --warn-at 90 --handoff-at 97 --with-agent
```

Use only accounts and profiles you are authorized to use. Relay does not sign
in, transfer credentials or share authentication between profiles. For
`status`, it extracts only the email address and organization from
`<config_dir>/.claude.json`.

You can repeat `--profiles`, `--profile` and `--settings`. The pool is replaced
with the supplied list, in that order. Without `--settings`, installation
modifies `~/.claude/settings.json` when `claude-profile` is on PATH (that file
is its synchronization source); otherwise, it modifies each profile's
`settings.json`.

Installation adds groups to `UserPromptSubmit`, `PostToolUse` and `StopFailure`
(without a matcher), preserves unrelated hooks, and wraps the previous
statusline without `refreshInterval`. Reinstalling removes relay's old
`refreshInterval:60` and migrates the old `rate_limit` matcher without
duplicating groups or changing unrelated hooks' matchers. Before each write,
it creates `settings.json.relay-backup-<date>.<suffix>` and validates the new
JSON before replacing the file atomically. `--dry-run` shows the changes
without writing files.

## Daily use

```bash
claude-relay status
claude-relay status --json
claude-relay pick
claude-relay pick --exclude work --json
claude-relay run --pick --
claude-relay run --profile personal -- --model sonnet
```

`status` shows the account, usage percentage and local reset time for both
windows, data age, score, and `*` beside the current profile. It identifies the
current profile by comparing the resolved path of `CLAUDE_CONFIG_DIR`
(default: `~/.claude`) with the pool's paths. Outside the pool, specify
`--profile` or `--pick` explicitly. `run` without a selector uses the current
profile.

The score is the higher usage percentage of the 5-hour and 7-day windows.
A window whose reset time has passed is ignored. Among fresh captures, prefer those with an unexpired five-hour window when
any exist. Within that subset (or all fresh captures if none are current),
each window uses the latest reset time, then the highest usage
percentage on a tie. If none are fresh, relay uses the newest capture alone.
Without any active windows, the default score is 50. `pick` selects the lowest
score, excludes profiles with missing directories or scores of 97 or higher,
and breaks ties by pool order. If there are no candidates, it returns exit
code 3. Explicit profile selection allows a manual choice even when the
profile does not meet those filters.

An account marked as exhausted has a score of 100 until the mark expires;
`status` shows "exhausted until HH:MM" in local time. You can set or clear the
mark manually:

```bash
claude-relay exhausted personal
claude-relay exhausted personal --for 90m   # also 4h or 3600s
claude-relay exhausted personal --until 1791828000  # epoch seconds
claude-relay exhausted personal --clear
```

Without an explicit duration or deadline, relay uses the last known
`five_hour.resets_at` if it is still in the future; otherwise, it uses
`exhausted_ttl` (3600 seconds by default). `--for`, `--until` and `--clear` are
mutually exclusive. A new capture with valid quota data and a score below
`handoff_at` clears the mark if its `captured_at` is later than the mark's
creation time. Missing, older or still-high usage data does not clear it.

At 90%, the model receives a warning to start wrapping up. At 97%, it receives
the exact handoff path and these section names: Goal; Status (done / in
progress / pending); Files and branches touched; Decisions and why; Concrete
next steps; Commands to verify; Risks/open questions. The model must write the
handoff in the language of the conversation. Each level is announced once per
profile, session and reset time of the window that triggered it.

When the model says the handoff is ready, run this in your terminal:

```bash
claude-relay resume --last
# Or choose a destination:
claude-relay resume --last --to work
```

The hook records the session even before copying it, so `--last` can complete
a pending transfer. The `StopFailure` hook records every error it receives and
looks for usage-limit signals in the error fields. If it detects a limit, it
first marks the account as exhausted, then tries to copy the session to the
best profile. It sends a desktop notification if a notifier is available;
if the transcript is missing or the transfer fails, it reports "account X
exhausted; could not copy the session". The log helps investigate whether plan
limit errors actually reach this hook.

You can also transfer manually from the project directory:

```bash
claude-relay handoff --from personal --to auto
claude-relay handoff --from personal --to work --session ID --cwd "$PWD"
claude-relay handoff --from personal --to work \
  --transcript /path/to/config/projects/project/ID.jsonl --cwd /path/to/project --json
claude-relay resume --last
claude-relay resume --session ID --to auto
```

Without an ID or transcript, relay chooses the most recent `.jsonl` by mtime
in the project for the cwd. With an explicit selector and no `--cwd`, it tries
to recover the cwd from the transcript; if none is present, it uses the current
directory. An ID found in multiple projects requires `--transcript`. The
source project directory name is preserved, without recalculating it for the
destination.

The sibling subagent directory is copied too. A newer destination file keeps
its contents. Transcripts and handoffs have mode 600, and new directories have
mode 700; file copies are atomic. Symlinks in transcripts and their destinations
are rejected. Credentials, configuration, project files, branches and worktrees
are not copied: both profiles must have access to the same cwd. `resume` shows
the handoff path and runs `claude --resume ID` there; it does not attach the
handoff as a new prompt.

`run` and `resume` remove the inherited variables `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`,
`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY` and `ANTHROPIC_BASE_URL` before
launching Claude. For tests or an alternative executable, set
`CLAUDE_RELAY_CLAUDE_BIN` (a binary path, without arguments).
They also remove `CLAUDECODE` and `CLAUDE_CODE_CHILD_SESSION` to allow the
separate process requested by the forwarder and let Claude save its transcripts
for future handoffs and resumes.

## Configuration and state

`${XDG_CONFIG_HOME:-$HOME/.config}/claude-relay/pool` contains one
`name<TAB>config_dir` line per profile. Comments beginning with `#` are allowed.
Names may contain ASCII letters, numbers, dots, hyphens and underscores, and
must start with a letter or number. Paths cannot contain tabs or newlines.

In the same directory, `config` is `key=value` text, without shell expansion:

```ini
warn_at=90
handoff_at=97
unknown_score=50
exhausted_ttl=3600
capture_max_age=21600
max_depth=1
wrapped_statusline=printf 'my statusline'
```

`CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` and
`CLAUDE_RELAY_EXHAUSTED_TTL`, plus `CLAUDE_RELAY_CAPTURE_MAX_AGE` and `CLAUDE_RELAY_MAX_DEPTH`, take
precedence over their corresponding keys. The TTL and maximum capture age
are positive integers in seconds. Percentages must be between 0 and
100, with `warn_at <= handoff_at`. The previous statusline receives exactly
the same JSON on stdin, and its output is appended with ` │ ` as the separator.
Its command runs through Bash as trusted local configuration code; input must
be a single JSON object and is never interpolated into the command. If it fails, relay's
statusline produces no output either.

State is stored under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-relay/`:

- `usage/<profile>/<session_id>.json`: each session's last changed quota
  capture, containing `profile`, `session_id`, `model` (input `.model.id`, or
  `null`), `captured_at` and `rate_limits`. Captures older than seven days are
  pruned when the statusline writes.
- `usage/<profile>.json`: a compatibility copy of the newest capture. Relay
  reads it only when no per-session captures exist for that profile.
- `exhausted/<profile>.json`: `{profile, at, until, source}`; epoch timestamps,
  with source `manual` or `stop-failure`. While `until > now`, `status --json`
  exposes `score:100`, `exhausted:true` and `exhausted_until`; it does not invent
  windows.
- `events.log`: one JSON line per StopFailure, mode 600. Includes an ISO UTC
  timestamp, profile, session_id, sorted top-level keys, and only the fields
  present among `error`, `error_type`, `error_details`, `matcher`, `reason`,
  `message`. The session_id and those values are sanitized and truncated to
  200 characters; transcripts and other payload values are not logged.
- `handoffs/<project>/<date>-<sid8>.md`: private handoffs.
- `last-handoff.json`: the latest transfer or pending transfer.
- `warned/`: marks for warnings already delivered.
- `sessions/`: persistent associations between sessions and their handoffs.

`installed-settings.json`, in the configuration directory, records the modified
settings files and original statuslines. It allows all their options to be
restored and supports different statuslines per profile. It contains no
credentials.

## Optional subagent

`--with-agent` installs `agents/relay.md` at `~/.claude/agents/relay.md`. It is a
forwarder using Haiku and only the Bash tool: it passes the complete task in
one call to `claude-relay run --pick --exclude <current> -- -p ...`, with the
prompt read from stdin via a private temporary file. A quoted heredoc with a
random suffix keeps task text out of shell arguments; the file is deleted on exit. The child
**does not see the conversation**; the task must include all necessary context.
Usage is charged to the selected account, and the wrapper reports which
profile was used.

The default permission mode is `plan`; if the task requires writing, use
`acceptEdits`. Request `run_in_background` for long tasks. Do not assume those
runs update the quota data relay sees.

The forwarder refuses when `CLAUDE_RELAY_DEPTH` is set. `run` refuses at
`max_depth` (default 1), and each launch increments the inherited depth.
`resume` is interactive and user-initiated: it resets depth to 0 before launch,
so the new process receives 1. Depth values are bounded non-negative integers
(0–2147483646); `max_depth=0` disables `run`.

Installation records the agent copy’s POSIX `cksum` in `agent.cksum`. Upgrades
replace the copy when it matches that record or the current template. An
unrecognized or edited file is preserved: move it aside and rerun
`install --with-agent`, then reapply any changes you need. Backups are retained.

Agents installed before 0.2.0 have no checksum record. A no-options upgrade
checks an existing agent rather than silently retaining the older forwarder.
If it differs from the current template, move it aside and run
`./install.sh --with-agent --dry-run`, review, then `./install.sh --with-agent`.
An identical current template can safely acquire a missing checksum record.

## Diagnostics, tests and uninstallation

```bash
claude-relay doctor
claude-relay help
claude-relay help handoff
claude-relay --version
bash tests/run.sh
/bin/bash tests/run.sh
# If you have shellcheck:
shellcheck -x bin/claude-relay install.sh lib/*.sh tests/*.sh
claude-relay uninstall
# Also remove configuration, measurements and handoffs:
claude-relay uninstall --purge
```

The suite creates HOME, XDG, profiles, temporary files and a fake `claude`
inside `tests/.sandbox.*`, then removes them on exit. It does not install over
your real configuration, run the real Claude or send real notifications.

`uninstall` accepts repeated `--settings PATH` options; without them, it uses
the recorded settings files. It removes commands containing `claude-relay`,
restores the previous statusline if relay still occupies that slot, and
preserves unrelated changes. It removes its own symlink and the agent if the
agent matches its recorded checksum, even if the checkout template has changed.
Settings backups remain beside their
originals, even with `--purge`.

## Limitations and terms

Observed in live tests on **2026-10-12**, with **Claude Code 2.1.296**:

- **Team seats do receive `rate_limits`**, but only `five_hour`, without
  `seven_day`.
- With `refreshInterval:60`, idle sessions repeat quota data that may be
  hours old; Claude Code drops `five_hour` after its reset time, often leaving
  only `seven_day`. Relay now installs without that refresh interval, and
  reinstalling migrates existing relay statuslines.
- Two live sessions on the same account reported weekly usage of **14% and
  2% for the same reset time**. This is unexplained. A per-model weekly bucket
  may account for it, but that has not been confirmed. A later observation of
  15 sessions sharing one weekly reset found all four current sessions at 2%,
  while eleven idle sessions without a five-hour window reported 7–94%. The
  current-capture rule prevents those stale values from triggering a warning.
- With `claude -p`, the statusline **does not run**, so relay does not measure
  headless usage, including the subagent's usage.
- An account already at its limit never gets a successful response and
  produces no measurement. Exhaustion marks address this: they prevent that
  account from appearing as "no data" with a score of 50 and being selected
  again.
- The first interactive launch in a new folder shows the workspace trust
  prompt; you must handle it in the terminal.

Other limitations:

- `rate_limits` arrives only through the statusline, after the first response.
  Either or both windows may be missing; relay does not invent measurements.
- Input without `rate_limits` does not erase a previous valid measurement.
  Check its age: another session, another machine or an account switch within
  the same directory can leave it stale. There is no network quota polling.
- Sessions in the same profile have separate captures. An unchanged
  `rate_limits` payload never refreshes `captured_at`, even on an idle render.
  Relay considers captures up to `capture_max_age` old (default six hours),
  preferring captures with an unexpired five-hour window if any are fresh.
  Within the selected captures, each window uses latest reset time and then
  highest usage. This avoids stale weekly values from idle sessions. If all captures
  are stale, it uses only the newest one, still ignoring expired windows.
  `status --json` exposes `capture_count` and each selected window's
  `session_id` and `model`; its age is that of the newest considered capture.
- It is still unconfirmed whether "You've hit your session limit · resets
  2:10pm" reaches `StopFailure`. Relay installs it without a matcher to observe
  events in `events.log`; if the error does not arrive, use `exhausted` manually.
  The fallback TTL is an estimate and may require `--for` or `--until`.
- Transcript formats and locations are internal to Claude Code and may change.
  The SPEC records a manual check of cross-profile `--resume` with Claude Code
  2.1.296; this suite uses a fake binary and does not certify compatibility
  with every version. Check a test session when upgrading.
- The handoff depends on the model having time and permission to write it.
  The placeholder created by the hook may be empty if the quota runs out
  first. A transfer is not guaranteed if no other profile is available.
- Hooks and the statusline suppress errors and exit with code 0. Use `doctor`
  and the manual subcommands to investigate problems. A slow external
  statusline can increase the wrapper's execution time. The target for common
  paths is under 100 ms; this is not a guaranteed limit. The suite reports
  indicative timings, which depend on the machine and its load.

Anthropic's terms state that plan limits assume "ordinary, individual usage".
Each user is responsible for using the tool and their accounts within the
applicable terms. This note is not legal advice.
