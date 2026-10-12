#!/usr/bin/env bash
# Sourced by run.sh, using only its temporary HOME, state and fake executables.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
rm -rf "$STATE/usage" "$STATE/exhausted" "$STATE/warned"
capture_input() {
  jq -n --arg sid "$1" --arg model "$2" --argjson weekly "$3" --argjson hourly "${4:-23}" \
    '{session_id:$sid,model:{id:$model},rate_limits:{five_hour:{used_percentage:$hourly,resets_at:4102444800},seven_day:{used_percentage:$weekly,resets_at:4102444800}}}'
}
capture_input live-high model-a 14 | relay statusline > "$SANDBOX/out"
capture_input live-low model-b 2 | relay statusline > "$SANDBOX/out"
check json_is "$STATE/usage/a/live-high.json" '.profile=="a" and .session_id=="live-high" and .model=="model-a" and .rate_limits.seven_day.used_percentage==14'
check json_is "$STATE/usage/a/live-low.json" '.session_id=="live-low" and .model=="model-b" and .rate_limits.seven_day.used_percentage==2'
check cmp -s "$STATE/usage/a/live-low.json" "$STATE/usage/a.json"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==2 and .[0].seven_day.used_percentage==14 and .[0].seven_day.session_id=="live-high" and .[0].seven_day.model=="model-a"'
# Old render keeps both its timestamp and the newer compatibility copy.
if [ -f "$STATE/usage/a/live-high.json" ]; then
  jq '.captured_at=now-100' "$STATE/usage/a/live-high.json" > "$SANDBOX/aged"
  mv "$SANDBOX/aged" "$STATE/usage/a/live-high.json"
  cp "$STATE/usage/a/live-high.json" "$SANDBOX/unchanged"
fi
cp "$STATE/usage/a.json" "$SANDBOX/legacy-newest"
capture_input live-high different-model 14 | jq -S . | relay statusline > "$SANDBOX/out"
check cmp -s "$SANDBOX/unchanged" "$STATE/usage/a/live-high.json"
check cmp -s "$SANDBOX/legacy-newest" "$STATE/usage/a.json"
capture_input live-high model-a 15 | relay statusline > "$SANDBOX/out"
check json_is "$STATE/usage/a/live-high.json" '.rate_limits.seven_day.used_percentage==15 and .captured_at>now-30'
check cmp -s "$STATE/usage/a/live-high.json" "$STATE/usage/a.json"
# A capture with an expired five-hour window cannot override a current one.
capture_input live-low model-b 2 | jq '.rate_limits.seven_day.resets_at=4102444801 | .rate_limits.five_hour.resets_at=1' | relay statusline > "$SANDBOX/out"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].seven_day.used_percentage==15 and .[0].seven_day.session_id=="live-high" and .[0].five_hour.session_id=="live-high"'
# Never consult legacy when session files exist, including corrupt legacy JSON.
printf '{broken' > "$STATE/usage/a.json"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].score==23'
# Deterministic captures for freshness selection and stale-only fallback.
mkdir -p "$STATE/usage/a"
rm -f "$STATE/usage/a/"*.json
jq -n '{profile:"a",session_id:"old",model:"model-old",captured_at:(now-22000),rate_limits:{five_hour:{used_percentage:99,resets_at:4102444800},seven_day:{used_percentage:90,resets_at:4102444900}}}' > "$STATE/usage/a/old.json"
jq -n '{profile:"a",session_id:"new",model:"model-new",captured_at:(now-100),rate_limits:{five_hour:{used_percentage:98,resets_at:1},seven_day:{used_percentage:2,resets_at:4102444800}}}' > "$STATE/usage/a/new.json"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].score==2 and .[0].five_hour==null and .[0].seven_day.session_id=="new"'
printf 'capture_max_age=30000\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].score==99 and .[0].seven_day.session_id=="old"'
CLAUDE_RELAY_CAPTURE_MAX_AGE=60 relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].score==2 and .[0].five_hour==null and .[0].age_seconds>=100 and .[0].seven_day.model=="model-new"'
jq '.rate_limits.seven_day.resets_at=1' "$STATE/usage/a/new.json" > "$SANDBOX/expired"
mv "$SANDBOX/expired" "$STATE/usage/a/new.json"
CLAUDE_RELAY_CAPTURE_MAX_AGE=60 relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].known==false and .[0].score==50 and .[0].five_hour==null and .[0].seven_day==null'
# Guard must use the selected current captures without needing the legacy file.
rm -f "$STATE/usage/a.json"
guard_input | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("99")'
relay exhausted a --for 1h
CLAUDE_RELAY_CAPTURE_MAX_AGE=60 relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].exhausted and .[0].score==100'
# Identical data predating exhaustion must not clear the marker.
rm -rf "$STATE/usage/a"
capture_input idle model-a 14 | relay statusline > "$SANDBOX/out"
relay exhausted a --for 1h
capture_input idle model-a 14 | relay statusline > "$SANDBOX/out"
check test -f "$STATE/exhausted/a.json"
capture_input idle model-a 15 | relay statusline > "$SANDBOX/out"
check test ! -e "$STATE/exhausted/a.json"
# Prune by captured_at, keeping recent captures and unrelated files.
mkdir -p "$STATE/usage/a"
jq -n '{profile:"a",session_id:"week-old",captured_at:(now-604900),rate_limits:{}}' > "$STATE/usage/a/week-old.json"
jq -n '{profile:"b",session_id:"week-old",captured_at:(now-604900),rate_limits:{}}' > "$SANDBOX/old-other"
mkdir -p "$STATE/usage/b"
cp "$SANDBOX/old-other" "$STATE/usage/b/week-old.json"
printf 'keep' > "$STATE/usage/a/notes.txt"
rm -f "$STATE/prune.json"
capture_input idle model-a 16 | relay statusline > "$SANDBOX/out"
check test ! -e "$STATE/usage/a/week-old.json"
check test -f "$STATE/usage/b/week-old.json" # Keep the newest even when stale.
check test -f "$STATE/usage/a/idle.json"
check equals "$(cat "$STATE/usage/a/notes.txt")" keep
# Missing model is represented as null; unsafe session IDs fail silently.
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check json_is "$STATE/usage/a/session-one.json" '.model==null'
capture_input ../escape model-a 20 | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check test ! -e "$STATE/usage/escape.json"
# Damaged per-session state is repaired by the next valid render.
printf '{broken' > "$STATE/usage/a/repair.json"
capture_input repair model-a 17 | relay statusline > "$SANDBOX/out"
check json_is "$STATE/usage/a/repair.json" '.session_id=="repair" and .rate_limits.seven_day.used_percentage==17'
# A corrupt inactive session cannot suppress another profile's statusline.
printf '{broken' > "$STATE/usage/b/corrupt.json"
capture_input healthy model-a 18 | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23% · 7d 18%'
check test ! -s "$SANDBOX/err"
check json_is "$STATE/usage/a/healthy.json" '.session_id=="healthy" and .rate_limits.seven_day.used_percentage==18'
rm "$STATE/usage/b/corrupt.json"
# A stopped lock owner must not prevent all subsequent captures.
(exit 0) &
dead_owner=$!
wait "$dead_owner"
mkdir "$STATE/usage/.capture-lock"
: > "$STATE/usage/.capture-lock/$dead_owner"
capture_input recovered model-a 18 | relay statusline > "$SANDBOX/out"
check json_is "$STATE/usage/a/recovered.json" '.session_id=="recovered" and .rate_limits.seven_day.used_percentage==18'
check test ! -d "$STATE/usage/.capture-lock"
# Cleanup also tolerates interruption between mkdir and recording the owner.
rm -rf "$STATE/usage/.capture-lock"
mkdir "$STATE/usage/.capture-lock"
capture_input ownerless model-a 19 | relay statusline > "$SANDBOX/out"
check json_is "$STATE/usage/a/ownerless.json" '.session_id=="ownerless" and .rate_limits.seven_day.used_percentage==19'
rm -rf "$STATE/usage/.capture-lock"
# Controlled reversed arrival: a later capture is already persisted when an
# older writer reaches the critical section. Use the real persistence helper.
jq -n '{profile:"a",session_id:"overlap",model:"newer",captured_at:(now+60),rate_limits:{seven_day:{used_percentage:20,resets_at:4102444800}}}' > "$STATE/usage/a/overlap.json"
cp "$STATE/usage/a/overlap.json" "$SANDBOX/newer-capture"
(
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/profiles.sh"
  source "$ROOT/lib/hooks.sh"
  RELAY_ROOT=$ROOT
  init_config
  load_pool
  store_capture "$(jq '.captured_at-=60 | .model="older" | .rate_limits.seven_day.used_percentage=10' "$SANDBOX/newer-capture")"
) > "$SANDBOX/out"
check cmp -s "$STATE/usage/a/overlap.json" "$SANDBOX/newer-capture"
check json_is "$STATE/usage/a.json" '.session_id=="overlap" and .model=="newer" and .rate_limits.seven_day.used_percentage==20'
# Simultaneous sessions both survive, with the newest capture mirrored.
capture_input parallel-a model-a 24 | relay statusline > "$SANDBOX/parallel-a" &
parallel_pid=$!
capture_input parallel-b model-b 25 | relay statusline > "$SANDBOX/parallel-b"
wait "$parallel_pid"
check json_is "$STATE/usage/a/parallel-a.json" '.rate_limits.seven_day.used_percentage==24'
check json_is "$STATE/usage/a/parallel-b.json" '.rate_limits.seven_day.used_percentage==25'
check json_is "$STATE/usage/a.json" '.session_id=="overlap" and .model=="newer"'
# A late write failure is buffered, silent, and releases its lock.
printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/fake/mv"
chmod +x "$SANDBOX/fake/mv"
capture_input failed-write model-a 26 | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
rm "$SANDBOX/fake/mv"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check test ! -e "$STATE/usage/a/failed-write.json"
check test ! -d "$STATE/usage/.capture-lock"
# A live owner is never displaced; contention fails open after bounded retries.
mkdir "$STATE/usage/.capture-lock"
: > "$STATE/usage/.capture-lock/$$"
capture_input locked model-a 27 | relay statusline > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check test ! -e "$STATE/usage/a/locked.json"
check test -f "$STATE/usage/.capture-lock/$$"
rm -rf "$STATE/usage/.capture-lock"
# Legacy-only state remains usable (empty session directories also fall back).
usage a 42
mkdir -p "$STATE/usage/a"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].capture_count==1 and .[0].score==42 and .[0].five_hour.session_id=="other-session" and .[0].five_hour.model==null'
for invalid in 0 -1 1.5 nope; do
  rc=0; CLAUDE_RELAY_CAPTURE_MAX_AGE="$invalid" relay status --json > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
done
# Migrate refreshInterval with a backup, preserve the original receipt, repeat.
MIGRATION="$SANDBOX/refresh-settings.json"
printf '{"theme":"dark","statusLine":{"type":"command","command":"printf original", "refreshInterval":42,"padding":3}}\n' > "$MIGRATION"
cp "$MIGRATION" "$SANDBOX/refresh-original"
relay install --profiles a,b,c --settings "$MIGRATION" > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$MIGRATION" '.statusLine | has("refreshInterval") | not'
jq '.statusLine.refreshInterval=60' "$MIGRATION" > "$SANDBOX/old-installed"
cp "$SANDBOX/old-installed" "$MIGRATION"
relay install --profiles a,b,c --settings "$MIGRATION" > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$MIGRATION" '.theme=="dark" and (.statusLine|has("refreshInterval")|not)'
backup_found=false
for backup in "$MIGRATION".relay-backup-*; do
  if cmp -s "$backup" "$SANDBOX/old-installed"; then backup_found=true; fi
done
check "$backup_found"
cp "$MIGRATION" "$SANDBOX/migrated-once"
relay install --profiles a,b,c --settings "$MIGRATION" > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$MIGRATION" "$SANDBOX/migrated-once"
check equals "$(jq -Rsc 'split("\n")|map(select(.=="capture_max_age=30000"))|length' "$XDG_CONFIG_HOME/claude-relay/config")" 1
relay uninstall --settings "$MIGRATION" > "$SANDBOX/out"
check equals "$(jq -Sc . "$MIGRATION")" "$(jq -Sc . "$SANDBOX/refresh-original")"
