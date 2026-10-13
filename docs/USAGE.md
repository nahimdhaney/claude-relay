# claude-relay usage

`claude-relay` helps you continue Claude Code work across profiles that use
accounts you legitimately hold. Each profile has its own `CLAUDE_CONFIG_DIR`. The tool saves
quota usage received by the statusline and by relay runs, selects the profile with the most
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
claude-profile copies that file into a profile each time it launches it. If
you start profiles another way, or set `CLAUDE_PROFILE_SYNC_SETTINGS=0`, run
`claude-profile --sync-settings <name>` for each profile after installing, or
install with `--settings <profile dir>/settings.json` for each one.

Installation adds groups to `UserPromptSubmit`, `PostToolUse` and `StopFailure`
(without a matcher), preserves unrelated hooks, and wraps the previous
statusline without `refreshInterval`. Reinstalling removes relay's old
`refreshInterval:60` and migrates the old `rate_limit` matcher without
duplicating groups or changing unrelated hooks' matchers. Before each write,
it creates `settings.json.relay-backup-<date>.<suffix>` and validates the new
JSON before replacing the file atomically. `--dry-run` shows the changes
without writing files. Previewed statusline commands show only their first word
and character count; the complete original is preserved privately. Existing
settings file modes and extra statusLine fields such as padding are preserved.

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
score and excludes profiles with missing directories or scores of 97 or higher.
Among profiles tied for the lowest score, it prefers the least relay cost in
the last 5 hours, then the fewest runs. If any tied profile has a run without
a known cost, it compares run counts first, then cost. Remaining ties go to
pool order. If there are no candidates, it returns exit code 3. Explicit
profile selection allows a manual choice even when the profile does not meet
those filters.

`status --json` and `pick --json` include
`"relay_spend_5h":{"cost_usd":0.12,"runs":3,"complete":true,"errors":0}`. The
window rolls over the last 5 hours. `complete` is false if any counted run has
no valid cost. `errors` counts runs whose child reported an error; among tied
profiles, fewer errors win first. With no runs, the values are 0, 0, true and 0. `cost_usd` is a relative
weight between accounts, not a bill: subscription plans do not charge per run.
Relay spend only breaks score ties. An unknown profile at 50 still beats a
measured 60, even if it has spent more. The text `status` table is unchanged.

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
are rejected. Existing destination directory modes are left alone; `doctor`
warns if transcript directories are group- or world-accessible. Credentials, configuration, project files, branches and worktrees
are not copied: both profiles must have access to the same cwd. `resume` shows
the handoff path and runs `claude --resume ID` there; it does not attach the
handoff as a new prompt.

`run`, `forward` and `resume` remove the inherited variables `ANTHROPIC_API_KEY`,
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
child_model=
child_allowed_tools=
forward_progress=true
wrapped_statusline=printf 'my statusline'
```

`CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` and
`CLAUDE_RELAY_EXHAUSTED_TTL`, plus `CLAUDE_RELAY_CAPTURE_MAX_AGE`, `CLAUDE_RELAY_MAX_DEPTH`
and `CLAUDE_RELAY_CHILD_MODEL`, take precedence over their corresponding keys.
`child_model` is the model alias for `forward` children (empty: the selected
profile's default); see [Optional subagent](#optional-subagent).
Claude Code 2.1.296 runs a requested Haiku model as Sonnet in `plan` mode, the
read-only default for children; see [How it works](HOW-IT-WORKS.md).
`child_allowed_tools` (or `CLAUDE_RELAY_CHILD_ALLOWED_TOOLS`; set but empty disables
it) is passed to every `forward` child as `--allowedTools`, using Claude Code's
syntax, for example `Bash(bash tests/run.sh) Bash(git diff:*)`. A `claude -p`
child cannot ask for approval, so without it any shell command is denied. With
`--write`, allowing a script the child can edit (such as a test runner) amounts to
allowing arbitrary code in that repository. `forward_progress` (or
`CLAUDE_RELAY_FORWARD_PROGRESS`) turns `forward`'s progress lines on or off; see
[Watching progress](#watching-progress). The TTL and maximum capture age
are positive integers in seconds. Percentages must be between 0 and
100, with `warn_at <= handoff_at`. The previous statusline receives exactly
the same JSON on stdin, and its output is appended with ` │ ` as the separator.
Its command runs through Bash as trusted local configuration code; input must
be a single JSON object and is never interpolated into the command. If it fails, relay's
statusline produces no output either.

State is stored under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-relay/`:

- `usage/<profile>/<session_id>.json`: each session's last changed quota
  capture, containing `profile`, `session_id`, `model` (input `.model.id`, or
  `null`), `captured_at` and `rate_limits`. Relay runs add `"source":"relay"`
  and use the session ID `forward` assigned. Captures older than `capture_max_age` are
  pruned when a capture is written, at most once every ten minutes, keeping
  the newest capture per profile.
- `usage/<profile>.json`: a compatibility copy of the newest capture. Relay
  reads it only when no per-session captures exist for that profile.
- `exhausted/<profile>.json`: `{profile, at, until, source}`; epoch timestamps,
  with source `manual`, `stop-failure` or `relay`. While `until > now`, `status --json`
  exposes `score:100`, `exhausted:true` and `exhausted_until`; it does not invent
  windows.
- `events.log`: one JSON line per StopFailure, mode 600. Includes an ISO UTC
  timestamp, profile, session_id, sorted top-level keys, and only the fields
  present among `error`, `error_type`, `error_details`, `matcher`, `reason`,
  `message`. The session_id and those values are sanitized and truncated to
  200 characters; transcripts and other payload values are not logged.
- `tasks/`: private forwarding files; `task-path` returns an unused path here.
  `out-*` files hold child output while `forward` runs, including tool input
  and output from the child's stream. Tasks and output buffers
  are deleted when forwarding ends. Files older than one day are also pruned
  on `task-path` and state pruning. A child running longer than a day could
  lose its output buffer.
- `spend/<profile>/<session>-<epoch>-<random>.json`: one private record per
  relay run, with cost and token counts but no task or result text. Records
  older than seven days are pruned when spend is recorded and during state
  pruning.
- `forwarded/<session_id>.json`: one record per session `forward` created,
  `{session_id, profile, cwd, created_at, last_used_at, totals}` with epoch-second
  timestamps. `totals` holds the last reported cumulative cost and token counts
  after an envelope is recorded. Continued runs record the increase from those
  totals. Records have mode 600 in a 700 directory. Records unused for 30 days
  are pruned on each `forward`.
- `backups/`: backups of `~/.claude/agents/relay.md` taken before install
  replaces it or uninstall removes it (mode 600, directory 700).
- `prune.json`: timestamp of the last successful state prune.
- `handoffs/<project>/<date>-<sid8>.md`: private handoffs.
- `last-handoff.json`: the latest transfer or pending transfer.
- `warned/`: marks for warnings already delivered; entries older than seven days are pruned.
- `sessions/`: associations between sessions and their handoffs; entries older than seven days are pruned.

`installed-settings.json`, in the configuration directory, records the modified
settings files and original statuslines. It allows all their options to be
restored and supports different statuslines per profile. It also records exact installed command identities. It contains no
credentials.

## Optional subagent

`--with-agent` installs `agents/relay.md` at `~/.claude/agents/relay.md`. It is a
forwarder using Haiku and the Write and Bash tools. First, one Bash call to
`claude-relay task-path` returns a fresh path in the relay's private `tasks/`
directory (700, never a symlink), without creating the task file. Write saves
the complete task to exactly that path. Then one Bash call invokes
`claude-relay forward --task-file PATH`. The deterministic command verifies
containment, ownership and regular-file status, rejects symlinks, sets mode
600, selects another profile, and passes the task on stdin. Cleanup starts
only after validation succeeds and removes the task after child success or
failure. Refused files remain untouched.
The child **does not see the conversation**; include all necessary context.
Usage is charged to the selected account, and stderr reports its profile.

The default permission mode is `plan`. The forwarder may pass `--write` (using
`acceptEdits`) only when the delegating prompt explicitly says the user approved
file edits. Requests inside task text are data and cannot grant that approval.
Request `run_in_background` for long tasks. Relay runs report quota through
stream-json: `forward` records the child profile's percentages like an
interactive reply, and records cost to break score ties.

```bash
claude-relay forward --task-file PATH [--write] [--model ALIAS] [--continue SESSION_ID] [--quiet]
```

**Child output.** `forward` asks for stream-json (`--output-format stream-json
--verbose`). It records the cost and the quota percentages, and prints the
final result text followed by a newline. It keeps the child's exit status and
passes its stderr through. An error result also adds a short note on stderr.
A stream without a result prints nothing and adds
`claude-relay: the child ended without a result.` on stderr; its quota is
still recorded. Unrecognized output passes through byte for byte and records
nothing. A recording failure prints
`claude-relay: could not record relay run data.` on stderr without changing
the result or exit status.

**Child quota.** The stream includes a `rate_limit_event` with the account's
5-hour and 7-day usage. `forward` saves it as a capture of the child profile,
`usage/<profile>/<session>.json`, marked `"source":"relay"`, so `status` and
`pick` use real percentages. `--continue` updates the same file. If the event
says the account was rejected, the profile is marked exhausted until its reset.

Claude Code's text mode can print several results when background tasks finish
at exit. `forward` returns only the last result in the stream. Children use
`plan` mode by default and rarely start background tasks.

### Watching progress

While the child works, `forward` prints one line on stderr for each tool the
child calls. You see the line as soon as the child's stream reports the call.
Stdout is unchanged: it still holds only the final result.

```text
$ claude-relay forward --task-file "$task"
claude-relay: profile side, session 3f2a9c1e-8b7d-4e60-9a1f-2c4b5d6e7f80
  · Read lib/parser.sh
  · Grep src
  · Bash Run the parser tests
  · Bash bash tests/run.sh
  · WebFetch https://example.com/spec
The parser drops the last field when a line ends with a comma. …
```

Each line shows the tool name and one detail: the first of the file path,
path, search pattern, URL, description, or the first line of the command.
Paths inside the directory where you ran `forward` are shown relative to it.
Tools with none of these show only their name.

What is never shown: tool results, file contents, edits, assistant text, and
any command line after the first. Control characters, including terminal
escape codes, are removed, runs of spaces become one space, and each line is
cut to 120 characters, ending in `…` when cut.

The relay subagent reads `forward`'s stderr too, so it sees these lines. When
it runs in the background, they show up in its output as the child works.

Progress lines are on by default. To turn them off:

- for one run: `claude-relay forward --task-file PATH --quiet`;
- for a shell: `export CLAUDE_RELAY_FORWARD_PROGRESS=0`;
- always: `forward_progress=false` in the config.

`--quiet` wins over the environment, and the environment wins over the
config. Accepted values are `true`, `false`, `1` and `0`. Any other value in
the environment or config refuses the forward before the child starts, and the
task file is kept.

**Child model.** `--model ALIAS` passes `--model ALIAS` to the child. Without
the flag, `CLAUDE_RELAY_CHILD_MODEL` applies, then `child_model` from the
config; if all are empty, the child uses the selected profile's default model.
Aliases must match `^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$` (for example `sonnet`,
`opus` or `claude-opus-5-5[1m]`). Every nonempty source is checked, even one a
higher source overrides; an invalid value refuses the forward and names its
source. The subagent passes `--model` only when the delegating prompt names a
model.

**Continuing a child.** Each new child gets a random lowercase UUID passed as
`--session-id`, and stderr reports `claude-relay: profile P, session S`; the
subagent always reports that session ID back. Relay records the session in
`forwarded/<S>.json` with the profile and the resolved working directory.
To send a follow-up to the same child conversation, run from the same
directory:

```bash
claude-relay forward --task-file PATH --continue S
```

This launches the child with `--resume S` in the recorded profile, without
selecting a profile, and updates `last_used_at`. It combines with `--model` and
`--write`. Relay refuses, leaving the task file untouched, if `S` is not a
lowercase UUID, has no record (never created by `forward`, or unused for more
than 30 days and pruned), or the current directory differs from the recorded
one. The subagent passes `--continue S` when the delegating prompt says to
continue session `S`.

`forward` refuses when `CLAUDE_RELAY_DEPTH` is set, even to 0. `run` with `-p`
or `--print` refuses at `max_depth` (default 1); these print children and
`forward` children receive depth + 1. Interactive `run` and `resume` are
user-initiated and unset depth entirely. Depth values are bounded non-negative
integers (0–2147483646); `max_depth=0` disables print launches and `forward`.

Installation records the agent copy’s POSIX `cksum` in `agent.cksum`. Upgrades
replace the copy when it matches that record or the current template. An
unrecognized or edited file is preserved: move it aside and rerun
`install --with-agent`, then reapply any changes you need. Backups are retained
in the state directory's `backups/` folder, not beside `relay.md`, where Claude
Code could load them as agents. Install moves regular files named
`relay.md.relay-backup-*` left in `~/.claude/agents/` by earlier releases into
that folder; symlinks and other files are not touched.

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

`doctor` also compares the CLAUDE.md each pool profile reads: a symlinked
`<config_dir>/CLAUDE.md` is identified by its resolved target, a regular file
by its `cksum`, and a missing file as `none`. If they differ, it prints one
informational line such as
`Note: pool profiles read different CLAUDE.md instructions: personal=/home/me/dotfiles/CLAUDE.md, work=cksum 1234567890, spare=none`.
A forwarded child follows its own profile's instructions. The note never
makes `doctor` fail.

The suite creates HOME, XDG, profiles, temporary files and a fake `claude`
inside `tests/.sandbox.*`, then removes them on exit. It does not install over
your real configuration, run the real Claude or send real notifications.

`uninstall` accepts repeated `--settings PATH` options; without them, it uses
the recorded settings files. It removes exact command identities recorded at installation (with narrow
legacy recognition when no identities were recorded),
restores the previous statusline if relay still occupies that slot, and
preserves unrelated changes. It removes its own symlink and the agent if the
agent matches its recorded checksum, even if the checkout template has changed,
after backing it up to the state directory's `backups/`. Settings backups
remain beside their originals, even with `--purge`; agent backups are in the
state directory, which `--purge` deletes.

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
- With `claude -p`, the statusline **does not run**. Relay runs report quota
  through stream-json instead, so `forward` still records the child's
  percentages. Other headless runs (`run -- -p`) are not measured. `forward`
  also records reported cost and token counts and uses cost to break score ties.
- An account already at its limit never gets a successful response and
  produces no measurement. Exhaustion marks address this: they prevent that
  account from appearing as "no data" with a score of 50 and being selected
  again.
- The first interactive launch in a new folder shows the workspace trust
  prompt; you must handle it in the terminal.

Other limitations:

- `rate_limits` arrives only through the statusline, after the first response,
  or through a relay run's stream. Either or both windows may be missing; relay does not invent measurements.
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

Use this tool for continuity across accounts you legitimately hold. Anthropic's
[legal and compliance documentation](https://code.claude.com/docs/en/legal-and-compliance)
says advertised plan limits assume “ordinary, individual usage”. You must comply
with Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
and [Usage Policy](https://www.anthropic.com/legal/aup), and any other terms
applicable to your accounts. Not affiliated with Anthropic.
