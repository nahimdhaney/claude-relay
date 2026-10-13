#!/usr/bin/env bash
# Sourced by run.sh: v0.4.0 stream-json child output and relay usage captures.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
STATE="$XDG_STATE_HOME/claude-relay"
rm -f "$STATE/tasks/"task-*.txt
rm -rf "$STATE/forwarded" "$STATE/exhausted" "$STATE/spend"
# a is above handoff_at, so every new child goes to b unless b is exhausted.
usage a 98; usage c 60
reset_b() { rm -rf "$STATE/usage/b" "$STATE/exhausted" "$STATE/spend"; usage b 10; }
fwd40() {
  local t
  t=$(relay task-path)
  printf 'TASKMARKER-40\n' > "$t"
  rc=0; (cd "$SANDBOX/project space" && relay forward --task-file "$t" "$@") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  SID40=$(jq -r '.args[5]' "$FAKE_LOG")
}
stream() { printf '%s\n' "$@" > "$FAKE_CLAUDE_OUTPUT"; }
# One rate_limit_event line: unifiedWindows JSON, status, top-level resetsAt.
rl() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":%s},"session_id":"child-own"}' "${2:-allowed}" "${3:-4102444800}" "$1"; }
win() { printf '{"utilization":%s,"resetsAt":%s}' "$1" "${2:-4102444800}"; }
# ev STATUS RESET [KEY WINDOW]...: Bash 3.2 mangles \" inside nested $(...),
# so windows are joined here instead of quoted at each call site.
ev() {
  local status=$1 reset=$2 windows='' sep=''
  shift 2
  while [ "$#" -gt 1 ]; do windows="$windows$sep\"$1\":$2"; sep=,; shift 2; done
  rl "{$windows}" "$status" "$reset"
}
STRWIN='{"utilization":"0.5","resetsAt":4102444800}'
NORESET='{"utilization":0.3}'
done40() { [ "$(cat "$SANDBOX/out")" = done ]; }
INIT='{"type":"system","subtype":"init","session_id":"child-own"}'
RESULT='{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.5}'
capture40() { printf '%s' "$STATE/usage/b/$SID40.json"; }
count40() { find "$1" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
export FAKE_CLAUDE_OUTPUT="$SANDBOX/child.jsonl"

# 1 + 2: argv; init + assistant + rate_limit_event + result renders the result.
reset_b
cp "$ROOT/tests/fixtures/stream.jsonl" "$FAKE_CLAUDE_OUTPUT"
FAKE_CLAUDE_STATUS=5 fwd40
check equals "$rc" 5
check jq -e '.args[0:5]==["-p","--output-format","stream-json","--verbose","--session-id"] and .args[6:]==["--permission-mode","plan"]' "$FAKE_LOG"
printf 'RESULTMARKER-40 ✓\n\n' > "$SANDBOX/expect"
check cmp -s "$SANDBOX/out" "$SANDBOX/expect"
# Only the profile line: the worker never echoes captures.
check equals "$(wc -l < "$SANDBOX/err" | tr -d ' ')" 1
check jq -se --arg s "$SID40" 'length==1 and .[0].cost_usd==0.75 and .[0].session_id==$s and .[0].models.m.in==3' "$STATE/spend/b/"*.json

# 3: the last of several results is rendered and recorded.
reset_b
stream "$INIT" '{"type":"result","is_error":false,"result":"first","total_cost_usd":0.1}' \
  '{"type":"assistant"}' '{"type":"result","is_error":false,"result":"second","total_cost_usd":0.2}'
fwd40
check equals "$(cat "$SANDBOX/out")" second
check jq -se 'length==1 and .[0].cost_usd==0.2' "$STATE/spend/b/"*.json

# 4: five_hour 0.06 and seven_day 0.34 become 6 and 34 in the child profile.
reset_b
cp "$ROOT/tests/fixtures/stream.jsonl" "$FAKE_CLAUDE_OUTPUT"
fwd40
check jq -e --arg s "$SID40" '.profile=="b" and .session_id==$s and .source=="relay" and .model==null
  and (.captured_at|type)=="number" and .captured_at<=now and .captured_at>now-60
  and .rate_limits=={five_hour:{used_percentage:6,resets_at:4102444800},seven_day:{used_percentage:34,resets_at:4102448400}}
  and keys==["captured_at","model","profile","rate_limits","session_id","source"]' "$(capture40)"
check test ! -e "$STATE/usage/a/$SID40.json"
relay status --json > "$SANDBOX/status40"
check json_is "$SANDBOX/status40" '.[1].profile=="b" and .[1].known==true and .[1].score==34 and .[1].five_hour.used_percentage==6'

# 5: a Team seat sends only five_hour.
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.25)")" "$RESULT"
fwd40
check done40
check jq -e '.rate_limits=={five_hour:{used_percentage:25,resets_at:4102444800}}' "$(capture40)"

# 6: invalid windows are dropped; utilization above 1 is clamped.
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$STRWIN" seven_day "$(win 0.3 -1)")" "$RESULT"
fwd40
check done40
check test ! -e "$(capture40)"
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 1e999)" seven_day "$NORESET")" "$RESULT"
fwd40
check done40
check test ! -e "$(capture40)"
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.2 1e999)" seven_day '[1]')" "$RESULT"
fwd40
check done40
check test ! -e "$(capture40)"
for windows in null '[]' '"x"' '{}'; do
  stream "$INIT" "$(rl "$windows")" "$RESULT"
  fwd40
  check done40
  check test ! -e "$(capture40)"
done
check equals "$rc" 0
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 1.7)" seven_day "$STRWIN" other "$(win 0.9)")" "$RESULT"
fwd40
check jq -e '.rate_limits=={five_hour:{used_percentage:100,resets_at:4102444800}}' "$(capture40)"
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win -0.2)" seven_day "$(win 0.1234)")" "$RESULT"
fwd40
check jq -e '.rate_limits.five_hour.used_percentage==0 and .rate_limits.seven_day.used_percentage==12.34' "$(capture40)"
# The last valid event wins over earlier ones.
reset_b
stream "$(ev allowed 4102444800 five_hour "$(win 0.5)")" "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.07)")" \
  '{"type":"rate_limit_event","rate_limit_info":{}}' "$RESULT"
fwd40
check jq -e '.rate_limits.five_hour.used_percentage==7' "$(capture40)"

# 7: rejected with a future reset marks the child exhausted until then.
reset_b
stream "$INIT" "$(ev rejected 4102444800 five_hour "$(win 1)")" "$RESULT"
fwd40
check jq -e '.profile=="b" and .source=="relay" and .until==4102444800' "$STATE/exhausted/b.json"
relay status --json > "$SANDBOX/status40"
check json_is "$SANDBOX/status40" '.[1].exhausted==true and .[1].score==100'
reset_b
stream "$INIT" "$(ev rejected 1000 five_hour "$(win 1)")" "$RESULT"
fwd40
check done40
check test ! -e "$STATE/exhausted/b.json"
stream "$INIT" "$(ev rejected '"4102444800"' five_hour "$(win 0.2)")" "$RESULT"
fwd40
check done40
check test ! -e "$STATE/exhausted/b.json"
stream "$INIT" "$(ev allowed_warning 4102444800 five_hour "$(win 0.2)")" "$RESULT"
fwd40
check done40
check test ! -e "$STATE/exhausted/b.json"

# 8: a stream without a result prints nothing, records usage, no spend.
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.4)")"
FAKE_CLAUDE_STATUS=2 fwd40
check equals "$rc" 2
check test ! -s "$SANDBOX/out"
check grep -qxF 'claude-relay: the child ended without a result.' "$SANDBOX/err"
check jq -e '.rate_limits.five_hour.used_percentage==40' "$(capture40)"
check equals "$(count40 "$STATE/spend")" 0

# 9: --continue updates the same capture file.
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.06)" seven_day "$(win 0.34)")" "$RESULT"
fwd40
FIRST40=$SID40
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.1)" seven_day "$(win 0.4)")" "$RESULT"
fwd40 --continue "$FIRST40"
check equals "$rc" 0
check equals "$(cat "$SANDBOX/out")" done
check equals "$(count40 "$STATE/usage/b")" 1
check jq -e --arg s "$FIRST40" '.session_id==$s and .rate_limits.five_hour.used_percentage==10 and .rate_limits.seven_day.used_percentage==40' "$STATE/usage/b/$FIRST40.json"

# 10: buffers that are not a stream pass through and record nothing.
reset_b
RL40=$(ev allowed 4102444800 five_hour "$(win 0.3)")
for raw in 'plain text' '{}' '[1]' '{"x":1}' '{"type":1}' "$RL40"$'\n''[1]' "$RL40"$'\n''{"x":1}' "$RL40 garbage" "$RL40"$'\n'"$RESULT"$'\n''trailing'; do
  printf '%s' "$raw" > "$FAKE_CLAUDE_OUTPUT"
  fwd40
  check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
done
check equals "$(count40 "$STATE/usage/b")" 0
check equals "$(count40 "$STATE/spend")" 0

# 11: a recording failure warns and leaves output and status unchanged.
reset_b
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.2)")" "$RESULT"
fwd40
FIRST40=$SID40
# A symlinked usage tree also blocks pick, so continue the recorded session.
mv "$STATE/usage" "$SANDBOX/usage-kept40"
mkdir -p "$SANDBOX/usage-elsewhere40"
ln -s "$SANDBOX/usage-elsewhere40" "$STATE/usage"
FAKE_CLAUDE_STATUS=6 fwd40 --continue "$FIRST40"
check equals "$rc" 6
check equals "$(cat "$SANDBOX/out")" done
check grep -qxF 'claude-relay: could not record relay run data.' "$SANDBOX/err"
check test -z "$(ls -A "$SANDBOX/usage-elsewhere40")"
# The spend part is still attempted.
check equals "$(count40 "$STATE/spend/b")" 2
rm "$STATE/usage"; mv "$SANDBOX/usage-kept40" "$STATE/usage"
# The worker validates like v0.3.0 and never writes stdout.
BUFFER40="$STATE/tasks/out-worker40"
stream "$INIT" "$(ev allowed 4102444800 five_hour "$(win 0.3)")"
cp "$FAKE_CLAUDE_OUTPUT" "$BUFFER40"; chmod 600 "$BUFFER40"
rc=0; relay __record-run b "$FIRST40" "$BUFFER40" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 0
check test ! -s "$SANDBOX/out"
check jq -e '.rate_limits.five_hour.used_percentage==30' "$STATE/usage/b/$FIRST40.json"
for bad in profile session buffer; do
  case "$bad" in
    profile) set -- zz "$FIRST40" "$BUFFER40" ;;
    session) set -- b not-a-uuid "$BUFFER40" ;;
    buffer) set -- b "$FIRST40" "$FAKE_CLAUDE_OUTPUT" ;;
  esac
  rc=0; relay __record-run "$@" > "$SANDBOX/out" 2>/dev/null || rc=$?
  check test "$rc" -ne 0
  check test ! -s "$SANDBOX/out"
done
set --
chmod 644 "$BUFFER40"
rc=0; relay __record-run b "$FIRST40" "$BUFFER40" 2>/dev/null || rc=$?
check test "$rc" -ne 0
rm -f "$BUFFER40"
rc=0; relay __record-spend b "$FIRST40" "$BUFFER40" > /dev/null 2>&1 || rc=$?
check test "$rc" -ne 0

# 12: no task or result text outside the transient buffer; private modes.
reset_b
rm -rf "$STATE/usage/b"
cp "$ROOT/tests/fixtures/stream.jsonl" "$FAKE_CLAUDE_OUTPUT"
FAKE_CLAUDE_BUFFER_MODE="$SANDBOX/buffer-mode40" fwd40
check equals "$(cat "$SANDBOX/buffer-mode40")" -rw-------
check test -f "$(capture40)"
check equals "$(find "$STATE/tasks" -type f | wc -l | tr -d ' ')" 0
check test "$(grep -rl 'TASKMARKER-40\|RESULTMARKER-40\|ASSISTANTMARKER-40' "$STATE" | wc -l | tr -d ' ')" -eq 0
check equals "$(LC_ALL=C ls -ld "$STATE/usage" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -ld "$STATE/usage/b" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -l "$(capture40)" | cut -c1-10)" -rw-------
reset_b
unset FAKE_CLAUDE_OUTPUT
