#!/usr/bin/env bash
cmd_statusline() {
  load_pool
  [ -n "$CURRENT_PROFILE" ] || return 0
  local input data line wrapped='' receipts='{}' result save recovered
  input=$(cat; printf '.')
  input=${input%.}
  # Per-settings originals let different profiles retain distinct status lines.
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then
    receipts=$(cat "$CONFIG_DIR/installed-settings.json")
  fi
  result=$(printf '%s' "$input" | jq -er -L "$RELAY_ROOT/lib" --arg p "$CURRENT_PROFILE" \
    --arg settings "$(profile_dir "$CURRENT_PROFILE")/settings.json" --argjson receipts "$receipts" --arg wrapped "$WRAPPED_STATUSLINE" '
    include "usage";
    select(type=="object") |
    {profile:$p,captured_at:now,session_id:(.session_id // ""),rate_limits:(.rate_limits // {})} as $data |
    ($data|measurement(50)) as $m |
    ($p+" · "+(if $m.known then
      [if $m.five_hour!=null then "5h \($m.five_hour.effective)%" else empty end,
       if $m.seven_day!=null then "7d \($m.seven_day.effective)%" else empty end]|join(" · ") else "sin dato" end)) as $line |
    [($data|tojson),($m.known|tostring),$line,
     (if $receipts|has($settings) then $receipts[$settings].statusLine.command // "" else $wrapped end)] | .[]')
  # The first three values cannot contain literal newlines. Preserve the rest
  # as the wrapper command, rather than splitting paths or shell syntax.
  data=${result%%$'\n'*}; result=${result#*$'\n'}
  save=${result%%$'\n'*}; result=${result#*$'\n'}
  line=${result%%$'\n'*}
  case "$result" in *$'\n'*) wrapped=${result#*$'\n'} ;; esac
  # Missing windows never erase a previous account measurement.
  if [ "$save" = true ]; then
    printf '%s' "$data" | atomic_json "$STATE_DIR/usage/$CURRENT_PROFILE.json"
    if [ -f "$STATE_DIR/exhausted/$CURRENT_PROFILE.json" ]; then
      recovered=$(printf '%s' "$data" | jq -r -L "$RELAY_ROOT/lib" --argjson h "$HANDOFF_AT" \
        --slurpfile marker "$STATE_DIR/exhausted/$CURRENT_PROFILE.json" '
        include "usage"; . as $data | measurement(50) |
        .known and .score<$h and ($marker[0].at|type)=="number" and $data.captured_at>$marker[0].at')
      if [ "$recovered" = true ]; then rm -f "$STATE_DIR/exhausted/$CURRENT_PROFILE.json"; fi
    fi
  fi
  # Broken/migrated receipts must not recursively launch this statusline.
  case "$wrapped" in *claude-relay*statusline*) return 1 ;; esac
  if [ -n "$wrapped" ]; then
    wrapped=$(printf '%s' "$input" | bash -c "$wrapped")
    [ -z "$wrapped" ] || line="$line │ $wrapped"
  fi
  printf '%s\n' "$line"
}
cmd_hook() {
  case "${1:-}" in guard) hook_guard ;; stop-failure) hook_stop_failure ;; *) return 1 ;; esac
}
hook_guard() {
  load_pool
  [ -n "$CURRENT_PROFILE" ] || return 0
  [ -f "$STATE_DIR/usage/$CURRENT_PROFILE.json" ] || return 0
  local input sid event cwd transcript plan fields score reset level marker md project stamp context best='' record output
  input=$(cat)
  # Validate all fields before producing any side effects.
  plan=$(printf '%s' "$input" | jq -c -L "$RELAY_ROOT/lib" --slurpfile usage "$STATE_DIR/usage/$CURRENT_PROFILE.json" \
    --arg w "$WARN_AT" --arg h "$HANDOFF_AT" --arg u "$UNKNOWN_SCORE" '
    include "usage";
    ([$w,$h,$u]|map(tonumber)) as $cfg |
    if ($cfg|all(.>=0 and .<=100)) and $cfg[0]<=$cfg[1] then . else error("Umbrales inválidos") end |
    select(type=="object" and (.session_id|type=="string") and (.cwd|type=="string") and (.transcript_path|type=="string") and
      (.hook_event_name=="UserPromptSubmit" or .hook_event_name=="PostToolUse")) |
    . as $input | ($usage[0]|measurement($cfg[2])) as $m |
    select($m.known and $m.score >= $cfg[0]) |
    $input + {score:$m.score,reset:$m.trigger_reset,level:(if $m.score >= $cfg[1] then "handoff" else "warn" end)}')
  [ -n "$plan" ] || return 0
  fields=$(printf '%s' "$plan" | jq -r '[.session_id,.hook_event_name,.score,.reset,.level]|@tsv')
  IFS=$'\t' read -r sid event score reset level <<< "$fields"
  safe_name "$sid" || return 1
  marker="$STATE_DIR/warned/$CURRENT_PROFILE-$sid-$level-$reset"
  [ ! -e "$marker" ] || return 0
  if [ "$level" = warn ]; then
    context="Cuota del perfil $CURRENT_PROFILE en $score %. Ve cerrando el trabajo y no empieces tareas largas."
  else
    cwd=$(printf '%s' "$input" | jq -r .cwd)
    transcript=$(printf '%s' "$input" | jq -r .transcript_path)
    project=$(basename "$(dirname "$transcript")")
    case "$project" in ''|.|..|/) project=$(project_name "$cwd") ;; esac
    stamp=$(now_stamp)
    md="$STATE_DIR/handoffs/$project/$stamp-${sid:0:8}.md"
    # A private placeholder means the model's subsequent edit also stays 600.
    mkdir -p "$(dirname "$md")"
    (set -o noclobber; : > "$md") 2>/dev/null || [ -f "$md" ]
    chmod 600 "$md"
    if choose_profile "$CURRENT_PROFILE"; then best=$PICKED; fi
    record=$(jq -n --arg from "$CURRENT_PROFILE" --arg to "${best:-auto}" --arg sid "$sid" --arg cwd "$cwd" --arg t "$transcript" --arg md "$md" '{from:$from,to:$to,session_id:$sid,cwd:$cwd,transcript:$t,source_transcript:$t,handoff_md:$md,at:now}')
    printf '%s' "$record" | atomic_json "$STATE_DIR/sessions/$CURRENT_PROFILE-$sid.json"
    printf '%s' "$record" | atomic_json "$STATE_DIR/last-handoff.json"
    context="Cuota del perfil $CURRENT_PROFILE en $score %. Deja de empezar trabajo nuevo. Escribe YA el handoff en la ruta exacta $md, en el idioma de la conversación, con estas secciones: Objetivo; Estado (hecho / en curso / pendiente); Archivos y ramas tocados; Decisiones y por qué; Próximos pasos concretos; Comandos para verificar; Riesgos/dudas. Después dile al usuario que ejecute claude-relay resume --last en su terminal."
    [ -z "$best" ] || context="$context El mejor perfil ahora es $best; puede elegirlo con claude-relay resume --last --to $best."
  fi
  output=$(jq -n --arg e "$event" --arg c "$context" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}')
  mkdir -p "$STATE_DIR/warned"
  # Atomic noclobber prevents concurrent hooks from issuing the same warning.
  if (set -o noclobber; : > "$marker") 2>/dev/null; then printf '%s\n' "$output"; fi
}
hook_stop_failure() {
  load_pool
  [ -n "$CURRENT_PROFILE" ] || return 0
  local input sid transcript cwd to message record event
  input=$(cat)
  # JSONL escapes delimiters; strip control characters before truncation.
  # Deliberately project an allowlist, never the transcript or full input.
  event=$(printf '%s' "$input" | jq -ce --arg p "$CURRENT_PROFILE" '
    def sanitized: tostring | gsub("[\u0000-\u001f\u007f-\u009f]";" ") | .[:200];
    select(type=="object") | . as $input |
    {at:(now|todateiso8601),profile:$p,session_id:((.session_id // "")|sanitized),keys:keys} +
    (reduce ["error","error_type","error_details","matcher","reason","message"][] as $key
      ({}; if $input|has($key) then .[$key]=($input[$key]|sanitized) else . end))')
  mkdir -p "$STATE_DIR"
  : >> "$STATE_DIR/events.log"
  chmod 600 "$STATE_DIR/events.log"
  printf '%s\n' "$event" >> "$STATE_DIR/events.log"
  # Classify the original fields, including text beyond the log's 200 chars.
  if ! printf '%s' "$input" | jq -e '
    [ .error,.error_type,.error_details,.matcher,.reason,.message ] |
    any(.[]; .=="rate_limit" or (tostring|test("rate.?limit|usage limit|session limit|weekly limit|hit your .*limit|limit reached";"i")))' >/dev/null; then return 0; fi
  mark_exhausted "$CURRENT_PROFILE" stop-failure
  message="cuenta $CURRENT_PROFILE agotada; no se pudo copiar la sesión"
  if printf '%s' "$input" | jq -e 'all([.session_id,.transcript_path,.cwd][]; type=="string" and length>0)' >/dev/null; then
    sid=$(printf '%s' "$input" | jq -r .session_id)
    transcript=$(printf '%s' "$input" | jq -r .transcript_path)
    cwd=$(printf '%s' "$input" | jq -r .cwd)
    # A separate worker keeps errexit active even inside this conditional:
    # failed copies must not leave a successful handoff record or skip notice.
    if record=$("$BASH" "$RELAY_BIN" handoff --from "$CURRENT_PROFILE" --to auto --session "$sid" --transcript "$transcript" --cwd "$cwd" --quiet --json 2>/dev/null); then
      to=$(printf '%s' "$record" | jq -er .to)
      message="cuenta $CURRENT_PROFILE agotada; sesión copiada al perfil $to. Ejecuta claude-relay resume --last."
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
