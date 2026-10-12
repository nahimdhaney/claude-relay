#!/usr/bin/env bash
# Sourced by run.sh; all paths and executables belong to its sandbox.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
STATE="$XDG_STATE_HOME/claude-relay"
MARKER="$STATE/exhausted/a.json"
rm -rf "$STATE/exhausted"
rm -f "$STATE/usage/a.json"
rm -rf "$STATE/usage/a"
usage b 60; usage c 70
check relay exhausted a
check json_is "$MARKER" '.profile=="a" and .source=="manual" and .until-.at==3600'
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==100 and .[0].exhausted==true and .[0].known==false'
check equals "$(relay pick)" b
relay status > "$SANDBOX/status-table"
check grep -Eq 'exhausted until [0-9]{2}:[0-9]{2}' "$SANDBOX/status-table"
check equals "$(LC_ALL=C ls -l "$MARKER" 2>/dev/null | cut -c1-10)" '-rw-------'
check relay exhausted a --clear
check test ! -e "$MARKER"
check relay exhausted a --clear
for duration in 90m 4h 3600s; do
  case "$duration" in 90m) seconds=5400 ;; 4h) seconds=14400 ;; *) seconds=3600 ;; esac
  check relay exhausted a --for "$duration"
  check json_is "$MARKER" ".until-.at==$seconds"
done
check relay exhausted a --until 1
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==50 and .[0].exhausted==false'
usage a 23
check relay exhausted a
check json_is "$MARKER" '.until==4102444800'
usage a 99 1
printf 'exhausted_ttl=120\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
check relay exhausted a
check json_is "$MARKER" '.until-.at==120'
check env CLAUDE_RELAY_EXHAUSTED_TTL=240 "$BASH" "$CLI" exhausted a
check json_is "$MARKER" '.until-.at==240'
for args in '--for 0s' '--for -1h' '--for 1d' '--until nope' '--for 1h --until 1' '--clear --for 1h'; do
  rc=0
  # Deliberate splitting: each test case consists of CLI tokens.
  # shellcheck disable=SC2086
  relay exhausted a $args > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
done
rc=0; relay exhausted ../outside > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
rc=0; CLAUDE_RELAY_EXHAUSTED_TTL=invalid relay exhausted a > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
# Only a newer, usable capture below the configured threshold clears a mark.
mkdir -p "$STATE/exhausted"
jq -n '{profile:"a",at:4102444800,until:4102444900,source:"manual"}' > "$MARKER"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check test -f "$MARKER"
jq '.at=1' "$MARKER" > "$SANDBOX/marker"; mv "$SANDBOX/marker" "$MARKER"
printf '{"session_id":"no-usage"}' | relay statusline > "$SANDBOX/out"
check test -f "$MARKER"
jq '.rate_limits.five_hour.used_percentage=97' "$ROOT/tests/fixtures/statusline.json" | relay statusline > "$SANDBOX/out"
check test -f "$MARKER"
CLAUDE_RELAY_WARN_AT=30 CLAUDE_RELAY_HANDOFF_AT=40 relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check test -f "$MARKER"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out"
check test ! -e "$MARKER"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].score==41 and .[0].exhausted==false'
# Live Team payload: five_hour alone is a valid measurement and recovery.
check relay exhausted a
jq 'del(.rate_limits.seven_day)' "$ROOT/tests/fixtures/statusline.json" | relay statusline > "$SANDBOX/out"
check equals "$(cat "$SANDBOX/out")" 'a · 5h 23%'
check test ! -e "$MARKER"
relay status --json > "$SANDBOX/status"
check json_is "$SANDBOX/status" '.[0].known and .[0].score==23 and .[0].seven_day==null'
printf '{broken' > "$MARKER"
relay statusline < "$ROOT/tests/fixtures/statusline.json" > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
rm "$MARKER"
CLAUDE_CODE_CHILD_SESSION=1 relay run --profile a -- -p sandbox > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.child=="unset"'
CLAUDE_CODE_CHILD_SESSION=1 relay resume --session session-one --to b > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.child=="unset" and .args==["--resume","session-one"]'
# Capture notifications without sending any real desktop messages.
export NOTIFY_LOG="$SANDBOX/notify.json"
for notifier in osascript notify-send; do
  cat > "$SANDBOX/fake/$notifier" <<'NOTIFIER'
#!/usr/bin/env bash
jq -n --args '$ARGS.positional' -- "$@" > "$NOTIFY_LOG"
NOTIFIER
done
rm -f "$STATE/events.log" "$NOTIFY_LOG"
cp "$STATE/last-handoff.json" "$SANDBOX/handoff-before"
jq -n '{session_id:"id\nwith\tcontrols",hook_event_name:"StopFailure",error:"authentication_error",error_details:("x"*250),message:"bad\nlogin\u001b",extra:"DO_NOT_LOG",transcript:"DO_NOT_LOG"}' > "$SANDBOX/event"
relay hook stop-failure < "$SANDBOX/event" > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
check test ! -e "$MARKER"
check test ! -e "$NOTIFY_LOG"
check cmp -s "$STATE/last-handoff.json" "$SANDBOX/handoff-before"
check json_is "$STATE/events.log" '.profile=="a" and (.at|test("^[0-9]{4}-.*Z$")) and .keys==["error","error_details","extra","hook_event_name","message","session_id","transcript"] and (.error_details|length)==200 and (has("extra")|not) and (has("transcript")|not)'
check equals "$(wc -l < "$STATE/events.log" 2>/dev/null | tr -d ' ')" 1
check equals "$(LC_ALL=C ls -l "$STATE/events.log" 2>/dev/null | cut -c1-10)" '-rw-------'
check json_is "$STATE/events.log" 'tostring | contains("DO_NOT_LOG") | not'
check json_is "$STATE/events.log" '.session_id=="id with controls" and .message=="bad login "'
# Every allowed field can carry the limit signal; missing transcripts still notify.
for field in error error_type error_details matcher reason message; do
  case "$field" in
    error) signal=rate_limit ;; error_type) signal='RATE LIMIT' ;;
    error_details) signal='Usage limit' ;; matcher) signal='weekly limit' ;;
    reason) signal='Limit reached' ;; message) signal="You've hit your session limit · resets 2:10pm" ;;
  esac
  rm -f "$MARKER" "$NOTIFY_LOG"
  jq -n --arg field "$field" --arg signal "$signal" '{hook_event_name:"StopFailure",session_id:"missing",($field):$signal}' | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
  check json_is "$MARKER" '.profile=="a" and .source=="stop-failure" and .until==4102444800'
  check json_is "$NOTIFY_LOG" 'any(.[]; contains("account a exhausted; could not copy the session"))'
done
check equals "$(wc -l < "$STATE/events.log" 2>/dev/null | tr -d ' ')" 7
# Successful handoff and a real copy failure, with the mark present before copying.
usage b 10; usage c 20
guard_input StopFailure | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$STATE/last-handoff.json" '.to=="b" and .session_id=="session-one"'
check json_is "$NOTIFY_LOG" 'any(.[]; contains("profile b") and contains("resume --last"))'
touch -t 202001010000 "$DEST"
export REAL_CAT=$(command -v cat) COPY_SOURCE="$SOURCE"
cat > "$SANDBOX/fake/cat" <<'COPYFAIL'
#!/usr/bin/env bash
if [ "${1:-}" = "$COPY_SOURCE" ]; then
  jq -e '.profile=="a" and .until>now' "$XDG_STATE_HOME/claude-relay/exhausted/a.json" > "$COPY_CHECK"
  exit 1
fi
exec "$REAL_CAT" "$@"
COPYFAIL
chmod +x "$SANDBOX/fake/cat"
export COPY_CHECK="$SANDBOX/marked-before-copy"
rm -f "$NOTIFY_LOG" "$STATE/last-handoff.json"
guard_input StopFailure | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
rm "$SANDBOX/fake/cat"
check test -s "$COPY_CHECK"
check test ! -e "$STATE/last-handoff.json"
check json_is "$NOTIFY_LOG" 'any(.[]; contains("account a exhausted; could not copy the session"))'
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
printf '{broken' | relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
guard_input StopFailure | XDG_STATE_HOME="$SANDBOX/not-directory" relay hook stop-failure > "$SANDBOX/out" 2> "$SANDBOX/err"
check test ! -s "$SANDBOX/out"
check test ! -s "$SANDBOX/err"
# Migrate a legacy group shared with an unrelated hook, retaining its matcher.
LEGACY="$SANDBOX/legacy-settings.json"
printf '{"hooks":{"StopFailure":[{"matcher":"rate_limit","hooks":[{"type":"command","command":"old/claude-relay hook stop-failure"},{"type":"command","command":"unrelated stop"}]}]}}\n' > "$LEGACY"
relay install --profiles a,b,c --settings "$LEGACY" > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$LEGACY" '.hooks.StopFailure | length==2 and .[0].matcher=="rate_limit" and .[0].hooks[0].command=="unrelated stop" and (.[1]|has("matcher")|not)'
cp "$LEGACY" "$SANDBOX/legacy-once"
relay install --profiles a,b,c --settings "$LEGACY" > "$SANDBOX/out" 2> "$SANDBOX/err"
check cmp -s "$LEGACY" "$SANDBOX/legacy-once"
relay uninstall --settings "$LEGACY" > "$SANDBOX/out"
check json_is "$LEGACY" '.hooks.StopFailure | length==1 and .[0].matcher=="rate_limit" and .[0].hooks==[{type:"command",command:"unrelated stop"}]'
cp "$LEGACY" "$SANDBOX/legacy-uninstalled"
relay uninstall --settings "$LEGACY" > "$SANDBOX/out"
check cmp -s "$LEGACY" "$SANDBOX/legacy-uninstalled"
relay help exhausted > "$SANDBOX/out"
check test -s "$SANDBOX/out"
rm -rf "$STATE/exhausted"
