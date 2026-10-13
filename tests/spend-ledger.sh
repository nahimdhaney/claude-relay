#!/usr/bin/env bash
# Sourced by run.sh: single-envelope child output and the relay spend ledger.
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

# 1: argv uses stream-json; .result + newline, byte for byte.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"line one\nline\ttwo ✓ 🐄\n","total_cost_usd":0.5,"modelUsage":{}}'
FAKE_CLAUDE_BUFFER_MODE="$SANDBOX/buffer-mode" fwd
check equals "$(cat "$SANDBOX/buffer-mode")" -rw-------
check equals "$rc" 0
check jq -e '.args[0:4]==["-p","--output-format","stream-json","--verbose"]' "$FAKE_LOG"
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
check jq -se 'any(.[]; .is_error and .cost_usd==0.1)' "$STATE/spend/b/"*.json

for subtype in null 1 false '[]' '{}' '""' '"success\n"'; do
  envelope "$FAKE_CLAUDE_OUTPUT" "{\"type\":\"result\",\"is_error\":true,\"result\":\"partial\",\"subtype\":$subtype}"
  fwd
  check equals "$(cat "$SANDBOX/out")" partial
  check grep -qxF 'claude-relay: the child reported an error (unknown).' "$SANDBOX/err"
done

# 4: not an envelope -> byte-identical passthrough.
BEFORE_RAW=$(find "$STATE/spend" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
for raw in 'plain text' 'no newline at end' '{"type":"result","is_error":false}{"x":1}' '{"type":"result","is_error":false} garbage' '{}' '[1]' 'null' 'true' '1' '"text"'; do
  printf '%s' "$raw" > "$FAKE_CLAUDE_OUTPUT"
  fwd
  check cmp -s "$SANDBOX/out" "$FAKE_CLAUDE_OUTPUT"
done
: > "$FAKE_CLAUDE_OUTPUT"; fwd; check test ! -s "$SANDBOX/out"
# Typed objects without a boolean is_error are a stream with no result (v0.4.0).
for raw in '{"type":"result","is_error":null}' '{"type":"other","is_error":false}'; do
  printf '%s' "$raw" > "$FAKE_CLAUDE_OUTPUT"
  fwd
  check test ! -s "$SANDBOX/out"
  check grep -qxF 'claude-relay: the child ended without a result.' "$SANDBOX/err"
done
check equals "$(find "$STATE/spend" -type f 2>/dev/null | wc -l | tr -d ' ' || true)" "$BEFORE_RAW"

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

# 5: record contents, normalization, no text anywhere.
rm -rf "$STATE/spend" "$STATE/forwarded"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","subtype":"success","is_error":false,"result":"RESULTMARKER-31","total_cost_usd":0.25,
 "modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":40,"cacheReadInputTokens":11054,"cacheCreationInputTokens":17802,"costUSD":0.25},
   "bad name; rm":{"inputTokens":1},"newline\n":{"inputTokens":1},"array":[],"null":null,"weird":5,"neg":{"inputTokens":-3,"outputTokens":"9","cacheReadInputTokens":1e13,"cacheCreationInputTokens":1e999}}}'
fwd
check equals "$(wc -l < "$SANDBOX/err" | tr -d ' ')" 1
SIDL=$(jq -r '.args[5]' "$FAKE_LOG")
check equals "$(find "$STATE/spend/b" -name '*.json' | wc -l | tr -d ' ')" 1
RECL=$(find "$STATE/spend/b" -name '*.json' 2>/dev/null || true)
check jq -e --arg s "$SIDL" '.profile=="b" and .session_id==$s and .cost_usd==0.25 and .is_error==false and (.at|type)=="number" and .at<=now
  and .models=={"claude-haiku-5-5":{"in":2,"out":40,"cache_read":11054,"cache_write":17802},"neg":{"in":0,"out":0,"cache_read":0,"cache_write":0}}
  and (keys==["at","cost_usd","is_error","models","profile","session_id"])' "$RECL"
check equals "$(basename "$RECL" | grep -cE "^$SIDL-[0-9]+-[A-Za-z0-9]+\.json$")" 1
check test "$(grep -rl 'TASKMARKER-31\|RESULTMARKER-31' "$STATE/spend" "$STATE/forwarded" | wc -l | tr -d ' ')" -eq 0
check jq -e '.totals.cost_usd==0.25 and .totals.models["claude-haiku-5-5"].in==2' "$STATE/forwarded/$SIDL.json"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"r","total_cost_usd":"0.5"}'
fwd
check jq -se 'map(select(.cost_usd==null and .models=={}))|length==1' "$STATE/spend/b/"*.json

check equals "$(find "$STATE/spend" -name '.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" 0

# 6: permissions.
check equals "$(LC_ALL=C ls -ld "$STATE/spend" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -ld "$STATE/spend/b" | cut -c1-10)" drwx------
check equals "$(LC_ALL=C ls -l "$RECL" | cut -c1-10)" -rw-------

# 7: deltas on --continue.
rm -rf "$STATE/spend"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"one","total_cost_usd":1.0,"modelUsage":{"m":{"inputTokens":10,"outputTokens":5,"cacheReadInputTokens":100,"cacheCreationInputTokens":50}}}'
fwd; SIDD=$(jq -r '.args[5]' "$FAKE_LOG")
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"two","total_cost_usd":1.25,"modelUsage":{"m":{"inputTokens":14,"outputTokens":7,"cacheReadInputTokens":180,"cacheCreationInputTokens":50}}}'
fwd --continue "$SIDD"
check jq -se 'sort_by(.cost_usd)|.[0].cost_usd==0.25 and .[0].models.m=={"in":4,"out":2,"cache_read":80,"cache_write":0} and .[1].cost_usd==1' "$STATE/spend/b/"*.json
check jq -e '.totals.cost_usd==1.25 and .totals.models.m.in==14' "$STATE/forwarded/$SIDD.json"
# Lower than baseline (per-run reporting) -> reported value as is.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"three","total_cost_usd":0.1,"modelUsage":{"m":{"inputTokens":3}}}'
fwd --continue "$SIDD"
check jq -se 'map(select(.cost_usd==0.1 and .models.m.in==3))|length==1' "$STATE/spend/b/"*.json
# Missing baseline (record without totals) -> reported value.
jq 'del(.totals)' "$STATE/forwarded/$SIDD.json" > "$SANDBOX/rec" && mv "$SANDBOX/rec" "$STATE/forwarded/$SIDD.json"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"four","total_cost_usd":2.5}'
fwd --continue "$SIDD"
check jq -se 'map(select(.cost_usd==2.5))|length==1' "$STATE/spend/b/"*.json

# 8 + review focus 3: back-to-back and concurrent runs all recorded.
rm -rf "$STATE/spend"
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"c","total_cost_usd":0.01}'
t1=$(relay task-path); printf 'x\n' > "$t1"; t2=$(relay task-path); printf 'y\n' > "$t2"
(cd "$SANDBOX/project space" && relay forward --task-file "$t1" > "$SANDBOX/c1" 2>/dev/null) &
pid1=$!
(cd "$SANDBOX/project space" && relay forward --task-file "$t2" > "$SANDBOX/c2" 2>/dev/null) &
pid2=$!
wait "$pid1"; wait "$pid2"
check equals "$(cat "$SANDBOX/c1")$(cat "$SANDBOX/c2")" cc
check equals "$(find "$STATE/spend" -name '*.json' | wc -l | tr -d ' ')" 2

# 9 + review focus 5: recording failures warn, never change output or status.
rm -rf "$STATE/spend"; mkdir -p "$SANDBOX/elsewhere"; ln -s "$SANDBOX/elsewhere" "$STATE/spend"
FAKE_CLAUDE_STATUS=4 fwd
check equals "$rc" 4; check equals "$(cat "$SANDBOX/out")" c
check grep -qxF 'claude-relay: could not record relay run data.' "$SANDBOX/err"
check test -z "$(ls -A "$SANDBOX/elsewhere")"
rm -f "$STATE/spend"
rc=0; relay __record-run zz "$SIDD" "$STATE/tasks/out-nope" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0; check test ! -s "$SANDBOX/out"; check test ! -e "$STATE/spend/zz"
rc=0; relay __record-run b "$SIDD" "$SANDBOX/child.json" 2>/dev/null || rc=$?
check test "$rc" -ne 0

# 12 (pruning part): files older than 7 days are pruned by forward and prune_state.
mkdir -p "$STATE/spend/c"; printf '{}' > "$STATE/spend/c/old.json"; touch -t 200001010000 "$STATE/spend/c/old.json"
fwd; check test ! -e "$STATE/spend/c/old.json"
printf '{}' > "$STATE/spend/c/old2.json"; touch -t 200001010000 "$STATE/spend/c/old2.json"
rm -f "$STATE/prune.json"; relay statusline < "$ROOT/tests/fixtures/statusline.json" > /dev/null
check test ! -e "$STATE/spend/c/old2.json"

# Invalid costs and modelUsage shapes remain recordable; strict bounds are inclusive.
rm -rf "$STATE/spend"
BUFFER="$STATE/tasks/out-worker"
for cost in '"0.5"' -1 100001 1e999 null true '{}' '[]'; do
  printf '{"type":"result","is_error":false,"total_cost_usd":%s,"modelUsage":[]}\n' "$cost" > "$BUFFER"
  chmod 600 "$BUFFER"
  rc=0; relay __record-run b "$SIDD" "$BUFFER" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check equals "$rc" 0
  check test ! -s "$SANDBOX/out"
done
check jq -se 'length==8 and all(.[]; .cost_usd==null and .models=={})' "$STATE/spend/b/"*.json
envelope "$BUFFER" '{"type":"result","is_error":true,"total_cost_usd":100000,"modelUsage":{"m[1]:_-.":{"inputTokens":1e12,"outputTokens":0}}}'
rc=0; relay __record-run b "$SIDD" "$BUFFER" 2> "$SANDBOX/err" || rc=$?
check equals "$rc" 0
check jq -se 'any(.[]; .cost_usd==100000 and .is_error and .models["m[1]:_-."]["in"]==1e12)' "$STATE/spend/b/"*.json

# Missing and malformed baseline fields each fall back to the reported counter.
for baseline in '[]' '{"cost_usd":-1,"models":{"m":[]}}'; do
  jq --argjson t "$baseline" '.totals=$t' "$STATE/forwarded/$SIDD.json" > "$SANDBOX/rec"
  mv "$SANDBOX/rec" "$STATE/forwarded/$SIDD.json"
  envelope "$BUFFER" '{"type":"result","is_error":false,"total_cost_usd":3,"modelUsage":{"m":{"inputTokens":4}}}'
  rc=0; relay __record-run b "$SIDD" "$BUFFER" 2> "$SANDBOX/err" || rc=$?
  check equals "$rc" 0
done
check jq -se 'map(select(.cost_usd==3 and .models.m.in==4))|length==2' "$STATE/spend/b/"*.json

# Repeated same-session writes are unique, including within the same second.
rm -rf "$STATE/spend"
rc=0; relay __record-run b "$SIDD" "$BUFFER" 2>/dev/null || rc=$?
check equals "$rc" 0
rc=0; relay __record-run b "$SIDD" "$BUFFER" 2>/dev/null || rc=$?
check equals "$rc" 0
check equals "$(find "$STATE/spend/b" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" 2

# Every non-envelope is ignored even by the worker directly.
for raw in '' 'text' '{}' '[1]' 'null' '{"type":"result","is_error":false}{}' '{"type":"result","is_error":false} garbage'; do
  printf '%s' "$raw" > "$BUFFER"
  rc=0; relay __record-run b "$SIDD" "$BUFFER" > "$SANDBOX/out" 2>/dev/null || rc=$?
  check equals "$rc" 0
  check test ! -s "$SANDBOX/out"
done
check equals "$(find "$STATE/spend/b" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" 2

# A profile removed by the running child is rejected only by the recorder.
envelope "$FAKE_CLAUDE_OUTPUT" '{"type":"result","is_error":false,"result":"pool changed","total_cost_usd":1}'
FAKE_CLAUDE_REMOVE_PROFILE=b FAKE_CLAUDE_STATUS=4 fwd
check equals "$rc" 4
check equals "$(cat "$SANDBOX/out")" 'pool changed'
check grep -qxF 'claude-relay: could not record relay run data.' "$SANDBOX/err"
check equals "$(find "$STATE/spend/b" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" 2
write_pool

# An unwritable ledger directory gives up after five names, writes nothing and preserves totals.
envelope "$BUFFER" '{"type":"result","is_error":false,"total_cost_usd":9}'
cp "$STATE/forwarded/$SIDD.json" "$SANDBOX/totals-before"
before=$(find "$STATE/spend/b" -type f | wc -l | tr -d ' ')
chmod 500 "$STATE/spend/b"
# private_dir would restore 700; this chmod leaves only that directory read-only.
export REAL_CHMOD_SPEND=$(command -v chmod) LOCKED_SPEND_DIR="$STATE/spend/b"
cat > "$SANDBOX/fake/chmod" <<'CHMODSPEND'
#!/usr/bin/env bash
if [ "${1:-}" = 700 ] && [ "${2:-}" = "$LOCKED_SPEND_DIR" ]; then exit 0; fi
exec "$REAL_CHMOD_SPEND" "$@"
CHMODSPEND
"$REAL_CHMOD_SPEND" +x "$SANDBOX/fake/chmod"
rc=0; relay __record-run b "$SIDD" "$BUFFER" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
rm -f "$SANDBOX/fake/chmod"; unset REAL_CHMOD_SPEND LOCKED_SPEND_DIR
chmod 700 "$STATE/spend/b"
check test "$rc" -ne 0
check test ! -s "$SANDBOX/out"
check grep -q 'Could not allocate a ledger file name' "$SANDBOX/err"
check equals "$(find "$STATE/spend/b" -type f | wc -l | tr -d ' ')" "$before"
check cmp -s "$STATE/forwarded/$SIDD.json" "$SANDBOX/totals-before"
# An existing name is never overwritten: noclobber refuses it.
printf 'keep\n' > "$SANDBOX/existing"; cp "$SANDBOX/existing" "$STATE/spend/b/taken.json"
rc=0; ( set -C; printf 'x\n' > "$STATE/spend/b/taken.json" ) 2>/dev/null || rc=$?
check test "$rc" -ne 0
check cmp -s "$STATE/spend/b/taken.json" "$SANDBOX/existing"
rm -f "$STATE/spend/b/taken.json"

# Worker failures cannot follow symlinked files or state directories.
envelope "$BUFFER" '{"type":"result","is_error":false,"total_cost_usd":1}'
chmod 644 "$BUFFER"
rc=0; relay __record-run b "$SIDD" "$BUFFER" 2>/dev/null || rc=$?
check test "$rc" -ne 0
chmod 600 "$BUFFER"
ln -s "$BUFFER" "$STATE/tasks/out-link"
rc=0; relay __record-run b "$SIDD" "$STATE/tasks/out-link" 2>/dev/null || rc=$?
check test "$rc" -ne 0
rm "$STATE/tasks/out-link"
mkdir -p "$STATE/spend/b"
for target in "$STATE/forwarded/$SIDD.json" "$STATE/tasks" "$STATE/forwarded" "$STATE/spend/b" "$STATE"; do
  mv "$target" "$SANDBOX/record-real"
  ln -s "$SANDBOX/record-real" "$target"
  rc=0; relay __record-run b "$SIDD" "$BUFFER" > "$SANDBOX/out" 2>/dev/null || rc=$?
  check test "$rc" -ne 0
  check test ! -s "$SANDBOX/out"
  rm "$target"; mv "$SANDBOX/record-real" "$target"
done
rm -f "$BUFFER"

# Pruning skips symlinked entries and directories without touching their targets.
printf '{}' > "$SANDBOX/old-ledger"; touch -t 200001010000 "$SANDBOX/old-ledger"
ln -s "$SANDBOX/old-ledger" "$STATE/spend/b/link.json"
mkdir "$SANDBOX/old-ledgers"; cp -p "$SANDBOX/old-ledger" "$SANDBOX/old-ledgers/old.json"
ln -s "$SANDBOX/old-ledgers" "$STATE/spend/linked"
fwd
check test -L "$STATE/spend/b/link.json"
check test -f "$SANDBOX/old-ledger"
check test -f "$SANDBOX/old-ledgers/old.json"
unset FAKE_CLAUDE_OUTPUT
