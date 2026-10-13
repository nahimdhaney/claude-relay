#!/usr/bin/env bash
# Serialize capture updates so concurrent renders cannot regress the legacy
# copy or race pruning. Bound contention; the safe worker stays fail-open.
store_capture() (
  # Command substitutions otherwise disable errexit in Bash, including 3.2.
  set -e
  local data=$1 sid target previous newest file dir lock owner pid present prune cleanup attempts=0
  sid=$(printf '%s' "$data" | jq -er '.session_id | select(type=="string")')
  safe_name "$sid" || return 1
  private_dir "$STATE_DIR/usage/$CURRENT_PROFILE"
  lock="$STATE_DIR/usage/.capture-lock"
  [ ! -L "$lock" ] || return 1
  until mkdir "$lock" 2>/dev/null; do
    present=false
    for owner in "$lock/"*; do
      [ -f "$owner" ] || continue
      present=true
      pid=${owner##*/}
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      if ! kill -0 "$pid" 2>/dev/null; then
        # Only the process that removes this particular dead owner's file
        # may remove its directory; competing waiters must retry acquisition.
        if rm "$owner" 2>/dev/null; then rmdir "$lock" 2>/dev/null || true; fi
      fi
    done
    # Allow an owner a retry to publish its PID after mkdir. An empty lock
    # left by interruption before that point can then be removed safely.
    if ! $present && [ "$attempts" -gt 0 ]; then rmdir "$lock" 2>/dev/null || true; fi
    attempts=$((attempts+1))
    [ "$attempts" -lt 4 ] || return 1
    if [ -d "$lock" ]; then sleep 1; fi
  done
  # Bash 3.2 can discard locals before an errexit EXIT trap. Bake in quoted
  # paths while they are still in scope, including spaces and shell syntax.
  printf -v cleanup 'rm -f %q; rmdir %q' "$lock/$$" "$lock"
  trap "$cleanup" EXIT
  trap 'exit 1' HUP INT TERM
  : > "$lock/$$"
  target="$STATE_DIR/usage/$CURRENT_PROFILE/$sid.json"
  if [ -f "$target" ]; then
    previous=$(jq -ce 'select(type=="object" and (.captured_at|type)=="number")' "$target" 2>/dev/null) || previous='{}'
    if printf '%s' "$previous" | jq -e --argjson incoming "$data" \
      '.rate_limits==$incoming.rate_limits or .captured_at>$incoming.captured_at' >/dev/null; then
      data=$previous
    else
      printf '%s' "$data" | atomic_json "$target"
    fi
  else
    printf '%s' "$data" | atomic_json "$target"
  fi
  newest=$(captures "$CURRENT_PROFILE" | jq -ce 'map(select((.captured_at|type)=="number")) | max_by([.captured_at,.session_id])')
  printf '%s' "$newest" | atomic_json "$STATE_DIR/usage/$CURRENT_PROFILE.json"
  prune_state
  printf '%s\n' "$data"
)
# Batch capture metadata; corrupt files fall back independently.
prune_state() (
  local dir file data files=() count cutoff
  # store_capture holds the lock; a stamp avoids scanning on every render.
  if [ -f "$STATE_DIR/prune.json" ] && [ ! -L "$STATE_DIR/prune.json" ] &&
    jq -e '(.at|type)=="number" and .at<=now and .at>now-600' "$STATE_DIR/prune.json" >/dev/null 2>&1; then return 0; fi
  for dir in "$STATE_DIR/usage/"*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    files=(); count=0
    for file in "$dir/"*.json; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      files[$count]=$file; count=$((count+1))
    done
    [ "$count" -gt 0 ] || continue
    if ! data=$(jq -cn '[inputs | select(type=="object" and (.captured_at|type)=="number") | {path:input_filename,at:.captured_at}]' "${files[@]}" 2>/dev/null); then
      data=$(for file in "${files[@]}"; do
        jq -c --arg path "$file" 'select(type=="object" and (.captured_at|type)=="number") | {path:$path,at:.captured_at}' "$file" 2>/dev/null || true
      done | jq -s .)
    fi
    while IFS= read -r -d '' file; do
      [ -z "$file" ] || rm -f "$file"
    done < <(printf '%s' "$data" | jq -j --argjson age "$CAPTURE_MAX_AGE" 'sort_by([.at,.path]) | .[:-1][] | select(.at < now-$age) | .path,"\u0000"')
  done
  cutoff=$(mktemp "$STATE_DIR/.prune.XXXXXX")
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr 'now-604800 | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff"
  for dir in "$STATE_DIR/warned" "$STATE_DIR/sessions"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    while IFS= read -r -d '' file; do rm -f "$file"; done < <(find "$dir" -type f ! -newer "$cutoff" -print0)
  done
  prune_task_files
  prune_spend
  jq -n '{at:now}' | atomic_json "$STATE_DIR/prune.json"
)
cmd_statusline() {
  load_pool
  local input data line wrapped='' receipts='{}' result save recovered command
  input=$(cat; printf '.')
  input=${input%.}
  validate_input "$input"
  # Per-settings originals let different profiles retain distinct status lines.
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then
    receipts=$(cat "$CONFIG_DIR/installed-settings.json")
  fi
  result=$(printf '%s' "$input" | jq -er -L "$RELAY_ROOT/lib" --arg p "$CURRENT_PROFILE" \
    --arg settings "${CURRENT_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/settings.json" --argjson receipts "$receipts" --arg wrapped "$WRAPPED_STATUSLINE" '
    include "usage";
    select(type=="object") |
    {profile:$p,captured_at:now,session_id:(.session_id // ""),model:(.model.id // null),rate_limits:(.rate_limits // {})} as $data |
    ($data|measurement(50)) as $m |
    ($p+" · "+(if $m.known then
      [if $m.five_hour!=null then "5h \($m.five_hour.effective)%" else empty end,
       if $m.seven_day!=null then "7d \($m.seven_day.effective)%" else empty end]|join(" · ") else "no data" end)) as $line |
    [($data|tojson),($data|[valid_window("five_hour"),valid_window("seven_day")]|any(.!=null)|tostring),$line,
     (if $receipts|has($settings) then $receipts[$settings].statusLine.command // "" else $wrapped end)] | .[]')
  # The first three values cannot contain literal newlines. Preserve the rest
  # as the wrapper command, rather than splitting paths or shell syntax.
  data=${result%%$'\n'*}; result=${result#*$'\n'}
  save=${result%%$'\n'*}; result=${result#*$'\n'}
  line=${result%%$'\n'*}
  case "$result" in *$'\n'*) wrapped=${result#*$'\n'} ;; esac
  # Missing windows never erase a previous account measurement.
  if [ -n "$CURRENT_PROFILE" ] && [ "$save" = true ]; then
    data=$(store_capture "$data")
    if [ -f "$STATE_DIR/exhausted/$CURRENT_PROFILE.json" ]; then
      recovered=$(printf '%s' "$data" | jq -r -L "$RELAY_ROOT/lib" --argjson h "$HANDOFF_AT" \
        --slurpfile marker "$STATE_DIR/exhausted/$CURRENT_PROFILE.json" '
        include "usage"; . as $data | measurement(50) |
        .known and .score<$h and ($marker[0].at|type)=="number" and $data.captured_at>$marker[0].at')
      if [ "$recovered" = true ]; then rm -f "$STATE_DIR/exhausted/$CURRENT_PROFILE.json"; fi
    fi
  fi
  # Broken/migrated receipts must not recursively launch this statusline.
  printf -v command '%q' "$RELAY_BIN"
  # jq 1.6 exits 0 for -e with empty input, so never test an empty command.
  if [ -n "$wrapped" ] && printf '%s' "$wrapped" | jq -eR -L "$RELAY_ROOT/lib" --arg bin "$command" 'include "settings"; {command:.} | is_relay(relay_commands($bin)) or is_relay' >/dev/null; then return 1; fi
  [ -n "$CURRENT_PROFILE" ] || line=''
  if [ -n "$wrapped" ]; then
    wrapped=$(printf '%s' "$input" | bash -c "$wrapped")
    if [ -n "$wrapped" ]; then
      if [ -n "$line" ]; then line="$line │ $wrapped"; else line=$wrapped; fi
    fi
  fi
  [ -z "$line" ] || printf '%s\n' "$line"
}
cmd_hook() {
  case "${1:-}" in guard) hook_guard ;; stop-failure) hook_stop_failure ;; *) return 1 ;; esac
}
hook_guard() {
  load_pool
  [ -n "$CURRENT_PROFILE" ] || return 0
  local input sid event cwd transcript plan fields score reset level marker md project stamp context best='' record output metrics
  input=$(cat)
  validate_input "$input"
  sid=$(printf '%s' "$input" | jq -er '.session_id | select(type=="string")')
  safe_name "$sid" || return 1
  # A delivered handoff remains valid until its reset or a new capture/config.
  local file unchanged deadline current_time
  current_time=$(jq -nr 'now|floor')
  for marker in "$STATE_DIR/warned/$CURRENT_PROFILE-$sid-handoff-"*; do
    [ -f "$marker" ] || continue
    deadline=${marker##*-}
    case "$deadline" in ''|*[!0-9]*) continue ;; esac
    [ "$deadline" -gt "$current_time" ] || continue
    [ "$(cat "$marker")" = "$WARN_AT $HANDOFF_AT $CAPTURE_MAX_AGE" ] || continue
    unchanged=true
    for file in "$CONFIG_DIR/config" "$STATE_DIR/usage/$CURRENT_PROFILE.json" "$STATE_DIR/usage/$CURRENT_PROFILE/"*.json; do
      [ ! "$file" -nt "$marker" ] || unchanged=false
    done
    if $unchanged; then return 0; fi
  done
  metrics=$(measurement "$CURRENT_PROFILE")
  # Validate all fields before producing any side effects.
  plan=$(printf '%s' "$input" | jq -c --argjson m "$metrics" \
    --arg w "$WARN_AT" --arg h "$HANDOFF_AT" --arg u "$UNKNOWN_SCORE" '
    ([$w,$h,$u]|map(tonumber)) as $cfg |
    if ($cfg|all(.>=0 and .<=100)) and $cfg[0]<=$cfg[1] then . else error("Invalid thresholds") end |
    select(type=="object" and (.session_id|type=="string") and (.cwd|type=="string") and (.transcript_path|type=="string") and
      (.hook_event_name=="UserPromptSubmit" or .hook_event_name=="PostToolUse")) |
    . as $input |
    select($m.known and $m.score >= $cfg[0]) |
    $input + {score:$m.score,reset:$m.trigger_reset,level:(if $m.score >= $cfg[1] then "handoff" else "warn" end)}')
  [ -n "$plan" ] || return 0
  fields=$(printf '%s' "$plan" | jq -r '[.session_id,.hook_event_name,.score,.reset,.level]|@tsv')
  IFS=$'\t' read -r sid event score reset level <<< "$fields"
  safe_name "$sid" || return 1
  marker="$STATE_DIR/warned/$CURRENT_PROFILE-$sid-$level-$reset"
  [ ! -e "$marker" ] || return 0
  if [ "$level" = warn ]; then
    context="Profile $CURRENT_PROFILE quota usage is at $score %. Start wrapping up the work and do not start long tasks."
  else
    cwd=$(printf '%s' "$input" | jq -r .cwd)
    transcript=$(printf '%s' "$input" | jq -r .transcript_path)
    session_source "$(profile_dir "$CURRENT_PROFILE")" "$sid" "$transcript" "$cwd" true
    if $SOURCE_MISSING; then
      # Do not cache this fallback: once the transcript exists, deliver the
      # full handoff instruction and record instead of suppressing it.
      context="Profile $CURRENT_PROFILE quota usage is at $score %. Stop starting new work. The session transcript is not available yet. Summarize progress and next steps for the user now."
      jq -n --arg e "$event" --arg c "$context" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
      return 0
    fi
    transcript=$SOURCE_TRANSCRIPT
    project=$(project_name "$PROJECT")
    stamp=$(now_stamp)
    md="$STATE_DIR/handoffs/$project/$stamp-${sid:0:8}.md"
    # A private placeholder means the model's subsequent edit also stays 600.
    prepare_file "$md"
    (set -o noclobber; : > "$md") 2>/dev/null || [ -f "$md" ]
    chmod 600 "$md"
    if choose_profile "$CURRENT_PROFILE"; then best=$PICKED; fi
    record=$(jq -n --arg from "$CURRENT_PROFILE" --arg to "${best:-auto}" --arg sid "$sid" --arg cwd "$cwd" --arg t "$transcript" --arg md "$md" '{from:$from,to:$to,session_id:$sid,cwd:$cwd,transcript:$t,source_transcript:$t,handoff_md:$md,at:now}')
    printf '%s' "$record" | atomic_json "$STATE_DIR/sessions/$CURRENT_PROFILE-$sid.json"
    printf '%s' "$record" | atomic_json "$STATE_DIR/last-handoff.json"
    context="Profile $CURRENT_PROFILE quota usage is at $score %. Stop starting new work. Write the handoff NOW at the exact path $md, in the language of the conversation, with these sections: Goal; Status (done / in progress / pending); Files and branches touched; Decisions and why; Concrete next steps; Commands to verify; Risks/open questions. Then tell the user to run claude-relay resume --last in their terminal."
    [ -z "$best" ] || context="$context The best profile right now is $best; the user can select it with claude-relay resume --last --to $best."
  fi
  output=$(jq -n --arg e "$event" --arg c "$context" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}')
  prepare_file "$marker"
  # Atomic noclobber prevents concurrent hooks from issuing the same warning.
  if (set -o noclobber; printf '%s\n' "$WARN_AT $HANDOFF_AT $CAPTURE_MAX_AGE" > "$marker") 2>/dev/null; then printf '%s\n' "$output"; fi
}
hook_stop_failure() {
  load_pool
  [ -n "$CURRENT_PROFILE" ] || return 0
  local input sid transcript cwd to message record event
  input=$(cat)
  validate_input "$input"
  # JSONL escapes delimiters; strip control characters before truncation.
  # Deliberately project an allowlist, never the transcript or full input.
  event=$(printf '%s' "$input" | jq -ce --arg p "$CURRENT_PROFILE" '
    def sanitized: tostring | gsub("[\u0000-\u001f\u007f-\u009f]";" ") | .[:200];
    select(type=="object") | . as $input |
    {at:(now|todateiso8601),profile:$p,session_id:((.session_id // "")|sanitized),keys:keys} +
    (reduce ["error","error_type","error_details","matcher","reason","message"][] as $key
      ({}; if $input|has($key) then .[$key]=($input[$key]|sanitized) else . end))')
  prepare_file "$STATE_DIR/events.log"
  : >> "$STATE_DIR/events.log"
  chmod 600 "$STATE_DIR/events.log"
  printf '%s\n' "$event" >> "$STATE_DIR/events.log"
  # Classify the original fields, including text beyond the log's 200 chars.
  if ! printf '%s' "$input" | jq -e '
    [ .error,.error_type,.error_details,.matcher,.reason,.message ] |
    any(.[]; .=="rate_limit" or (tostring|test("rate.?limit|usage limit|session limit|weekly limit|hit your .*limit|limit reached";"i")))' >/dev/null; then return 0; fi
  mark_exhausted "$CURRENT_PROFILE" stop-failure
  message="account $CURRENT_PROFILE exhausted; could not copy the session"
  if printf '%s' "$input" | jq -e 'all([.session_id,.transcript_path,.cwd][]; type=="string" and length>0)' >/dev/null; then
    sid=$(printf '%s' "$input" | jq -r .session_id)
    transcript=$(printf '%s' "$input" | jq -r .transcript_path)
    cwd=$(printf '%s' "$input" | jq -r .cwd)
    # A separate worker keeps errexit active even inside this conditional:
    # failed copies must not leave a successful handoff record or skip notice.
    if record=$("$BASH" "$RELAY_BIN" handoff --from "$CURRENT_PROFILE" --to auto --session "$sid" --transcript "$transcript" --cwd "$cwd" --quiet --json 2>/dev/null); then
      to=$(printf '%s' "$record" | jq -er .to)
      message="account $CURRENT_PROFILE exhausted; session copied to profile $to. Run claude-relay resume --last."
    fi
  fi
  if [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 1 of argv) with title "claude-relay"
end run
APPLESCRIPT
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send claude-relay "$message" >/dev/null 2>&1 || true
  fi
}
