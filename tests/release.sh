#!/usr/bin/env bash
# Sourced by run.sh. Every input is synthetic and confined to its sandbox.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
rm -rf "$STATE/usage" "$STATE/exhausted" "$STATE/warned"
# Fifteen anonymized captures share a weekly deadline. Four current sessions
# agree on 2%; eleven idle sessions repeat stale values up to 94%.
mkdir -p "$STATE/usage/a"
for n in 1 2 3 4; do
  jq -n --arg sid "active-$n" '{session_id:$sid,captured_at:now,rate_limits:{five_hour:{used_percentage:1,resets_at:4102444800},seven_day:{used_percentage:2,resets_at:4102444800}}}' > "$STATE/usage/a/active-$n.json"
done
n=0
for pct in 7 11 13 23 24 50 84 94 11 23 94; do
  n=$((n+1))
  jq -n --arg sid "idle-$n" --argjson pct "$pct" '{session_id:$sid,captured_at:now,rate_limits:{seven_day:{used_percentage:$pct,resets_at:4102444800}}}' > "$STATE/usage/a/idle-$n.json"
done
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==2 and .[0].seven_day.used_percentage==2 and .[0].capture_count==4'
guard_input | relay hook guard > "$SANDBOX/out"
check test ! -s "$SANDBOX/out"
# Prefer latest reset, then highest usage, within the current subset.
jq '.rate_limits.seven_day={used_percentage:1,resets_at:4102444900}' "$STATE/usage/a/active-1.json" > "$STATE/usage/a/active-later.json"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].seven_day.used_percentage==1 and .[0].seven_day.resets_at==4102444900'
rm "$STATE/usage/a/active-later.json"
# No current capture: retain the conservative fallback.
for file in "$STATE/usage/a/active-"*.json; do
  jq '.rate_limits.five_hour.resets_at=1' "$file" > "$SANDBOX/expired"
  mv "$SANDBOX/expired" "$file"
done
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==94 and .[0].capture_count==15'
# Stale current captures must not displace fresh idle ones.
jq '.captured_at=now-22000 | .rate_limits.five_hour.resets_at=4102444800' "$STATE/usage/a/active-1.json" > "$SANDBOX/stale"
mv "$SANDBOX/stale" "$STATE/usage/a/active-1.json"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==94 and .[0].capture_count==14'
check equals "$(relay --version)" 'claude-relay 0.2.2'
check equals "$(cat "$ROOT/VERSION" 2>/dev/null)" 0.2.2
# run preserves stdin verbatim, without interpolating or adding it to argv.
cp "$CLAUDE_RELAY_CLAUDE_BIN" "$SANDBOX/fake-original"
cat >> "$CLAUDE_RELAY_CLAUDE_BIN" <<'STDIN'
if [ "${1:-}" = -p ]; then cat > "$FAKE_STDIN"; fi
STDIN
export FAKE_STDIN="$SANDBOX/prompt-received"
cat > "$SANDBOX/prompt" <<'PROMPT_7fe31c'
quotes ' " ; $(touch SHOULD_NOT_EXIST) `touch ALSO_NOT` $HOME
--profile ../escape
TASK
PROMPT_7fe31c
(cd "$SANDBOX" && relay run --profile a -- -p --output-format text) < "$SANDBOX/prompt" > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$SANDBOX/prompt" "$FAKE_STDIN"
check json_is "$FAKE_LOG" '.depth=="1" and .args==["-p","--output-format","text"]'
cp "$FAKE_LOG" "$SANDBOX/no-launch"
rc=0; CLAUDE_RELAY_DEPTH=1 relay run --profile a -- -p < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check grep -q 'max_depth' "$SANDBOX/err"
check cmp -s "$FAKE_LOG" "$SANDBOX/no-launch"
CLAUDE_RELAY_MAX_DEPTH=2 CLAUDE_RELAY_DEPTH=1 relay run --profile a -- -p < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.depth=="2"'
printf 'max_depth=2\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
CLAUDE_RELAY_DEPTH=1 relay run --profile a -- -p < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.depth=="2"'
for depth in -1 'x[$(touch SHOULD_NOT_EXIST)]' 1.5 999999999999999999999999999999; do
  rc=0; (cd "$SANDBOX" && CLAUDE_RELAY_DEPTH="$depth" relay run --profile a -- -p) < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
done
CLAUDE_RELAY_DEPTH=99 relay resume --session session-one --to b > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.depth=="unset" and .args==["--resume","session-one"]'
check test ! -e "$SANDBOX/SHOULD_NOT_EXIST"
check test ! -e "$SANDBOX/ALSO_NOT"
# Exercise the deterministic forwarder with a hostile task as literal data.
printf '%s\n' '#!/usr/bin/env bash' 'task=$(claude-relay task-path)' 'printf "%s\n" "$task" > "$SANDBOX/forward-path"' 'cp "$SANDBOX/prompt" "$task"' 'claude-relay forward --task-file "$task"' > "$SANDBOX/forwarder.sh"
export SANDBOX
ln -s "$CLI" "$SANDBOX/fake/claude-relay"
(cd "$SANDBOX" && "$BASH" "$SANDBOX/forwarder.sh") > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$SANDBOX/prompt" "$FAKE_STDIN"
check json_is "$FAKE_LOG" '.depth=="1" and .args[0:4]==["-p","--output-format","text","--session-id"] and .args[5:]==["--permission-mode","plan"]'
check test ! -e "$SANDBOX/SHOULD_NOT_EXIST"
check test ! -e "$SANDBOX/ALSO_NOT"
check equals "$(find "$STATE/tasks" -name 'task-*.txt' | wc -l | tr -d ' ')" 0
cp "$FAKE_LOG" "$SANDBOX/no-launch"
rc=0; CLAUDE_RELAY_DEPTH=0 "$BASH" "$SANDBOX/forwarder.sh" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check cmp -s "$FAKE_LOG" "$SANDBOX/no-launch"
REFUSED_TASK=$(cat "$SANDBOX/forward-path")
check cmp -s "$SANDBOX/prompt" "$REFUSED_TASK"
printf '\nexit 7\n' >> "$CLAUDE_RELAY_CLAUDE_BIN"
rc=0; (cd "$SANDBOX" && "$BASH" "$SANDBOX/forwarder.sh") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 7
check test ! -e "$(cat "$SANDBOX/forward-path")"
check equals "$(find "$STATE/tasks" -name 'task-*.txt' | wc -l | tr -d ' ')" 1
check cmp -s "$SANDBOX/prompt" "$REFUSED_TASK"
rm "$REFUSED_TASK"
rm "$SANDBOX/fake/claude-relay"
cp "$SANDBOX/fake-original" "$CLAUDE_RELAY_CLAUDE_BIN"
# Multiple JSON documents must never become a wrapper command.
printf 'wrapped_statusline=touch %s\n' "$SANDBOX/untrusted-execution" >> "$XDG_CONFIG_HOME/claude-relay/config"
printf '{}\n{}\n' | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -e "$SANDBOX/untrusted-execution"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
# Existing loose directories get tightened when relay writes.
chmod 755 "$STATE" "$STATE/usage" "$STATE/usage/a"
capture_input private model-a 2 | relay statusline > "$SANDBOX/out"
for dir in "$STATE" "$STATE/usage" "$STATE/usage/a"; do
  check equals "$(LC_ALL=C ls -ld "$dir" | cut -c1-10)" 'drwx------'
done
# Reject symlinked write destinations, including non-atomic append targets.
printf 'untouched\n' > "$SANDBOX/victim"
rm -f "$STATE/events.log"
ln -s "$SANDBOX/victim" "$STATE/events.log"
printf '{"error":"ordinary"}' | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(cat "$SANDBOX/victim")" untouched
check test ! -s "$SANDBOX/err"
rm "$STATE/events.log"
mv "$STATE/usage/a" "$STATE/usage/a-kept"
ln -s "$SANDBOX" "$STATE/usage/a"
capture_input escaped model-a 2 | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -e "$SANDBOX/escaped.json"
check test ! -s "$SANDBOX/out"
rm "$STATE/usage/a"
mv "$STATE/usage/a-kept" "$STATE/usage/a"
# A sibling profile symlink must not be read or traversed by pruning.
mkdir -p "$SANDBOX/unrelated-state"
jq -n '{captured_at:1}' > "$SANDBOX/unrelated-state/old.json"
ln -s "$SANDBOX/unrelated-state" "$STATE/usage/sibling-link"
rm -f "$STATE/prune.json"
capture_input prune-safe model-a 2 | relay statusline > "$SANDBOX/out"
check test -f "$SANDBOX/unrelated-state/old.json"
rm "$STATE/usage/sibling-link"
# Discovery and onboarding use another isolated HOME so the prior pool cannot
# hide first-install cases. Do not inherit the current profile from run.sh.
saved_home=$HOME saved_config=$XDG_CONFIG_HOME saved_state=$XDG_STATE_HOME saved_profiles=$CLAUDE_PROFILES_ROOT saved_current=$CLAUDE_CONFIG_DIR
export HOME="$SANDBOX/onboarding" XDG_CONFIG_HOME="$SANDBOX/onboarding/config" XDG_STATE_HOME="$SANDBOX/onboarding/state"
export CLAUDE_PROFILES_ROOT="$HOME/profiles" CLAUDE_CONFIG_DIR="$HOME/.claude"
mkdir -p "$HOME/.claude" "$CLAUDE_PROFILES_ROOT/side" "$CLAUDE_PROFILES_ROOT/logged-out"
printf '{"oauthAccount":{"emailAddress":"person@example.test","organizationName":"Example"},"ignored":"DO_NOT_EXPOSE"}\n' > "$HOME/.claude/.claude.json"
printf '{broken' > "$CLAUDE_PROFILES_ROOT/logged-out/.claude.json"
rc=0; relay detect --json > "$SANDBOX/detect" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 0
check json_is "$SANDBOX/detect" 'length==3 and .[0].name=="default" and .[0].logged_in and .[0].email=="person@example.test" and .[0].organization=="Example" and (all(.[]; .in_pool==false))'
check json_is "$SANDBOX/detect" 'tostring | contains("DO_NOT_EXPOSE") | not'
rc=0; relay install --dry-run > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 0
check test ! -e "$XDG_CONFIG_HOME/claude-relay"
relay install --with-agent > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(cut -f1 "$XDG_CONFIG_HOME/claude-relay/pool")" default
# External --settings parents are user-owned; installing must not chmod them.
mkdir -p "$HOME/shared-settings"
chmod 755 "$HOME/shared-settings"
relay install --settings "$HOME/shared-settings/settings.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(LC_ALL=C ls -ld "$HOME/shared-settings" | cut -c1-10)" 'drwxr-xr-x'
chmod 755 "$XDG_CONFIG_HOME/claude-relay"
relay install > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(LC_ALL=C ls -ld "$XDG_CONFIG_HOME/claude-relay" | cut -c1-10)" 'drwx------'
for file in "$XDG_CONFIG_HOME/claude-relay/"*; do
  check equals "$(LC_ALL=C ls -l "$file" | cut -c1-10)" '-rw-------'
done
relay detect --json > "$SANDBOX/detect" 2> "$SANDBOX/err" || true
check json_is "$SANDBOX/detect" '.[0].in_pool==true'
# Upgrade with no options reuses the pool/settings/agent, even with more logins.
printf '{"oauthAccount":{"emailAddress":"side@example.test"}}\n' > "$CLAUDE_PROFILES_ROOT/side/.claude.json"
cp "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/reuse-pool"
relay install > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/reuse-pool"
check test -f "$XDG_CONFIG_HOME/claude-relay/agent.cksum"
# Simulate the recorded previous release without modifying checkout templates.
printf 'old relay template\n' > "$HOME/.claude/agents/relay.md"
cksum < "$HOME/.claude/agents/relay.md" > "$XDG_CONFIG_HOME/claude-relay/agent.cksum"
relay install > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$ROOT/agents/relay.md" "$HOME/.claude/agents/relay.md"
check equals "$(cat "$XDG_CONFIG_HOME/claude-relay/agent.cksum")" "$(cksum < "$ROOT/agents/relay.md")"
printf '\nuser edit\n' >> "$HOME/.claude/agents/relay.md"
rc=0; relay install --with-agent > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check grep -q 'edited' "$SANDBOX/err"
relay uninstall > "$SANDBOX/out"
check test -f "$HOME/.claude/agents/relay.md"
# Uninstall uses the record even when it differs from the current template.
printf 'old relay template\n' > "$HOME/.claude/agents/relay.md"
cksum < "$HOME/.claude/agents/relay.md" > "$XDG_CONFIG_HOME/claude-relay/agent.cksum"
relay uninstall > "$SANDBOX/out"
check test ! -e "$HOME/.claude/agents/relay.md"
rm "$XDG_CONFIG_HOME/claude-relay/pool"
rc=0; relay install > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 2
check grep -q 'choose with --profiles a,b or --profile name=dir' "$SANDBOX/err"
check grep -q 'side@example.test' "$SANDBOX/out"
check test ! -e "$XDG_CONFIG_HOME/claude-relay/pool"
rm "$HOME/.claude/.claude.json" "$CLAUDE_PROFILES_ROOT/side/.claude.json"
rc=0; relay install > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 2
check test ! -e "$XDG_CONFIG_HOME/claude-relay/pool"
export HOME=$saved_home XDG_CONFIG_HOME=$saved_config XDG_STATE_HOME=$saved_state CLAUDE_PROFILES_ROOT=$saved_profiles CLAUDE_CONFIG_DIR=$saved_current
write_pool

#!/usr/bin/env bash
# Review regressions run by the existing sandboxed test harness.
# A literal shell-sensitive checkout path must stay data in settings and traps.
relay uninstall > "$SANDBOX/out"
quoted_checkout="$SANDBOX/checkout ' quote \$(touch INJECTED) \`touch INJECTED2\`"
mkdir -p "$quoted_checkout"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/agents" "$quoted_checkout/"
cp "$ROOT/VERSION" "$quoted_checkout/VERSION"
"$BASH" "$quoted_checkout/bin/claude-relay" install --profiles a,b --settings "$SANDBOX/quoted-settings.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
quoted_command=$(jq -r .statusLine.command "$SANDBOX/quoted-settings.json")
(cd "$SANDBOX" && "$BASH" -c "$quoted_command") < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 41%'
check test ! -e "$SANDBOX/INJECTED"
check test ! -e "$SANDBOX/INJECTED2"
check test ! -s "$SANDBOX/err"
"$BASH" "$quoted_checkout/bin/claude-relay" uninstall > "$SANDBOX/out"
write_pool
# Wrapped statusline receives the exact original bytes but never evals input.
printf 'wrapped_statusline=cat > "%s"\n' "$SANDBOX/wrapper-input" > "$XDG_CONFIG_HOME/claude-relay/config"
jq -n --arg sid '$(touch INJECTED)' '{session_id:$sid}' > "$SANDBOX/hostile-input"
(cd "$SANDBOX" && relay statusline) < "$SANDBOX/hostile-input" > "$SANDBOX/out"
check cmp -s "$SANDBOX/hostile-input" "$SANDBOX/wrapper-input"
check test ! -e "$SANDBOX/INJECTED"
rm "$SANDBOX/wrapper-input"
cat "$SANDBOX/hostile-input" "$SANDBOX/hostile-input" | (cd "$SANDBOX" && relay statusline) > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check test ! -e "$SANDBOX/wrapper-input"
check test ! -e "$SANDBOX/INJECTED"
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"

# Isolated edge cases: reserved names, hidden directories, aliases, env path.
saved_home=$HOME saved_config=$XDG_CONFIG_HOME saved_state=$XDG_STATE_HOME saved_profiles=$CLAUDE_PROFILES_ROOT saved_current=$CLAUDE_CONFIG_DIR
export HOME="$SANDBOX/discovery" XDG_CONFIG_HOME="$SANDBOX/discovery/config" XDG_STATE_HOME="$SANDBOX/discovery/state"
export CLAUDE_PROFILES_ROOT="$HOME/profiles" CLAUDE_CONFIG_DIR="$HOME/external"
mkdir -p "$HOME/.claude" "$CLAUDE_PROFILES_ROOT/side" "$CLAUDE_PROFILES_ROOT/.hidden" "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME/claude-relay"
printf 'default\t%s\n' "$CLAUDE_PROFILES_ROOT/side" > "$XDG_CONFIG_HOME/claude-relay/pool"
ln -s "$HOME/.claude" "$CLAUDE_PROFILES_ROOT/alias"
printf '{"oauthAccount":{"emailAddress":"$(touch INJECTED)","organizationName":"`touch INJECTED2`"}}\n' > "$HOME/external/.claude.json"
(cd "$SANDBOX" && relay detect --json) > "$SANDBOX/detect"
check json_is "$SANDBOX/detect" 'length==4 and ([.[].name]|unique|length)==4 and any(.[]; .in_pool and .name=="default" and (.path|endswith("/side")))'
check json_is "$SANDBOX/detect" 'any(.[]; .name=="hidden" and (.logged_in|not)) and any(.[]; (.path|endswith("/external")) and .logged_in)'
check test ! -e "$SANDBOX/INJECTED"
check test ! -e "$SANDBOX/INJECTED2"
# A no-options upgrade cannot silently retain an unrecorded legacy forwarder.
relay install --with-agent > "$SANDBOX/out" 2> "$SANDBOX/err"
rm "$XDG_CONFIG_HOME/claude-relay/agent.cksum"
printf 'unrecorded older relay agent\n' > "$HOME/.claude/agents/relay.md"
rc=0; relay install > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check grep -q 'Move it aside' "$SANDBOX/err"
check equals "$(cat "$HOME/.claude/agents/relay.md")" 'unrecorded older relay agent'
# A current template can safely acquire a missing record.
cp "$ROOT/agents/relay.md" "$HOME/.claude/agents/relay.md"
relay install > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(cat "$XDG_CONFIG_HOME/claude-relay/agent.cksum" 2>/dev/null)" "$(cksum < "$ROOT/agents/relay.md")"
cp "$HOME/.claude/agents/relay.md" "$SANDBOX/agent-before"
cp "$XDG_CONFIG_HOME/claude-relay/agent.cksum" "$SANDBOX/checksum-before" 2>/dev/null || true
relay install --dry-run > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$HOME/.claude/agents/relay.md" "$SANDBOX/agent-before"
check cmp -s "$XDG_CONFIG_HOME/claude-relay/agent.cksum" "$SANDBOX/checksum-before"
for max in -1 1.5 invalid 99999999999999999999999; do
  rc=0; CLAUDE_RELAY_MAX_DEPTH="$max" relay run --profile default -- < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
done
rc=0; CLAUDE_RELAY_MAX_DEPTH=0 relay run --profile default -- -p < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
export HOME=$saved_home XDG_CONFIG_HOME=$saved_config XDG_STATE_HOME=$saved_state CLAUDE_PROFILES_ROOT=$saved_profiles CLAUDE_CONFIG_DIR=$saved_current
# Current captures without a weekly window do not borrow an idle weekly value.
jq -n -L "$ROOT/lib" 'include "usage"; [
  {captured_at:now,session_id:"current",rate_limits:{five_hour:{used_percentage:1,resets_at:4102444800}}},
  {captured_at:now,session_id:"idle",rate_limits:{seven_day:{used_percentage:99,resets_at:4102444800}}}
] | measurements(50;21600)' > "$SANDBOX/current-only"
check json_is "$SANDBOX/current-only" '.score==1 and .seven_day==null and .capture_count==1'
