#!/usr/bin/env bash
# Sourced by run.sh: v0.3.0 JSON child output and the relay spend ledger.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
rm -f "$STATE/tasks/"task-*.txt
rm -rf "$STATE/forwarded" "$STATE/exhausted" "$STATE/spend"
usage a 98; usage b 10; usage c 20
envelope() { printf '%s' "$2" > "$1"; }
fwd() {
  local t
  t=$(relay task-path)
  printf 'TASKMARKER-31\n' > "$t"
  rc=0; (cd "$SANDBOX/project space" && relay forward --task-file "$t" "$@") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
}
export FAKE_CLAUDE_OUTPUT="$SANDBOX/child.json"

# 1: argv uses json; .result + newline, byte for byte.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"line one\nline\ttwo ✓ 🐄\n","total_cost_usd":0.5,"modelUsage":{}}'
FAKE_CLAUDE_BUFFER_MODE="$SANDBOX/buffer-mode" fwd
check equals "$(cat "$SANDBOX/buffer-mode")" -rw-------
check equals "$rc" 0
check jq -e '.args[0:3]==["-p","--output-format","json"]' "$FAKE_LOG"
printf 'line one\nline\ttwo ✓ 🐄\n\n' > "$SANDBOX/expect"
check cmp -s "$SANDBOX/out" "$SANDBOX/expect"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":""}'
fwd; printf '\n' > "$SANDBOX/expect"; check cmp -s "$SANDBOX/out" "$SANDBOX/expect"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"  \n\t "}'
fwd; printf '  \n\t \n' > "$SANDBOX/expect"; check cmp -s "$SANDBOX/out" "$SANDBOX/expect"

# 2: exit status preserved, including disagreement with is_error.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
FAKE_CLAUDE_STATUS=3 fwd; check equals "$rc" 3; check equals "$(cat "$SANDBOX/out")" ok
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"partial"}'
fwd; check equals "$rc" 0
check equals "$(cat "$SANDBOX/out")" partial
check grep -qxF 'claude-relay: the child reported an error (error_max_turns).' "$SANDBOX/err"

# 3: error envelope without .result: empty stdout, stderr note; odd subtype -> unknown.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"Bad Subtype;rm","is_error":true,"total_cost_usd":0.1}'
FAKE_CLAUDE_STATUS=1 fwd
check equals "$rc" 1; check test ! -s "$SANDBOX/out"
check grep -qxF 'claude-relay: the child reported an error (unknown).' "$SANDBOX/err"

for subtype in null 1 false '[]' '{}' '""' '"success\n"'; do
  envelope "$FAKE_CLAUDE_OUTPUT" "{\"type\":\"result\",\"is_error\":true,\"result\":\"partial\",\"subtype\":$subtype}"
  fwd
  check equals "$(cat "$SANDBOX/out")" partial
  check grep -qxF 'claude-relay: the child reported an error (unknown).' "$SANDBOX/err"
done

# 4: not an envelope -> byte-identical passthrough.
for raw in 'plain text' 'no newline at end' '{"type":"result","is_error":false}{"x":1}' '{"type":"result","is_error":false} garbage' '{}' '[1]' 'null' 'true' '1' '"text"' '{"type":"result","is_error":null}' '{"type":"other","is_error":false}'; do
  printf '%s' "$raw" > "$FAKE_CLAUDE_OUTPUT"
  fwd
  check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
done
: > "$FAKE_CLAUDE_OUTPUT"; fwd; check test ! -s "$SANDBOX/out"

# Review focus 1: about 2 MB result, byte-identical.
jq -n '{type:"result",subtype:"success",is_error:false,result:([range(0;60000)]|map("row \(.) ✓ 0123456789abcdef")|join("\n"))}' > "$FAKE_CLAUDE_OUTPUT"
fwd
jq -j .result "$FAKE_CLAUDE_OUTPUT" > "$SANDBOX/expect"; printf '\n' >> "$SANDBOX/expect"
check cmp -s "$SANDBOX/out" "$SANDBOX/expect"

# 6 (buffer part) + 14: no buffer left; killed child -> 143, task and buffer gone.
check equals "$(find "$STATE/tasks" -name 'out-*' | wc -l | tr -d ' ')" 0
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"x"}'
FAKE_CLAUDE_SIGNAL=TERM fwd
check equals "$rc" 143
check equals "$(find "$STATE/tasks" -type f | wc -l | tr -d ' ')" 0
mkdir -p "$STATE/tasks"; : > "$STATE/tasks/out-OLD123"; : > "$STATE/tasks/out-NEW123"
touch -t 200001010000 "$STATE/tasks/out-OLD123"
relay task-path > /dev/null
check test ! -e "$STATE/tasks/out-OLD123"
check test -e "$STATE/tasks/out-NEW123"
rm -f "$STATE/tasks/out-NEW123"
# Buffer pruning skips symlinks and leaves their targets intact.
printf keep > "$SANDBOX/output-target"
ln -s "$SANDBOX/output-target" "$STATE/tasks/out-LINK123"
relay task-path > /dev/null
check test -L "$STATE/tasks/out-LINK123"
check equals "$(cat "$SANDBOX/output-target")" keep
rm -f "$STATE/tasks/out-LINK123"
unset FAKE_CLAUDE_OUTPUT
