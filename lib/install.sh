#!/usr/bin/env bash
atomic_text() (
  local target=$1 tmp
  mkdir -p "$(dirname "$target")"
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
)
read_settings() {
  if [ -e "$1" ]; then
    jq -ce 'select(type=="object") | select((.hooks==null or (.hooks|type)=="object")) |
      select(all((.hooks // {})[]; type=="array")) |
      select(all((.hooks // {})[][]; type=="object" and (.hooks|type)=="array"))' "$1" || die "Settings inválido: $1"
  else printf '{}\n'; fi
}
write_settings() {
  local file=$1 data=$2 backup
  printf '%s' "$data" | jq -e 'type=="object"' >/dev/null
  [ ! -L "$file" ] || die "Settings simbólico rechazado: $file"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then
    backup=$(mktemp "$file.relay-backup-$(now_stamp).XXXXXX")
    cp -p "$file" "$backup"
    chmod 600 "$backup"
  fi
  printf '%s\n' "$data" | atomic_json "$file"
}
add_install_profile() {
  local name=$1 dir=$2 i=0
  safe_name "$name" || die "Nombre inválido: $name"
  dir=$(resolve_dir "$dir") || die "No existe el perfil: $dir"
  case "$dir" in *$'\n'*|*$'\t'*) die 'La ruta del perfil no admite tabs ni saltos de línea.' ;; esac
  while [ "$i" -lt "$INSTALL_COUNT" ]; do
    if [ "${INSTALL_NAMES[$i]}" = "$name" ]; then
      [ "${INSTALL_DIRS[$i]}" = "$dir" ] || die "Perfil duplicado: $name"
      return
    fi
    [ "${INSTALL_DIRS[$i]}" != "$dir" ] || die "Directorio duplicado: $dir"
    i=$((i+1))
  done
  INSTALL_NAMES[$INSTALL_COUNT]=$name INSTALL_DIRS[$INSTALL_COUNT]=$dir
  INSTALL_COUNT=$((INSTALL_COUNT+1))
}
cmd_install() {
  local settings=() settings_count=0 dry=false agent=false warn="$WARN_AT" handoff="$HANDOFF_AT"
  local names name i entry file original updated receipts='{}' pool='' config='' wrapped="$WRAPPED_STATUSLINE" command link existing
  local originals=() updates=()
  INSTALL_NAMES=() INSTALL_DIRS=() INSTALL_COUNT=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profiles)
        need_value "$@"; names=$2
        while :; do
          name=${names%%,*}; add_install_profile "$name" "${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}/$name"
          case "$names" in *,*) names=${names#*,} ;; *) break ;; esac
        done
        shift 2 ;;
      --profile)
        need_value "$@"; case "$2" in *=*) ;; *) die 'Usa --profile nombre=dir' ;; esac
        add_install_profile "${2%%=*}" "${2#*=}"; shift 2 ;;
      --settings) need_value "$@"; settings[$settings_count]=$(absolute_path "$2"); settings_count=$((settings_count+1)); shift 2 ;;
      --warn-at) need_value "$@"; warn=$2; shift 2 ;;
      --handoff-at) need_value "$@"; handoff=$2; shift 2 ;;
      --with-agent) agent=true; shift ;; --dry-run) dry=true; shift ;;
      *) die "Opción desconocida: $1" ;;
    esac
  done
  jq -en --arg w "$warn" --arg h "$handoff" '[$w,$h]|map(tonumber)|.[0]>=0 and .[0]<=.[1] and .[1]<=100' >/dev/null || die 'Umbrales inválidos.'
  if [ "$INSTALL_COUNT" -eq 0 ]; then add_install_profile default "$HOME/.claude"; fi
  if [ "$settings_count" -eq 0 ]; then
    if command -v claude-profile >/dev/null 2>&1; then
      settings[0]="$HOME/.claude/settings.json"; settings_count=1
    else
      i=0
      while [ "$i" -lt "$INSTALL_COUNT" ]; do settings[$i]="${INSTALL_DIRS[$i]}/settings.json"; i=$((i+1)); done
      settings_count=$INSTALL_COUNT
    fi
  fi
  link="$HOME/.local/bin/claude-relay"
  if [ -e "$link" ] || [ -L "$link" ]; then
    [ -L "$link" ] && [ "$(readlink "$link")" = "$RELAY_BIN" ] || die "Ya existe un ejecutable ajeno: $link"
  fi
  if $agent && [ -e "$HOME/.claude/agents/relay.md" ]; then
    cmp -s "$RELAY_ROOT/agents/relay.md" "$HOME/.claude/agents/relay.md" || die 'Ya existe un agente relay.md diferente.'
  fi
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then receipts=$(jq -ce 'select(type=="object")' "$CONFIG_DIR/installed-settings.json"); fi
  printf -v command '%q' "$RELAY_BIN"
  i=0
  while [ "$i" -lt "$settings_count" ]; do
    file=${settings[$i]}
    [ ! -L "$file" ] || die "Settings simbólico rechazado: $file"
    original=$(read_settings "$file")
    # Keep hook provenance, but respect a statusline the user changed since
    # installation. Never overwrite its original with our own wrapper.
    receipts=$(printf '%s' "$original" | jq -c -L "$RELAY_ROOT/lib" --arg file "$file" --argjson r "$receipts" --arg wrapped "$wrapped" '
      include "settings";
      if $r[$file]==null then
        (receipt | if (.statusLine? | is_relay) then
          .hadStatusLine=($wrapped!="") |
          .statusLine=(if $wrapped!="" then {type:"command",command:$wrapped} else null end)
        else . end) as $new | $r+{($file):$new}
      elif (.statusLine? | is_relay) then $r
      else . as $s | $r | .[$file].hadStatusLine=($s|has("statusLine")) | .[$file].statusLine=$s.statusLine end')
    existing=$(printf '%s' "$original" | jq -r '.statusLine | select((.command? // "" | contains("claude-relay"))|not) | .command // ""')
    [ -z "$existing" ] || wrapped=$existing
    updated=$(printf '%s' "$original" | jq -L "$RELAY_ROOT/lib" --arg command "$command" 'include "settings"; install($command)')
    originals[$i]=$original updates[$i]=$updated
    i=$((i+1))
  done
  i=0
  while [ "$i" -lt "$INSTALL_COUNT" ]; do
    printf -v entry '%s\t%s\n' "${INSTALL_NAMES[$i]}" "${INSTALL_DIRS[$i]}"
    pool="$pool$entry"; i=$((i+1))
  done
  # Keep unknown config keys and never source/eval this file.
  if [ -f "$CONFIG_DIR/config" ]; then
    while IFS= read -r entry || [ -n "$entry" ]; do
      case "$entry" in warn_at=*|handoff_at=*|unknown_score=*|wrapped_statusline=*) ;; *) config="$config$entry"$'\n' ;; esac
    done < "$CONFIG_DIR/config"
  fi
  case "$wrapped" in *$'\n'*) die 'La statusline previa contiene saltos de línea; no puede guardarse como clave=valor.' ;; esac
  config="${config}warn_at=$warn"$'\n'"handoff_at=$handoff"$'\n'"unknown_score=$UNKNOWN_SCORE"$'\n'"wrapped_statusline=$wrapped"$'\n'
  if $dry; then
    printf 'Pool propuesto:\n%sConfiguración propuesta:\n%s' "$pool" "$config"
    i=0
    while [ "$i" -lt "$settings_count" ]; do
      printf '\nSettings: %s\n' "${settings[$i]}"
      diff -u <(printf '%s\n' "${originals[$i]}" | jq .) <(printf '%s\n' "${updates[$i]}") || [ "$?" -eq 1 ]
      i=$((i+1))
    done
    printf '\nSymlink: %s -> %s\n' "$link" "$RELAY_BIN"
    if $agent; then printf 'Agente: %s/.claude/agents/relay.md\n' "$HOME"; fi
    return
  fi
  printf '%s' "$pool" | atomic_text "$POOL_FILE"
  printf '%s' "$config" | atomic_text "$CONFIG_DIR/config"
  printf '%s' "$receipts" | atomic_json "$CONFIG_DIR/installed-settings.json"
  i=0
  while [ "$i" -lt "$settings_count" ]; do write_settings "${settings[$i]}" "${updates[$i]}"; i=$((i+1)); done
  mkdir -p "$HOME/.local/bin"
  [ -L "$link" ] || ln -s "$RELAY_BIN" "$link"
  if $agent; then atomic_text "$HOME/.claude/agents/relay.md" < "$RELAY_ROOT/agents/relay.md"; fi
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf 'Añade %s/.local/bin a PATH.\n' "$HOME" >&2 ;; esac
  printf 'claude-relay instalado (%s perfiles).\n' "$INSTALL_COUNT"
}
cmd_uninstall() {
  local settings=() count=0 purge=false file receipt receipts='{}' original updated i=0 remaining link
  while [ "$#" -gt 0 ]; do
    case "$1" in --settings) need_value "$@"; settings[$count]=$(absolute_path "$2"); count=$((count+1)); shift 2 ;; --purge) purge=true; shift ;; *) die "Opción desconocida: $1" ;; esac
  done
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then receipts=$(cat "$CONFIG_DIR/installed-settings.json"); fi
  if [ "$count" -eq 0 ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      settings[$count]=$file; count=$((count+1))
    done < <(printf '%s' "$receipts" | jq -r 'keys[]')
    if [ "$count" -eq 0 ]; then
      if command -v claude-profile >/dev/null 2>&1; then settings[0]="$HOME/.claude/settings.json"; count=1
      elif [ -f "$POOL_FILE" ]; then
        load_pool
        while [ "$count" -lt "$POOL_COUNT" ]; do settings[$count]="${POOL_DIRS[$count]}/settings.json"; count=$((count+1)); done
      fi
    fi
  fi
  remaining=$receipts
  while [ "$i" -lt "$count" ]; do
    file=${settings[$i]} i=$((i+1))
    [ -f "$file" ] || continue
    original=$(read_settings "$file")
    receipt=$(printf '%s' "$receipts" | jq -c --arg f "$file" '.[$f]')
    updated=$(printf '%s' "$original" | jq -L "$RELAY_ROOT/lib" --argjson r "$receipt" --arg w "$WRAPPED_STATUSLINE" 'include "settings"; uninstall($r;$w)')
    write_settings "$file" "$updated"
    remaining=$(printf '%s' "$remaining" | jq -c --arg f "$file" 'del(.[$f])')
  done
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then printf '%s' "$remaining" | atomic_json "$CONFIG_DIR/installed-settings.json"; fi
  link="$HOME/.local/bin/claude-relay"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$RELAY_BIN" ]; then rm -f "$link"; fi
  if [ -f "$HOME/.claude/agents/relay.md" ] && cmp -s "$RELAY_ROOT/agents/relay.md" "$HOME/.claude/agents/relay.md"; then rm -f "$HOME/.claude/agents/relay.md"; fi
  if $purge; then rm -rf "$CONFIG_DIR" "$STATE_DIR"; fi
  printf 'claude-relay desinstalado.\n'
}
cmd_doctor() {
  [ "$#" -eq 0 ] || die 'Uso: doctor'
  local failed=0 i=0 file m jq_version
  jq_version=$(jq --version)
  printf 'jq: %s\nBash: %s\n' "$jq_version" "$BASH_VERSION"
  if [[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+) ]] &&
    { [ "${BASH_REMATCH[1]}" -gt 1 ] || { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -ge 6 ]; }; }; then :
  else printf 'Se requiere jq >= 1.6.\n'; failed=1; fi
  if [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    printf 'Se requiere Bash >= 3.2.\n'; failed=1
  fi
  if command -v "${CLAUDE_RELAY_CLAUDE_BIN:-claude}" >/dev/null 2>&1; then printf 'claude: disponible\n'; else printf 'claude: falta\n'; failed=1; fi
  load_pool
  printf 'Pool: %s perfiles\n' "$POOL_COUNT"
  while [ "$i" -lt "$POOL_COUNT" ]; do
    if [ ! -d "${POOL_DIRS[$i]}" ]; then printf '%s: directorio ausente\n' "${POOL_NAMES[$i]}"; failed=1; fi
    m=$(measurement "${POOL_NAMES[$i]}")
    printf '%s: %s\n' "${POOL_NAMES[$i]}" "$(printf '%s' "$m" | jq -r 'if .known then "dato de hace \(.age_seconds)s" else "sin dato" end')"
    i=$((i+1))
  done
  if [ ! -f "$CONFIG_DIR/installed-settings.json" ] || ! jq -e 'type=="object" and length>0' "$CONFIG_DIR/installed-settings.json" >/dev/null 2>&1; then printf 'Settings: sin instalación registrada\n'; failed=1
  else
    while IFS= read -r file; do
      if [ -f "$file" ] && jq -e '
        (.statusLine.command // "" | contains("claude-relay"))' "$file" >/dev/null 2>&1 &&
        jq -e '.hooks as $h | all(["UserPromptSubmit","PostToolUse","StopFailure"][]; . as $e | any($h[$e][]?.hooks[]?; (.command // "" | contains("claude-relay hook"))))' "$file" >/dev/null 2>&1; then
        printf 'Settings: OK %s\n' "$file"
      else printf 'Settings: faltan hooks/statusline en %s\n' "$file"; failed=1; fi
    done < <(jq -r 'keys[]' "$CONFIG_DIR/installed-settings.json")
  fi
  return "$failed"
}
