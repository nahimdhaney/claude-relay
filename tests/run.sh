#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SANDBOX=$(mktemp -d "$ROOT/tests/.sandbox.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/config" XDG_STATE_HOME="$SANDBOX/state"
export XDG_CACHE_HOME="$SANDBOX/cache" XDG_DATA_HOME="$SANDBOX/data" XDG_RUNTIME_DIR="$SANDBOX/runtime" TMPDIR="$SANDBOX/tmp"
export CLAUDE_PROFILES_ROOT="$SANDBOX/profiles" CLAUDE_CONFIG_DIR="$SANDBOX/profiles/a"
unset CLAUDE_RELAY_WARN_AT CLAUDE_RELAY_HANDOFF_AT CLAUDE_RELAY_EXHAUSTED_TTL CLAUDE_RELAY_CAPTURE_MAX_AGE CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS BASH_ENV ENV || true
mkdir -p "$HOME" "$XDG_CONFIG_HOME/claude-relay" "$XDG_STATE_HOME" "$TMPDIR" "$SANDBOX/fake" "$CLAUDE_PROFILES_ROOT/a" "$CLAUDE_PROFILES_ROOT/b" "$CLAUDE_PROFILES_ROOT/c" "$SANDBOX/project space"
export PATH="$SANDBOX/fake:$PATH" CLAUDE_RELAY_CLAUDE_BIN="$SANDBOX/fake/claude" FAKE_LOG="$SANDBOX/launch.json"
# Shebangs and child shells use the same Bash as this suite (including 3.2).
ln -s "$BASH" "$SANDBOX/fake/bash"
cat > "$CLAUDE_RELAY_CLAUDE_BIN" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
jq -n --arg depth "${CLAUDE_RELAY_DEPTH-unset}" --arg cwd "$PWD" --arg config "$CLAUDE_CONFIG_DIR" --arg nested "${CLAUDECODE-}" --arg child "${CLAUDE_CODE_CHILD_SESSION-unset}" --arg auth "${ANTHROPIC_API_KEY-}${ANTHROPIC_AUTH_TOKEN-}${CLAUDE_CODE_OAUTH_TOKEN-}${CLAUDE_CODE_USE_BEDROCK-}${CLAUDE_CODE_USE_VERTEX-}${CLAUDE_CODE_USE_FOUNDRY-}${ANTHROPIC_BASE_URL-}" --args '{depth:$depth,cwd:$cwd,config:$config,nested:$nested,child:$child,auth:$auth,args:$ARGS.positional}' -- "$@" > "$FAKE_LOG"
if [ -n "${FAKE_CLAUDE_OUTPUT:-}" ]; then
  if [ -n "${FAKE_CLAUDE_BUFFER_MODE:-}" ]; then
    for buffer in "$XDG_STATE_HOME/claude-relay/tasks/"out-*; do
      [ -f "$buffer" ] && [ ! -L "$buffer" ] || continue
      LC_ALL=C ls -ld "$buffer" | cut -c1-10 > "$FAKE_CLAUDE_BUFFER_MODE"
    done
  fi
  if [ -n "${FAKE_CLAUDE_REMOVE_PROFILE:-}" ]; then
    awk -F '\t' -v profile="$FAKE_CLAUDE_REMOVE_PROFILE" '$1 != profile' "$XDG_CONFIG_HOME/claude-relay/pool" > "$TMPDIR/pool"
    mv "$TMPDIR/pool" "$XDG_CONFIG_HOME/claude-relay/pool"
  fi
  [ "${FAKE_CLAUDE_SIGNAL:-}" != TERM ] || kill -TERM $$
  cat "$FAKE_CLAUDE_OUTPUT"
  exit "${FAKE_CLAUDE_STATUS:-0}"
fi
FAKE
# Never invoke a real desktop notifier from this suite.
for notifier in osascript notify-send; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/fake/$notifier"
  chmod +x "$SANDBOX/fake/$notifier"
done
chmod +x "$CLAUDE_RELAY_CLAUDE_BIN"
CLI="$ROOT/bin/claude-relay"
TOTAL=0
FAILED=0
check() {
  TOTAL=$((TOTAL + 1))
  if "$@"; then printf 'ok %s - %s\n' "$TOTAL" "$*"; else printf 'not ok %s - %s\n' "$TOTAL" "$*"; FAILED=$((FAILED + 1)); fi
}
relay() { "$BASH" "$CLI" "$@"; }
json_is() { jq -e "$2" "$1" > /dev/null; }
equals() { [ "$1" = "$2" ]; }
write_pool() { printf 'a\t%s\nb\t%s\nc\t%s\n' "$CLAUDE_PROFILES_ROOT/a" "$CLAUDE_PROFILES_ROOT/b" "$CLAUDE_PROFILES_ROOT/c" > "$XDG_CONFIG_HOME/claude-relay/pool"; }
usage() {
  # This helper intentionally creates legacy-only state.
  rm -rf "$XDG_STATE_HOME/claude-relay/usage/$1"
  mkdir -p "$XDG_STATE_HOME/claude-relay/usage"
  jq -n --arg p "$1" --argjson n "$2" --argjson reset "${3:-4102444800}" '{profile:$p,captured_at:now,session_id:"other-session",rate_limits:{five_hour:{used_percentage:$n,resets_at:$reset}}}' > "$XDG_STATE_HOME/claude-relay/usage/$1.json"
}
guard_input() { jq --arg cwd "$SANDBOX/project space" --arg transcript "$SOURCE" --arg event "${1:-UserPromptSubmit}" '.cwd=$cwd | .transcript_path=$transcript | .hook_event_name=$event | if $event=="StopFailure" then .error="rate_limit" else . end' "$ROOT/tests/fixtures/hook.json"; }
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
check test -f "$CLI"
if [ ! -f "$CLI" ]; then printf 'Summary: %s tests, %s passed, %s failed.\n' "$TOTAL" "$((TOTAL-FAILED))" "$FAILED"; exit 1; fi
relay --version > "$SANDBOX/version"
check test -s "$SANDBOX/version"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check json_is "$XDG_STATE_HOME/claude-relay/usage/a.json" '.profile=="a" and .rate_limits.seven_day.used_percentage==41'
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41%'
cp "$XDG_STATE_HOME/claude-relay/usage/a.json" "$SANDBOX/usage-before"
printf '{"session_id":"missing"}' | relay statusline > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · no data'
check cmp -s "$SANDBOX/usage-before" "$XDG_STATE_HOME/claude-relay/usage/a.json"
CLAUDE_CONFIG_DIR="$SANDBOX/outside" relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
printf 'wrapped_statusline=jq -r .session_id\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41% │ session-one'
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
usage a 80; usage b 20
check equals "$(relay pick)" b
check equals "$(relay pick --exclude b)" c
usage a 99 1
check equals "$(relay pick)" b
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==50 and .[0].known==false and .[0].five_hour==null and .[0].current==true and .[2].score==50'
relay status > "$SANDBOX/status-table"
check test -s "$SANDBOX/status-table"
usage a 20
check equals "$(relay pick)" a
usage a 97; usage b 100; usage c 98
rc=0; relay pick > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 3
check test -s "$SANDBOX/err"
usage b 15; usage c 25
relay pick --json > "$SANDBOX/pick"
check json_is "$SANDBOX/pick" '.profile=="b" and .score==15'
PROJECT=$(printf '%s' "$SANDBOX/project space" | jq -Rr 'gsub("[^a-zA-Z0-9]";"-")')
SOURCE="$CLAUDE_PROFILES_ROOT/a/projects/$PROJECT/session-one.jsonl"
mkdir -p "$(dirname "$SOURCE")/session-one/subagents"
printf '{"type":"user","message":"hello"}\n' > "$SOURCE"
printf '{"type":"assistant"}\n' > "$(dirname "$SOURCE")/session-one/subagents/agent-one.jsonl"
usage a 89
guard_input | relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
usage a 90
guard_input | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.hookEventName=="UserPromptSubmit" and .hookSpecificOutput.additionalContext=="Profile a quota usage is at 90 %. Start wrapping up the work and do not start long tasks."'
guard_input | relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
usage a 97
guard_input PostToolUse | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.hookEventName=="PostToolUse" and (.hookSpecificOutput.additionalContext | contains("Goal; Status (done / in progress / pending); Files and branches touched; Decisions and why; Concrete next steps; Commands to verify; Risks/open questions") and contains("in the language of the conversation") and contains("resume --last"))'
HANDOFF=$(jq -r .handoff_md "$XDG_STATE_HOME/claude-relay/last-handoff.json")
check test -d "$(dirname "$HANDOFF")"
printf 'Goal: continue\n' > "$HANDOFF"
guard_input | relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
printf '{broken' | relay hook guard > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
guard_input | CLAUDE_CONFIG_DIR="$SANDBOX/outside" relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
export CLAUDECODE=1 ANTHROPIC_API_KEY=sentinel ANTHROPIC_AUTH_TOKEN=sentinel CLAUDE_CODE_OAUTH_TOKEN=sentinel CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 ANTHROPIC_BASE_URL=sentinel
relay run --pick -- --some-flag 'argument with spaces'
check json_is "$FAKE_LOG" '.config | endswith("/b")'
check json_is "$FAKE_LOG" '.auth=="" and .args==["--some-flag","argument with spaces"]'
check json_is "$FAKE_LOG" '.nested==""'
relay resume --last > "$SANDBOX/out"
check json_is "$FAKE_LOG" '.auth=="" and .args==["--resume","session-one"] and (.cwd | endswith("/project space"))'
DEST="$CLAUDE_PROFILES_ROOT/b/projects/$PROJECT/session-one.jsonl"
check cmp -s "$SOURCE" "$DEST"
check cmp -s "$(dirname "$SOURCE")/session-one/subagents/agent-one.jsonl" "$(dirname "$DEST")/session-one/subagents/agent-one.jsonl"
check equals "$(LC_ALL=C ls -l "$DEST" | cut -c1-10)" '-rw-------'
# Refresh a previous copy if the source session continued after handoff.
printf '{"updated":true}\n' > "$SOURCE"
touch -t 202101010000 "$SOURCE"
touch -t 202001010000 "$DEST"
relay resume --last > "$SANDBOX/out"
check cmp -s "$SOURCE" "$DEST"
check json_is "$XDG_STATE_HOME/claude-relay/last-handoff.json" '.from=="a" and .to=="b" and .session_id=="session-one" and (.handoff_md | endswith(".md"))'
touch -t 202001010000 "$SOURCE"
printf 'newer destination\n' > "$DEST"
relay handoff --from a --to b --transcript "$SOURCE" --cwd "$SANDBOX/project space" --quiet
check equals "$(cat "$DEST")" 'newer destination'
printf '{}\n' > "$(dirname "$SOURCE")/new-session.jsonl"
(cd "$SANDBOX/project space" && relay handoff --from a --to c --json) > "$SANDBOX/handoff"
check json_is "$SANDBOX/handoff" '.session_id=="new-session" and .to=="c"'
guard_input StopFailure | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check json_is "$XDG_STATE_HOME/claude-relay/last-handoff.json" '.to=="b" and .session_id=="session-one"'
SETTINGS="$SANDBOX/settings.json"
cp "$ROOT/tests/fixtures/settings.json" "$SETTINGS"
cp "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/pool-before"
relay install --profiles a,b,c --settings "$SETTINGS" --with-agent --dry-run > "$SANDBOX/diff"
check cmp -s "$ROOT/tests/fixtures/settings.json" "$SETTINGS"
check cmp -s "$SANDBOX/pool-before" "$XDG_CONFIG_HOME/claude-relay/pool"
check test ! -e "$HOME/.local/bin/claude-relay"
check test ! -e "$HOME/.claude/agents/relay.md"
check test -s "$SANDBOX/diff"
relay install --profiles a,b,c --settings "$SETTINGS" --with-agent > "$SANDBOX/install"
cp "$SETTINGS" "$SANDBOX/installed-once"
relay install --profiles a,b,c --settings "$SETTINGS" --with-agent > "$SANDBOX/install"
check cmp -s "$SANDBOX/installed-once" "$SETTINGS"
check json_is "$SETTINGS" '.hooks.Stop[0].hooks[0].command=="superset stop" and (.hooks.UserPromptSubmit|length)==2 and (.hooks.PostToolUse|length)==2 and (.hooks.StopFailure|length)==2'
check test -L "$HOME/.local/bin/claude-relay"
check test -f "$HOME/.claude/agents/relay.md"
"$HOME/.local/bin/claude-relay" --version > "$SANDBOX/version"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41% │ superset-status'
relay doctor > "$SANDBOX/doctor"
check test -s "$SANDBOX/doctor"
relay uninstall --settings "$SETTINGS" > "$SANDBOX/uninstall"
jq -S . "$SETTINGS" > "$SANDBOX/actual"
jq -S . "$ROOT/tests/fixtures/settings.json" > "$SANDBOX/expected"
check cmp -s "$SANDBOX/actual" "$SANDBOX/expected"
check test ! -e "$HOME/.local/bin/claude-relay"
check test ! -e "$HOME/.claude/agents/relay.md"
relay uninstall --settings "$SETTINGS" > "$SANDBOX/uninstall"
jq -S . "$SETTINGS" > "$SANDBOX/actual"
check cmp -s "$SANDBOX/actual" "$SANDBOX/expected"
rc=0; relay doctor > "$SANDBOX/doctor" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
for sub in status pick run handoff resume statusline hook install uninstall doctor; do relay help "$sub" > "$SANDBOX/help"; check test -s "$SANDBOX/help"; done
# Missing/partial/invalid input and IO errors must stay silent.
printf '{broken' | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
printf 'wrapped_statusline=printf partial; exit 7\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
printf 'blocked' > "$SANDBOX/not-directory"
XDG_STATE_HOME="$SANDBOX/not-directory" relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
jq 'del(.rate_limits.five_hour)' "$ROOT/tests/fixtures/statusline.json" | relay statusline > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 7d 41%'
usage a 90 4102444801
guard_input | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("90")'
usage a 92
guard_input | CLAUDE_RELAY_WARN_AT=95 relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
mv "$CLAUDE_PROFILES_ROOT/b" "$CLAUDE_PROFILES_ROOT/b-hidden"
usage a 95; usage c 98
check equals "$(relay pick)" a
mv "$CLAUDE_PROFILES_ROOT/b-hidden" "$CLAUDE_PROFILES_ROOT/b"
usage b 15; usage c 25
# Resolve aliases for the current config directory.
ln -s "$CLAUDE_PROFILES_ROOT/a" "$SANDBOX/profile-alias"
CLAUDE_CONFIG_DIR="$SANDBOX/profile-alias" relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].current'
relay run --profile c -- -p 'literal $HOME `command`' > "$SANDBOX/out"
check json_is "$FAKE_LOG" '.config | endswith("/c")'
check json_is "$FAKE_LOG" '.args==["-p","literal $HOME `command`"]'
# Original cwd is recoverable from a transcript when resuming from elsewhere.
jq -n --arg cwd "$SANDBOX/project space" '{type:"user",cwd:$cwd}' > "$(dirname "$SOURCE")/original-cwd.jsonl"
relay resume --session original-cwd --to c > "$SANDBOX/out"
check json_is "$FAKE_LOG" '.cwd | endswith("/project space")'
# A newer destination still needs private permissions.
chmod 644 "$DEST"
relay handoff --from a --to b --transcript "$SOURCE" --cwd "$SANDBOX/project space" --quiet
check equals "$(LC_ALL=C ls -l "$DEST" | cut -c1-10)" '-rw-------'
# Source project name must be copied verbatim, even when it differs from cwd encoding.
mkdir -p "$CLAUDE_PROFILES_ROOT/a/projects/verbatim-project"
printf '{}\n' > "$CLAUDE_PROFILES_ROOT/a/projects/verbatim-project/verbatim.jsonl"
relay handoff --from a --to b --transcript "$CLAUDE_PROFILES_ROOT/a/projects/verbatim-project/verbatim.jsonl" --cwd "$SANDBOX/project space" --json > "$SANDBOX/handoff"
check test -f "$CLAUDE_PROFILES_ROOT/b/projects/verbatim-project/verbatim.jsonl"
# Preserve unrelated empty hooks, including on repeated uninstall.
printf '{"hooks":{"Notification":[],"PostToolUse":[]},"theme":"dark"}\n' > "$SANDBOX/empty-hooks.json"
jq -S . "$SANDBOX/empty-hooks.json" > "$SANDBOX/expected-empty"
relay install --profiles a,b,c --settings "$SANDBOX/empty-hooks.json" > "$SANDBOX/install" 2> "$SANDBOX/err"
relay uninstall --settings "$SANDBOX/empty-hooks.json" > "$SANDBOX/uninstall"
jq -S . "$SANDBOX/empty-hooks.json" > "$SANDBOX/actual-empty"
check cmp -s "$SANDBOX/expected-empty" "$SANDBOX/actual-empty"
relay uninstall --settings "$SANDBOX/empty-hooks.json" > "$SANDBOX/uninstall"
jq -S . "$SANDBOX/empty-hooks.json" > "$SANDBOX/actual-empty"
check cmp -s "$SANDBOX/expected-empty" "$SANDBOX/actual-empty"
# Separate wrappers and exact restoration for multiple settings files.
printf '{"statusLine":{"type":"command","command":"printf profile-a"}}\n' > "$CLAUDE_PROFILES_ROOT/a/settings.json"
printf '{"statusLine":{"type":"command","command":"printf profile-b"}}\n' > "$CLAUDE_PROFILES_ROOT/b/settings.json"
cp "$CLAUDE_PROFILES_ROOT/a/settings.json" "$SANDBOX/original-a"
cp "$CLAUDE_PROFILES_ROOT/b/settings.json" "$SANDBOX/original-b"
relay install --profile "a=$CLAUDE_PROFILES_ROOT/a" --profile "b=$CLAUDE_PROFILES_ROOT/b" --settings "$CLAUDE_PROFILES_ROOT/a/settings.json" --settings "$CLAUDE_PROFILES_ROOT/b/settings.json" > "$SANDBOX/install" 2> "$SANDBOX/err"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41% │ profile-a'
CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/b" relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'b · 5h 23% · 7d 41% │ profile-b'
relay uninstall > "$SANDBOX/uninstall"
check equals "$(jq -Sc . "$SANDBOX/original-a")" "$(jq -Sc . "$CLAUDE_PROFILES_ROOT/a/settings.json")"
check equals "$(jq -Sc . "$SANDBOX/original-b")" "$(jq -Sc . "$CLAUDE_PROFILES_ROOT/b/settings.json")"
printf '{}\n' > "$CLAUDE_PROFILES_ROOT/a/settings.json"
relay install --profiles a,b --settings "$CLAUDE_PROFILES_ROOT/a/settings.json" --settings "$CLAUDE_PROFILES_ROOT/b/settings.json" > "$SANDBOX/install" 2> "$SANDBOX/err"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41%'
relay uninstall > "$SANDBOX/uninstall"
# Invalid settings abort before writing pool, settings or symlink.
printf '{"statusLine":{"type":"command","command":"printf old"}}\n' > "$CLAUDE_PROFILES_ROOT/a/settings.json"
relay install --profiles a,b --settings "$CLAUDE_PROFILES_ROOT/a/settings.json" > "$SANDBOX/install" 2> "$SANDBOX/err"
jq '.statusLine={type:"command",command:"printf changed",padding:3}' "$CLAUDE_PROFILES_ROOT/a/settings.json" > "$SANDBOX/changed"
mv "$SANDBOX/changed" "$CLAUDE_PROFILES_ROOT/a/settings.json"
relay install --profiles a,b --settings "$CLAUDE_PROFILES_ROOT/a/settings.json" > "$SANDBOX/install" 2> "$SANDBOX/err"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41% │ changed'
relay uninstall > "$SANDBOX/uninstall"
check json_is "$CLAUDE_PROFILES_ROOT/a/settings.json" '.statusLine.command=="printf changed" and .statusLine.padding==3'
cp "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/pool-before"
printf '{broken' > "$SANDBOX/broken-settings.json"
rc=0; relay install --profiles a,b,c --settings "$SANDBOX/broken-settings.json" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check cmp -s "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/pool-before"
check test ! -e "$HOME/.local/bin/claude-relay"
write_pool
# Test without desktop notification programs or claude-profile on PATH.
mkdir -p "$SANDBOX/minimal-bin"
for utility in bash jq cat dirname basename chmod cp mkdir mktemp mv rm readlink find ln cmp cksum touch ls; do
  ln -s "$(command -v "$utility")" "$SANDBOX/minimal-bin/$utility"
done
ln -s "$CLAUDE_RELAY_CLAUDE_BIN" "$SANDBOX/minimal-bin/claude"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$SANDBOX/minimal-bin/uname"
chmod +x "$SANDBOX/minimal-bin/uname"
usage b 15
guard_input StopFailure | PATH="$SANDBOX/minimal-bin" relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check json_is "$XDG_STATE_HOME/claude-relay/last-handoff.json" '.to=="b"'
usage a 99; usage b 99; usage c 99
guard_input StopFailure | PATH="$SANDBOX/minimal-bin" relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
# Plain installation and claude-profile routing remain isolated to this HOME.
mkdir -p "$HOME/.claude"
PATH="$SANDBOX/minimal-bin" relay install > "$SANDBOX/install" 2> "$SANDBOX/err"
check test -f "$CLAUDE_PROFILES_ROOT/a/settings.json"
check equals "$(cut -f1 "$XDG_CONFIG_HOME/claude-relay/pool")" "$(printf 'a\nb\nc')"
PATH="$SANDBOX/minimal-bin" relay uninstall > "$SANDBOX/uninstall"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/fake/claude-profile"
chmod +x "$SANDBOX/fake/claude-profile"
relay install --profiles a,b > "$SANDBOX/install" 2> "$SANDBOX/err"
check json_is "$HOME/.claude/settings.json" '.hooks.StopFailure[0] | has("matcher") | not'
relay uninstall > "$SANDBOX/uninstall"
rm "$SANDBOX/fake/claude-profile"
# Doctor rejects an executable below the required jq version.
relay install --profiles a,b --settings "$SETTINGS" > "$SANDBOX/install" 2> "$SANDBOX/err"
relay doctor > "$SANDBOX/doctor"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = --version ]; then printf "jq-1.5\\n"; else exec %q "$@"; fi\n' "$(command -v jq)" > "$SANDBOX/fake/jq"
chmod +x "$SANDBOX/fake/jq"
rc=0; relay doctor > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
rm "$SANDBOX/fake/jq"
# Reinstalling after loss of installation metadata must never wrap relay itself.
rm "$XDG_CONFIG_HOME/claude-relay/installed-settings.json"
relay install --profiles a,b --settings "$SETTINGS" > "$SANDBOX/install" 2> "$SANDBOX/err"
check json_is "$XDG_CONFIG_HOME/claude-relay/installed-settings.json" 'all(.[]; (.statusLine.command // "" | contains("claude-relay")) | not)'
# shellcheck source=tests/exhaustion-and-hooks.sh
source "$ROOT/tests/exhaustion-and-hooks.sh"
# shellcheck source=tests/captures-and-migration.sh
source "$ROOT/tests/captures-and-migration.sh"
# shellcheck source=tests/release.sh
source "$ROOT/tests/release.sh"
source "$ROOT/tests/security-hardening.sh"
source "$ROOT/tests/forward-and-preview.sh"
# shellcheck source=tests/v022.sh
source "$ROOT/tests/v022.sh"
# shellcheck source=tests/spend-ledger.sh
source "$ROOT/tests/spend-ledger.sh"
# Report timings for the common, non-warning path without imposing a flaky CI limit.
usage a 20
for operation in statusline guard; do
  started=$(jq -nr now)
  for iteration in 1 2 3 4 5; do
    if [ "$operation" = statusline ]; then relay statusline < "$ROOT/tests/fixtures/statusline.json" > /dev/null
    else guard_input | relay hook guard > /dev/null; fi
  done
  jq -nr --arg operation "$operation" --argjson start "$started" '"Average time " + $operation + ": " + (((now-$start)*1000/5|round)|tostring) + " ms (5 runs)."'
done
relay uninstall --purge > "$SANDBOX/uninstall"
check test ! -e "$XDG_CONFIG_HOME/claude-relay"
check test ! -e "$XDG_STATE_HOME/claude-relay"
printf 'Summary: %s tests, %s passed, %s failed.\n' "$TOTAL" "$((TOTAL-FAILED))" "$FAILED"
[ "$FAILED" -eq 0 ]
