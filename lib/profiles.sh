#!/usr/bin/env bash
# Project only the two permitted login metadata fields, never whole auth data.
account_metadata() {
  local file="$1/.claude.json"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    jq -cse '
      if length!=1 then error("Invalid metadata") else .[0] end |
      {email:(.oauthAccount.emailAddress | if type=="string" then . else null end),
       organization:(.oauthAccount.organizationName | if type=="string" then . else null end)}' "$file" 2>/dev/null || printf '{}\n'
  else printf '{}\n'; fi
}
detect_profiles() {
  local dir name base account rows='[]' in_pool i suffix reserved
  POOL_COUNT=0 POOL_NAMES=() POOL_DIRS=()
  [ ! -f "$POOL_FILE" ] || load_pool
  reserved=$(printf '%s\n' ${POOL_NAMES[@]+"${POOL_NAMES[@]}"} | jq -Rsc 'split("\n")|map(select(length>0))')
  for dir in "$HOME/.claude" "${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"/* "${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"/.[!.]* "${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"/..?* "${CLAUDE_CONFIG_DIR:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    dir=$(resolve_dir "$dir") || continue
    case "$dir" in *$'\t'*|*$'\n'*) continue ;; esac
    if printf '%s' "$rows" | jq -e --arg d "$dir" 'any(.[]; .path==$d)' >/dev/null; then continue; fi
    in_pool=false i=0 name=''
    while [ "$i" -lt "$POOL_COUNT" ]; do
      if [ "$dir" = "${POOL_DIRS[$i]}" ]; then in_pool=true; name=${POOL_NAMES[$i]}; break; fi
      i=$((i+1))
    done
    if [ -z "$name" ]; then
      if [ "$dir" = "$(resolve_dir "$HOME/.claude" || true)" ]; then name=default
      else name=$(printf '%s' "${dir##*/}" | jq -Rr 'gsub("[^a-zA-Z0-9._-]";"-") | sub("^[^a-zA-Z0-9]+";"") | if .=="" then "profile" else . end'); fi
      base=$name suffix=1
      while printf '%s' "$rows" | jq -e --arg n "$name" --argjson reserved "$reserved" 'any(.[]; .name==$n) or (($reserved|index($n))!=null)' >/dev/null; do
        suffix=$((suffix+1)); name="$base-$suffix"
      done
    fi
    account=$(account_metadata "$dir")
    rows=$(jq -cn --argjson rows "$rows" --argjson a "$account" --arg n "$name" --arg d "$dir" --argjson pooled "$in_pool" \
      '$rows+[{name:$n,path:$d,logged_in:(($a.email // "")|length>0),email:($a.email // null),organization:($a.organization // null),in_pool:$pooled}]')
  done
  printf '%s\n' "$rows"
}
detect_table() {
  printf 'NAME\tPATH\tLOGGED IN\tEMAIL\tORGANIZATION\tIN POOL\n'
  jq -r '.[] | [.name,.path,.logged_in,.email,.organization,.in_pool] | @tsv'
}
cmd_detect() {
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || die 'Usage: detect [--json]'; detect_profiles | detect_table ;;
    --json) [ "$#" -eq 1 ] || die 'Usage: detect [--json]'; detect_profiles | jq . ;;
    *) die 'Usage: detect [--json]' ;;
  esac
}
captures() {
  local profile=$1 file found=false data files=() count=0
  [ ! -L "$STATE_DIR/usage" ] && [ ! -L "$STATE_DIR/usage/$profile" ] || return 1
  for file in "$STATE_DIR/usage/$profile/"*.json; do
    [ -f "$file" ] || continue
    found=true
    [ ! -L "$file" ] || continue
    files[$count]=$file; count=$((count+1))
  done
  if ! $found && [ -f "$STATE_DIR/usage/$profile.json" ] && [ ! -L "$STATE_DIR/usage/$profile.json" ]; then
    files[$count]="$STATE_DIR/usage/$profile.json"; count=$((count+1))
  fi
  if [ "$count" -eq 0 ]; then printf '[]\n'; return; fi
  if data=$(jq -cs 'map(select(type=="object"))' "${files[@]}" 2>/dev/null); then
    printf '%s\n' "$data"
  else
    # One damaged file must not hide the remaining captures.
    for file in "${files[@]}"; do
      jq -ce 'select(type=="object")' "$file" 2>/dev/null || true
    done | jq -s .
  fi
}
measurement() {
  local data marker='{}'
  data=$(captures "$1")
  if [ -f "$STATE_DIR/exhausted/$1.json" ]; then
    marker=$(jq -ce 'select(type=="object")' "$STATE_DIR/exhausted/$1.json" 2>/dev/null) || marker='{}'
  fi
  printf '%s\n' "$data" | jq -c -L "$RELAY_ROOT/lib" --argjson marker "$marker" --argjson unknown "$UNKNOWN_SCORE" --arg max_age "$CAPTURE_MAX_AGE" '
    include "usage"; measurements($unknown;$max_age) |
    if ($marker.until|type)=="number" and $marker.until>now then
      . + {score:100,exhausted:true,exhausted_until:$marker.until}
    else . + {exhausted:false} end'
}
# A failed request has no rate_limits capture, so persist exhaustion separately.
mark_exhausted() {
  local profile=$1 source=$2 mode=${3:-default} value=${4:-0} m
  m=$(measurement "$profile")
  jq -n --arg p "$profile" --arg source "$source" --arg mode "$mode" --arg value "$value" \
    --arg ttl "$EXHAUSTED_TTL" --argjson m "$m" '
    now as $at | ($ttl|tonumber) as $ttl |
    if $ttl>0 and $ttl==($ttl|floor) then . else error("Invalid exhausted_ttl") end |
    {profile:$p,at:$at,source:$source,until:
      (if $mode=="until" then ($value|tonumber)
       elif $mode=="for" then $at+($value|tonumber)
       elif $m.five_hour!=null and $m.five_hour.resets_at>$at then $m.five_hour.resets_at
       else $at+$ttl end)}' | atomic_json "$STATE_DIR/exhausted/$profile.json"
}
cmd_exhausted() {
  [ "$#" -gt 0 ] || die 'Usage: exhausted <profile> [--for DURATION | --until EPOCH] [--clear]'
  local profile=$1 mode=default value=0 clear=false
  shift
  load_pool
  profile_dir "$profile" >/dev/null
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for|--until)
        need_value "$@"
        [ "$mode" = default ] && ! $clear || die '--for, --until and --clear are mutually exclusive.'
        mode=${1#--}
        if [ "$mode" = for ]; then
          value=$(jq -enr --arg duration "$2" '$duration | capture("^(?<n>[0-9]+)(?<unit>[smh])$") |
            (.n|tonumber) * (if .unit=="h" then 3600 elif .unit=="m" then 60 else 1 end) | select(.>0)') || die 'Invalid duration: use 90m, 4h or 3600s.'
        else
          value=$(jq -enr --arg epoch "$2" '$epoch|tonumber|select(.>=0 and .==floor)') || die 'Invalid epoch.'
        fi
        shift 2 ;;
      --clear) [ "$mode" = default ] || die '--for, --until and --clear are mutually exclusive.'; clear=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if $clear; then rm -f "$STATE_DIR/exhausted/$profile.json"
  else mark_exhausted "$profile" manual "$mode" "$value"; fi
}
cmd_status() {
  local json=false i=0 name dir m account rows='[]'
  case "${1:-}" in --json) json=true; shift ;; esac
  [ "$#" -eq 0 ] || die 'Usage: status [--json]'
  load_pool
  while [ "$i" -lt "$POOL_COUNT" ]; do
    name=${POOL_NAMES[$i]} dir=${POOL_DIRS[$i]}
    m=$(measurement "$name") account='{}'
    # Only these two non-secret fields leave jq; never dump the auth file.
    account=$(account_metadata "$dir")
    rows=$(jq -cn --argjson rows "$rows" --argjson m "$m" --argjson account "$account" --arg name "$name" --arg dir "$dir" --arg current "$CURRENT_PROFILE" '$rows + [$m + {profile:$name,config_dir:$dir,current:($name==$current),account:$account}]')
    i=$((i+1))
  done
  if $json; then printf '%s\n' "$rows" | jq .; else
    printf '  PROFILE\tACCOUNT\t5 h\t5 h RESET\t7 d\t7 d RESET\tAGE\tSCORE\tSTATUS\n'
    printf '%s\n' "$rows" | jq -r '
      def pct: if .==null then "no data" else "\(.effective)%" + (if .expired then " (reset)" else "" end) end;
      def reset: if .==null then "—" else .resets_at|strflocaltime("%Y-%m-%d %H:%M:%S %Z") end;
      .[] | [(if .current then "* " else "  " end)+.profile,
      ([.account.email,.account.organization]|map(select(.!=null))|join(" · ")),
      (.five_hour|pct),(.five_hour|reset),(.seven_day|pct),(.seven_day|reset),
      (if .age_seconds==null then "no data" else "\(.age_seconds)s" end),(.score|tostring),
      (if .exhausted then "exhausted until " + (.exhausted_until|strflocaltime("%H:%M")) else "" end)] | @tsv'
  fi
}
choose_profile() {
  local i=0 name dir score m best='' best_m='' lowest=101 x skip
  while [ "$i" -lt "$POOL_COUNT" ]; do
    name=${POOL_NAMES[$i]} dir=${POOL_DIRS[$i]} i=$((i+1))
    [ -d "$dir" ] || continue
    skip=false
    for x in "$@"; do [ "$name" != "$x" ] || skip=true; done
    $skip && continue
    m=$(measurement "$name") score=$(printf '%s' "$m" | jq -r .score)
    if jq -en --argjson s "$score" --argjson h "$HANDOFF_AT" --argjson b "$lowest" '$s<$h and $s<$b' >/dev/null; then
      best=$name best_m=$m lowest=$score
    fi
  done
  [ -n "$best" ] || { printf 'claude-relay: no eligible profiles.\n' >&2; return 3; }
  PICKED=$best PICKED_METRICS=$best_m
}
cmd_pick() {
  local json=false excludes=() count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --json) json=true; shift ;; --exclude) need_value "$@"; excludes[$count]=$2; count=$((count+1)); shift 2 ;; *) die "Unknown option: $1" ;; esac
  done
  load_pool
  choose_profile ${excludes[@]+"${excludes[@]}"}
  if $json; then jq -n --arg p "$PICKED" --arg d "$(profile_dir "$PICKED")" --argjson m "$PICKED_METRICS" '$m+{profile:$p,config_dir:$d}'; else printf '%s\n' "$PICKED"; fi
}
launch_claude() {
  local profile=$1 launch_mode=$2
  shift 2
  CLAUDE_CONFIG_DIR=$(profile_dir "$profile")
  [ -d "$CLAUDE_CONFIG_DIR" ] || die "Directory does not exist: $CLAUDE_CONFIG_DIR"
  export CLAUDE_CONFIG_DIR
  if [ "$launch_mode" = interactive ]; then unset CLAUDE_RELAY_DEPTH
  else
    valid_depth "${CLAUDE_RELAY_DEPTH:-0}" || die 'Invalid CLAUDE_RELAY_DEPTH.'
    CLAUDE_RELAY_DEPTH=$((10#${CLAUDE_RELAY_DEPTH:-0}+1))
    export CLAUDE_RELAY_DEPTH
  fi
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BASE_URL
  # The relay forwarder intentionally launches a separate Claude process.
  unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION
  exec "${CLAUDE_RELAY_CLAUDE_BIN:-claude}" "$@"
}
cmd_run() {
  local profile='' mode='' excludes=() count=0 separator=false
  valid_depth "${CLAUDE_RELAY_DEPTH:-0}" || die 'Invalid CLAUDE_RELAY_DEPTH.'
  [ "${CLAUDE_RELAY_DEPTH:-0}" -lt "$MAX_DEPTH" ] || die "Recursion refused: CLAUDE_RELAY_DEPTH reached max_depth=$MAX_DEPTH."
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile) need_value "$@"; [ -z "$mode" ] || die '--profile and --pick are mutually exclusive.'; mode=profile; profile=$2; shift 2 ;;
      --pick) [ -z "$mode" ] || die '--profile and --pick are mutually exclusive.'; mode=pick; shift ;;
      --exclude) need_value "$@"; excludes[$count]=$2; count=$((count+1)); shift 2 ;;
      --) separator=true; shift; break ;; *) die "Unknown option: $1" ;;
    esac
  done
  $separator || die 'Usage: run [--profile P | --pick] [--exclude P] -- <args>'
  load_pool
  if [ "$mode" = pick ]; then choose_profile ${excludes[@]+"${excludes[@]}"}; profile=$PICKED; fi
  profile=${profile:-$CURRENT_PROFILE}
  [ -n "$profile" ] || die 'Outside the pool: specify --profile or --pick.'
  local excluded
  for excluded in ${excludes[@]+"${excludes[@]}"}; do [ "$profile" != "$excluded" ] || die "Excluded profile: $profile"; done
  printf 'claude-relay: profile %s\n' "$profile" >&2
  launch_claude "$profile" child "$@"
}

cmd_forward() (
  local task='' mode=plan cleanup
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-file) need_value "$@"; [ -z "$task" ] || die 'Only one task file is allowed.'; task=$(absolute_path "$2"); shift 2 ;;
      --write) mode=acceptEdits; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [ -n "$task" ] || die 'Usage: forward --task-file PATH [--write]'
  # Never remove an untrusted directory or another user's file.
  [ ! -L "$task" ] && [ -f "$task" ] && [ -O "$task" ] || die 'Task must be an owned regular file, not a symlink.'
  printf -v cleanup 'rm -f %q' "$task"
  trap "$cleanup" EXIT
  trap 'exit 1' HUP INT TERM
  [ "$(file_mode "$task")" = 600 ] || die 'Task file must have mode 600.'
  init_config
  [ "${CLAUDE_RELAY_DEPTH+x}" != x ] || die 'Recursion refused: CLAUDE_RELAY_DEPTH is set.'
  [ "$MAX_DEPTH" -gt 0 ] || die 'Forwarding disabled by max_depth=0.'
  load_pool
  [ -n "$CURRENT_PROFILE" ] || die 'Cannot identify the current profile in the pool.'
  choose_profile "$CURRENT_PROFILE"
  printf 'claude-relay: profile %s\n' "$PICKED" >&2
  # The parent retains its cleanup trap while the child execs Claude.
  (launch_claude "$PICKED" child -p --output-format text --permission-mode "$mode") < "$task"
)
