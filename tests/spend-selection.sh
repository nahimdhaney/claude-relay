#!/usr/bin/env bash
# Sourced by run.sh: rolling relay spend and score tie-breaking.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
STATE="$XDG_STATE_HOME/claude-relay"
rm -rf "$STATE/spend" "$STATE/usage" "$STATE/exhausted" "$STATE/warned"
usage a 98
spend_rec() {
  mkdir -p "$STATE/spend/$1"; chmod 700 "$STATE/spend" "$STATE/spend/$1"
  jq -n --arg p "$1" --argjson c "$2" --argjson age "$3" --argjson e "${4:-false}" \
    '{profile:$p,session_id:"00000000-0000-4000-8000-000000000000",at:(now-$age|floor),cost_usd:$c,is_error:$e,models:{}}' \
    > "$STATE/spend/$1/r-$RANDOM$RANDOM.json"
}
# Complete costs compare cost, then runs, then pool order.
spend_rec b 0.3 60
check equals "$(relay pick --exclude a)" c
spend_rec c 0.3 60
check equals "$(relay pick --exclude a)" b
spend_rec b 0 60
check equals "$(relay pick --exclude a)" c
# One missing cost makes runs decisive, even against a lower known cost.
rm -rf "$STATE/spend"
spend_rec b null 60; spend_rec b 0 60; spend_rec c 9 60
check equals "$(relay pick --exclude a)" c
spend_rec c 0 60
check equals "$(relay pick --exclude a)" b
rm -rf "$STATE/spend"
check equals "$(relay pick --exclude a)" b
# A profile whose runs fail (cheap, e.g. a lost login) loses ties to one that works.
spend_rec b 0 60 true; spend_rec c 0.5 60
check equals "$(relay pick --exclude a)" c
relay status --json > "$SANDBOX/st"
check json_is "$SANDBOX/st" '.[1].relay_spend_5h.errors==1 and .[2].relay_spend_5h.errors==0'
spend_rec c 0.5 60 true; spend_rec c 0.5 60 true
check equals "$(relay pick --exclude a)" b
rm -rf "$STATE/spend"
# Spend never changes the score, and only lowest-score ties affect ordering.
usage c 30; spend_rec c 5 60
check equals "$(relay pick --exclude a)" c
usage c 60; spend_rec b 9 60
check equals "$(relay pick --exclude a)" b
usage a 80; spend_rec a null 60
rm -rf "$STATE/spend/b" "$STATE/spend/c"; rm -f "$STATE/usage/c.json"
spend_rec b 1 60; spend_rec b 0 60; spend_rec c 2 60
check equals "$(relay pick)" b
usage a 98
# Both JSON commands expose the aggregate; the text table stays unchanged.
relay status | cut -f 1-6,8- > "$SANDBOX/table-before"
relay pick --exclude a --json > "$SANDBOX/pk"
check json_is "$SANDBOX/pk" '.profile=="b" and .relay_spend_5h=={cost_usd:1,runs:2,complete:true,errors:0}'
rm -rf "$STATE/spend"
relay status | cut -f 1-6,8- > "$SANDBOX/table-after"
check cmp -s "$SANDBOX/table-before" "$SANDBOX/table-after"
spend_rec b 0.2 60
relay status --json > "$SANDBOX/st"
check json_is "$SANDBOX/st" '.[1].relay_spend_5h=={cost_usd:0.2,runs:1,complete:true,errors:0} and .[2].relay_spend_5h=={cost_usd:0,runs:0,complete:true,errors:0}'
# Stored costs have no upper bound; writer normalization is a separate rule.
spend_rec b 100001 60
relay status --json > "$SANDBOX/st"
check json_is "$SANDBOX/st" '.[1].relay_spend_5h=={cost_usd:100001.2,runs:2,complete:true,errors:0}'
rm -rf "$STATE/spend"; spend_rec b 0.2 60
# Bad timestamps, costs, shapes and files do not hide a valid record.
for record in \
  '{"profile":"b","at":(now-20000),"cost_usd":1}' \
  '{"profile":"b","at":(now+3600),"cost_usd":1}' \
  '{"profile":"c","at":now,"cost_usd":1}' \
  '{"profile":"b","at":"1","cost_usd":1}' \
  '{"profile":"b","at":null,"cost_usd":1}' \
  '{"profile":"b","at":now,"cost_usd":-1}' \
  '{"profile":"b","at":now,"cost_usd":"1"}' \
  '{"profile":"b","at":now,"cost_usd":{}}' '[]' 'null'; do
  jq -n "$record" > "$STATE/spend/b/invalid-$RANDOM.json"
done
printf '{"profile":"b","at":1e999,"cost_usd":1}' > "$STATE/spend/b/infinite-at.json"
printf '{"profile":"b","at":NaN,"cost_usd":1}' > "$STATE/spend/b/nan-at.json"
AT=$(jq -nr 'now|floor')
printf '{"profile":"b","at":%s,"cost_usd":1e999}' "$AT" > "$STATE/spend/b/infinite-cost.json"
printf '{broken' > "$STATE/spend/b/broken.json"
jq -n '{profile:"b",at:now,cost_usd:999}' > "$SANDBOX/outside.json"
ln -s "$SANDBOX/outside.json" "$STATE/spend/b/link.json"
cat "$SANDBOX/outside.json" > "$STATE/spend/b/trailing.json"
printf 'garbage' >> "$STATE/spend/b/trailing.json"
# Recent JSON in an old file must be excluded before reading it.
cp "$SANDBOX/outside.json" "$STATE/spend/b/old.json"
touch -t 200001010000 "$STATE/spend/b/old.json"
relay status --json > "$SANDBOX/st"
check json_is "$SANDBOX/st" '.[1].relay_spend_5h=={cost_usd:0.2,runs:1,complete:true,errors:0}'
spend_rec b null 60
relay status --json > "$SANDBOX/st"
check json_is "$SANDBOX/st" '.[1].relay_spend_5h=={cost_usd:0.2,runs:2,complete:false,errors:0}'
for target in "$STATE/spend/b" "$STATE/spend" "$STATE"; do
  mv "$target" "$SANDBOX/spend-real"; ln -s "$SANDBOX/spend-real" "$target"
  relay status --json > "$SANDBOX/st"
  check json_is "$SANDBOX/st" 'all(.[]; .relay_spend_5h=={cost_usd:0,runs:0,complete:true,errors:0})'
  rm "$target"; mv "$SANDBOX/spend-real" "$target"
done
# Equal-cost forwarded runs spread across accounts with no measurements.
rm -rf "$STATE/spend" "$STATE/forwarded"
export FAKE_CLAUDE_OUTPUT="$SANDBOX/child.json"
printf '{"type":"result","is_error":false,"result":"done","total_cost_usd":0.3}' > "$FAKE_CLAUDE_OUTPUT"
for expected in b c b c; do
  task=$(relay task-path); printf 'task\n' > "$task"
  rc=0; (cd "$SANDBOX/project space" && relay forward --task-file "$task") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check equals "$rc" 0
  check json_is "$FAKE_LOG" ".config|endswith(\"/$expected\")"
done
# run --pick and both handoff paths share the same choice.
spend_rec b 3 60
relay run --pick -- > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.config|endswith("/c")'
unset FAKE_CLAUDE_OUTPUT
PROJECT=$(printf '%s' "$SANDBOX/project space" | jq -Rr 'gsub("[^a-zA-Z0-9]";"-")')
SOURCE="$CLAUDE_PROFILES_ROOT/a/projects/$PROJECT/session-one.jsonl"
mkdir -p "$(dirname "$SOURCE")"
printf '{"type":"user","message":"hello"}\n' > "$SOURCE"
guard_input | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext|contains("handoff")'
check json_is "$STATE/last-handoff.json" '.to=="c"'
guard_input StopFailure | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$STATE/last-handoff.json" '.to=="c"'
# A populated ledger must keep the actual guard handoff path fast.
rm -rf "$STATE/spend" "$STATE/warned" "$STATE/exhausted"
for p in a b c; do
  mkdir -p "$STATE/spend/$p"; n=0
  while [ "$n" -lt 300 ]; do
    printf '{"profile":"%s","at":1,"cost_usd":0.1}' "$p" > "$STATE/spend/$p/old-$n.json"
    n=$((n+1))
  done
  touch -t 200001010000 "$STATE/spend/$p/"old-*.json
  spend_rec "$p" 0.1 60
done
usage a 98
guard_input > "$SANDBOX/guard16"
started=$(jq -nr now)
relay hook guard < "$SANDBOX/guard16" > "$SANDBOX/out16"
elapsed=$(jq -nr --argjson start "$started" '(now-$start)*1000')
check json_is "$SANDBOX/out16" '.hookSpecificOutput.additionalContext|contains("handoff")'
check json_is "$STATE/last-handoff.json" '.to=="b"'
check jq -en --argjson ms "$elapsed" --argjson budget "${CLAUDE_RELAY_TEST_HANDOFF_MS:-1500}" '$ms<$budget'
printf 'Guard handoff with 903 ledger files: %s ms.\n' "$elapsed"
rm -rf "$STATE/spend" "$STATE/exhausted"
