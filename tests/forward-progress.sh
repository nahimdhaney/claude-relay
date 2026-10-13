#!/usr/bin/env bash
# Sourced by run.sh: live progress lines from forward's child stream.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS CLAUDE_RELAY_FORWARD_PROGRESS
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
STATE="$XDG_STATE_HOME/claude-relay"
rm -f "$STATE/tasks/"task-*.txt
rm -rf "$STATE/forwarded" "$STATE/exhausted" "$STATE/spend" "$STATE/usage/b"
usage a 98; usage b 10; usage c 60
CWD41=$(cd "$SANDBOX/project space" && pwd -P)
fwd41() {
  T41=$(relay task-path)
  printf 'TASKMARKER-41\n' > "$T41"
  rc=0; (cd "$SANDBOX/project space" && relay forward --task-file "$T41" "$@") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
}
progress41() { grep '^  · ' "$SANDBOX/err" || true; }
tool41() { jq -nc --arg n "$1" --argjson i "$2" '{type:"assistant",message:{content:[{type:"tool_use",id:"t",name:$n,input:$i}]}}'; }
export FAKE_CLAUDE_OUTPUT="$SANDBOX/child41.jsonl"
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"child-own"}'
  jq -nc --arg cwd "$CWD41" '{type:"assistant",message:{content:[
    {type:"text",text:"ASSISTANTMARKER-41"},
    {type:"tool_use",id:"1",name:"Read",input:{file_path:($cwd+"/lib/a.sh")}},
    {type:"tool_use",id:"2",name:"Edit",input:{file_path:"/etc/hosts",old_string:"EDITMARKER-41",new_string:"x"}}]}}'
  jq -nc '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"1",content:"TOOLRESULTMARKER-41"}]}}'
  tool41 Bash '{"command":"bash tests/run.sh\necho SECONDLINEMARKER-41"}'
  tool41 Bash '{"command":"make","description":"Run the tests"}'
  tool41 Grep "$(jq -nc --arg cwd "$CWD41" '{pattern:"TODO",path:($cwd+"/src")}')"
  tool41 LS "$(jq -nc --arg cwd "$CWD41" '{path:$cwd}')"
  tool41 Glob '{"pattern":"**/*.sh"}'
  tool41 WebFetch '{"url":"https://example.com/x","prompt":"PROMPTMARKER-41"}'
  tool41 TodoWrite '{"todos":[{"content":"TODOMARKER-41"}]}'
  printf '%s\n' '{"type":"assistant","message":{"content":"plain"}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":7}]}}'
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":4102444800,"unifiedWindows":{"five_hour":{"utilization":0.2,"resetsAt":4102444800}}}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"RESULTMARKER-41","total_cost_usd":0.3}'
} > "$FAKE_CLAUDE_OUTPUT"
cp "$FAKE_CLAUDE_OUTPUT" "$SANDBOX/stream41.jsonl"

# Tool calls become stderr lines; stdout holds only the result.
fwd41
check equals "$rc" 0
check equals "$(cat "$SANDBOX/out")" RESULTMARKER-41
cat > "$SANDBOX/expect41" <<'EXPECT41'
  · Read lib/a.sh
  · Edit /etc/hosts
  · Bash bash tests/run.sh
  · Bash Run the tests
  · Grep src
  · LS .
  · Glob **/*.sh
  · WebFetch https://example.com/x
  · TodoWrite
EXPECT41
progress41 > "$SANDBOX/actual41"
check cmp -s "$SANDBOX/expect41" "$SANDBOX/actual41"
check test "$(grep -c '·' "$SANDBOX/out" || true)" -eq 0
check test "$(grep -c 'MARKER-41' "$SANDBOX/err" || true)" -eq 0
# The profile line comes first, then progress lines.
check equals "$(head -1 "$SANDBOX/err" | cut -c1-21)" 'claude-relay: profile'
# Spend and usage are still recorded from the same stream.
SID41=$(jq -r '.args[5]' "$FAKE_LOG")
check jq -se 'length==1 and .[0].cost_usd==0.3' "$STATE/spend/b/"*.json
check jq -e '.source=="relay" and .rate_limits.five_hour.used_percentage==20' "$STATE/usage/b/$SID41.json"
check test "$(grep -rl 'MARKER-41' "$STATE" | wc -l | tr -d ' ')" -eq 0

# Control characters and escape sequences are stripped; long lines are cut.
{
  tool41 Bash "$(jq -nc --arg c "$(printf 'printf \033[31mred\033[0m\tand\001x   spaced\r')" '{command:$c}')"
  tool41 "$(printf 'Re\033ad')" '{"file_path":"/tmp/x"}'
  tool41 Bash "$(jq -nc --arg c "$(printf 'y%.0s' $(seq 1 500))" '{command:$c}')"
} > "$FAKE_CLAUDE_OUTPUT"
fwd41
progress41 > "$SANDBOX/actual41"
check equals "$(sed -n 1p "$SANDBOX/actual41")" '  · Bash printf [31mred[0m andx spaced'
check equals "$(sed -n 2p "$SANDBOX/actual41")" '  · Read /tmp/x'
check test "$(LC_ALL=C grep -c "$(printf '\033')" "$SANDBOX/err" || true)" -eq 0
check equals "$(sed -n 3p "$SANDBOX/actual41" | jq -R length)" 120
check equals "$(sed -n 3p "$SANDBOX/actual41" | jq -R '.[-1:]' -r)" '…'
# GNU cut -c counts bytes, not characters; jq counts characters on every platform.
check equals "$(sed -n 3p "$SANDBOX/actual41" | jq -Rr '.[0:12]')" '  · Bash yyy'

# Opt-out: --quiet, the environment and config; precedence flag > env > config.
cp "$SANDBOX/stream41.jsonl" "$FAKE_CLAUDE_OUTPUT"
fwd41 --quiet
check equals "$(progress41 | wc -l | tr -d ' ')" 0
check equals "$(cat "$SANDBOX/out")" RESULTMARKER-41
for value in 0 false; do
  CLAUDE_RELAY_FORWARD_PROGRESS=$value fwd41
  check equals "$(progress41 | wc -l | tr -d ' ')" 0
  check equals "$(cat "$SANDBOX/out")" RESULTMARKER-41
done
printf 'forward_progress=false\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
fwd41
check equals "$(progress41 | wc -l | tr -d ' ')" 0
CLAUDE_RELAY_FORWARD_PROGRESS=1 fwd41
check equals "$(progress41 | wc -l | tr -d ' ')" 9
CLAUDE_RELAY_FORWARD_PROGRESS=true fwd41 --quiet
check equals "$(progress41 | wc -l | tr -d ' ')" 0
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\nforward_progress=true\n' > "$XDG_CONFIG_HOME/claude-relay/config"
fwd41
check equals "$(progress41 | wc -l | tr -d ' ')" 9
# Invalid values refuse before launch and keep the task, even with --quiet.
cp "$FAKE_LOG" "$SANDBOX/launch41-before"
for value in yes 2 TRUE ' 1'; do
  CLAUDE_RELAY_FORWARD_PROGRESS=$value fwd41
  check test "$rc" -ne 0
  check grep -q 'CLAUDE_RELAY_FORWARD_PROGRESS' "$SANDBOX/err"
  check cmp -s "$FAKE_LOG" "$SANDBOX/launch41-before"
  check equals "$(cat "$T41")" TASKMARKER-41
  rm -f "$T41"
done
printf 'forward_progress=maybe\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
for flag in '' --quiet; do
  if [ -n "$flag" ]; then CLAUDE_RELAY_FORWARD_PROGRESS=1 fwd41 "$flag"; else fwd41; fi
  check test "$rc" -ne 0
  check grep -q 'forward_progress' "$SANDBOX/err"
  check cmp -s "$FAKE_LOG" "$SANDBOX/launch41-before"
  check equals "$(cat "$T41")" TASKMARKER-41
  rm -f "$T41"
done
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"

# The child's status survives the pipeline, and the buffer stays byte for byte.
cp "$SANDBOX/stream41.jsonl" "$FAKE_CLAUDE_OUTPUT"
FAKE_CLAUDE_STATUS=3 fwd41
check equals "$rc" 3
check equals "$(cat "$SANDBOX/out")" RESULTMARKER-41
check equals "$(progress41 | wc -l | tr -d ' ')" 9
FAKE_CLAUDE_SIGNAL=TERM fwd41
check equals "$rc" 143
check test ! -s "$SANDBOX/out"
check equals "$(find "$STATE/tasks" -type f | wc -l | tr -d ' ')" 0
printf 'no newline at end' > "$FAKE_CLAUDE_OUTPUT"
fwd41
check equals "$rc" 0
check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
printf '\377\376 invalid UTF-8\n\000nul' > "$FAKE_CLAUDE_OUTPUT"
fwd41
check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
# A 2 MB line without a final newline, and progress lines mixed with garbage.
head -c 2000000 /dev/zero | tr '\0' 'a' > "$FAKE_CLAUDE_OUTPUT"
FAKE_CLAUDE_STATUS=4 fwd41
check equals "$rc" 4
check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
{ cat "$SANDBOX/stream41.jsonl"; head -c 2000000 /dev/zero | tr '\0' 'b'; } > "$FAKE_CLAUDE_OUTPUT"
fwd41
check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
check equals "$(progress41 | wc -l | tr -d ' ')" 9
rm -rf "$STATE/spend" "$STATE/usage/b" "$STATE/exhausted"
unset FAKE_CLAUDE_OUTPUT
