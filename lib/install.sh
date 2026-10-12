#!/usr/bin/env bash
backup_file() {
  local file=$1 backup
  [ ! -L "$file" ] || die "Symlink file rejected: $file"
  if [ -f "$file" ]; then
    backup=$(mktemp "$file.relay-backup-$(now_stamp).XXXXXX")
    cp -p "$file" "$backup"
    chmod 600 "$backup"
  fi
}
atomic_text() (
  local target=$1 tmp
  prepare_file "$target"
  backup_file "$target"
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
      select(all((.hooks // {})[][]; type=="object" and (.hooks|type)=="array"))' "$1" || die "Invalid settings: $1"
  else printf '{}\n'; fi
}
write_settings() {
  local file=$1 data=$2 backup
  printf '%s' "$data" | jq -e 'type=="object"' >/dev/null
  [ ! -L "$file" ] || die "Symlink settings file rejected: $file"
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
  safe_name "$name" || die "Invalid name: $name"
  dir=$(resolve_dir "$dir") || die "Profile directory does not exist: $dir"
  case "$dir" in *$'\n'*|*$'\t'*) die 'Profile paths cannot contain tabs or newlines.' ;; esac
  while [ "$i" -lt "$INSTALL_COUNT" ]; do
    if [ "${INSTALL_NAMES[$i]}" = "$name" ]; then
      [ "${INSTALL_DIRS[$i]}" = "$dir" ] || die "Duplicate profile: $name"
      return
    fi
    [ "${INSTALL_DIRS[$i]}" != "$dir" ] || die "Duplicate directory: $dir"
    i=$((i+1))
  done
  INSTALL_NAMES[$INSTALL_COUNT]=$name INSTALL_DIRS[$INSTALL_COUNT]=$dir
  INSTALL_COUNT=$((INSTALL_COUNT+1))
}
cmd_install() {
  local settings=() settings_count=0 dry=false agent=false warn="$WARN_AT" handoff="$HANDOFF_AT"
  local names name i entry file original updated receipts='{}' pool='' config='' wrapped="$WRAPPED_STATUSLINE" command link existing detected logged reuse=false
  local agent_file="$HOME/.claude/agents/relay.md" agent_record="$CONFIG_DIR/agent.cksum" recorded=''
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
        need_value "$@"; case "$2" in *=*) ;; *) die 'Use --profile name=dir' ;; esac
        add_install_profile "${2%%=*}" "${2#*=}"; shift 2 ;;
      --settings) need_value "$@"; settings[$settings_count]=$(absolute_path "$2"); settings_count=$((settings_count+1)); shift 2 ;;
      --warn-at) need_value "$@"; warn=$2; shift 2 ;;
      --handoff-at) need_value "$@"; handoff=$2; shift 2 ;;
      --with-agent) agent=true; shift ;; --dry-run) dry=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  jq -en --arg w "$warn" --arg h "$handoff" '[$w,$h]|map(tonumber)|.[0]>=0 and .[0]<=.[1] and .[1]<=100' >/dev/null || die 'Invalid thresholds.'
  if [ "$INSTALL_COUNT" -eq 0 ]; then
    if [ -f "$POOL_FILE" ]; then
      load_pool
      reuse=true i=0
      while [ "$i" -lt "$POOL_COUNT" ]; do
        add_install_profile "${POOL_NAMES[$i]}" "${POOL_DIRS[$i]}"
        i=$((i+1))
      done
    else
      detected=$(detect_profiles)
      logged=$(printf '%s' "$detected" | jq '[.[]|select(.logged_in)]|length')
      if [ "$logged" -ne 1 ]; then
        printf '%s' "$detected" | detect_table
        printf 'claude-relay: %s logged-in profiles; choose with --profiles a,b or --profile name=dir\n' "$logged" >&2
        return 2
      fi
      name=$(printf '%s' "$detected" | jq -r '.[]|select(.logged_in)|.name')
      entry=$(printf '%s' "$detected" | jq -r '.[]|select(.logged_in)|.path')
      add_install_profile "$name" "$entry"
    fi
  fi
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then receipts=$(jq -ce 'select(type=="object")' "$CONFIG_DIR/installed-settings.json"); fi
  if $reuse && [ "$settings_count" -eq 0 ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      settings[$settings_count]=$file; settings_count=$((settings_count+1))
    done < <(printf '%s' "$receipts" | jq -r 'keys[]')
  fi
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
    [ -L "$link" ] && [ "$(readlink "$link")" = "$RELAY_BIN" ] || die "An unrelated executable already exists: $link"
  fi
  [ ! -f "$agent_record" ] || agent=true
  # A pre-checksum installation must not silently keep its old forwarder.
  if $reuse && [ -e "$agent_file" ]; then agent=true; fi
  if $agent; then
    [ ! -L "$agent_file" ] && [ ! -L "$agent_record" ] || die 'Symlink agent or checksum rejected.'
    [ ! -f "$agent_record" ] || recorded=$(cat "$agent_record")
    if [ -e "$agent_file" ]; then
      [ -f "$agent_file" ] || die "Not a regular file: $agent_file"
      if ! cmp -s "$RELAY_ROOT/agents/relay.md" "$agent_file" && [ "$(cksum < "$agent_file")" != "$recorded" ]; then
        die "relay.md was edited or is unrecognized: $agent_file. Move it aside to keep your edits, then rerun install --with-agent."
      fi
    fi
  fi
  printf -v command '%q' "$RELAY_BIN"
  i=0
  while [ "$i" -lt "$settings_count" ]; do
    file=${settings[$i]}
    [ ! -L "$file" ] || die "Symlink settings file rejected: $file"
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
      case "$entry" in warn_at=*|handoff_at=*|unknown_score=*|exhausted_ttl=*|capture_max_age=*|max_depth=*|wrapped_statusline=*) ;; *) config="$config$entry"$'\n' ;; esac
    done < "$CONFIG_DIR/config"
  fi
  case "$wrapped" in *$'\n'*) die 'The previous statusline contains newlines; it cannot be saved as key=value.' ;; esac
  config="${config}warn_at=$warn"$'\n'"handoff_at=$handoff"$'\n'"unknown_score=$UNKNOWN_SCORE"$'\n'"exhausted_ttl=$EXHAUSTED_TTL"$'\n'"capture_max_age=$CAPTURE_MAX_AGE"$'\n'"max_depth=$MAX_DEPTH"$'\n'"wrapped_statusline=$wrapped"$'\n'
  if $dry; then
    printf 'Proposed pool:\n%sProposed configuration:\n%s' "$pool" "$config"
    i=0
    while [ "$i" -lt "$settings_count" ]; do
      printf '\nSettings: %s\n' "${settings[$i]}"
      diff -u <(printf '%s\n' "${originals[$i]}" | jq .) <(printf '%s\n' "${updates[$i]}") || [ "$?" -eq 1 ]
      i=$((i+1))
    done
    printf '\nSymlink: %s -> %s\n' "$link" "$RELAY_BIN"
    if $agent; then printf 'Agent: %s/.claude/agents/relay.md\n' "$HOME"; fi
    return
  fi
  printf '%s' "$pool" | atomic_text "$POOL_FILE"
  printf '%s' "$config" | atomic_text "$CONFIG_DIR/config"
  backup_file "$CONFIG_DIR/installed-settings.json"
  printf '%s' "$receipts" | atomic_json "$CONFIG_DIR/installed-settings.json"
  i=0
  while [ "$i" -lt "$settings_count" ]; do write_settings "${settings[$i]}" "${updates[$i]}"; i=$((i+1)); done
  mkdir -p "$HOME/.local/bin"
  [ -L "$link" ] || ln -s "$RELAY_BIN" "$link"
  if $agent; then
    atomic_text "$agent_file" < "$RELAY_ROOT/agents/relay.md"
    cksum < "$agent_file" | atomic_text "$agent_record"
  fi
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf 'Add %s/.local/bin to PATH.\n' "$HOME" >&2 ;; esac
  printf 'claude-relay installed (%s profiles).\n' "$INSTALL_COUNT"
}
cmd_uninstall() {
  local settings=() count=0 purge=false file receipt receipts='{}' original updated i=0 remaining link
  while [ "$#" -gt 0 ]; do
    case "$1" in --settings) need_value "$@"; settings[$count]=$(absolute_path "$2"); count=$((count+1)); shift 2 ;; --purge) purge=true; shift ;; *) die "Unknown option: $1" ;; esac
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
  if [ -f "$CONFIG_DIR/installed-settings.json" ]; then
    backup_file "$CONFIG_DIR/installed-settings.json"
    printf '%s' "$remaining" | atomic_json "$CONFIG_DIR/installed-settings.json"
  fi
  link="$HOME/.local/bin/claude-relay"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$RELAY_BIN" ]; then rm -f "$link"; fi
  file="$HOME/.claude/agents/relay.md"
  if [ -f "$file" ] && [ ! -L "$file" ] && [ -f "$CONFIG_DIR/agent.cksum" ] &&
    [ "$(cksum < "$file")" = "$(cat "$CONFIG_DIR/agent.cksum")" ]; then
    backup_file "$file"
    rm -f "$file" "$CONFIG_DIR/agent.cksum"
  fi
  if $purge; then rm -rf "$CONFIG_DIR" "$STATE_DIR"; fi
  printf 'claude-relay uninstalled.\n'
}
cmd_doctor() {
  [ "$#" -eq 0 ] || die 'Usage: doctor'
  local failed=0 i=0 file m jq_version
  jq_version=$(jq --version)
  printf 'jq: %s\nBash: %s\n' "$jq_version" "$BASH_VERSION"
  if [[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+) ]] &&
    { [ "${BASH_REMATCH[1]}" -gt 1 ] || { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -ge 6 ]; }; }; then :
  else printf 'jq >= 1.6 is required.\n'; failed=1; fi
  if [ "${BASH_VERSINFO[0]}" -lt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    printf 'Bash >= 3.2 is required.\n'; failed=1
  fi
  if command -v "${CLAUDE_RELAY_CLAUDE_BIN:-claude}" >/dev/null 2>&1; then printf 'claude: available\n'; else printf 'claude: missing\n'; failed=1; fi
  load_pool
  printf 'Pool: %s profiles\n' "$POOL_COUNT"
  while [ "$i" -lt "$POOL_COUNT" ]; do
    if [ ! -d "${POOL_DIRS[$i]}" ]; then printf '%s: missing directory\n' "${POOL_NAMES[$i]}"; failed=1; fi
    m=$(measurement "${POOL_NAMES[$i]}")
    printf '%s: %s\n' "${POOL_NAMES[$i]}" "$(printf '%s' "$m" | jq -r 'if .known then "data from \(.age_seconds)s ago" else "no data" end')"
    i=$((i+1))
  done
  if [ ! -f "$CONFIG_DIR/installed-settings.json" ] || ! jq -e 'type=="object" and length>0' "$CONFIG_DIR/installed-settings.json" >/dev/null 2>&1; then printf 'Settings: no installation recorded\n'; failed=1
  else
    while IFS= read -r file; do
      if [ -f "$file" ] && jq -e '
        (.statusLine.command // "" | contains("claude-relay"))' "$file" >/dev/null 2>&1 &&
        jq -e '.hooks as $h | all(["UserPromptSubmit","PostToolUse","StopFailure"][]; . as $e | any($h[$e][]?.hooks[]?; (.command // "" | contains("claude-relay hook"))))' "$file" >/dev/null 2>&1; then
        printf 'Settings: OK %s\n' "$file"
      else printf 'Settings: missing hooks/statusline in %s\n' "$file"; failed=1; fi
    done < <(jq -r 'keys[]' "$CONFIG_DIR/installed-settings.json")
  fi
  return "$failed"
}
