#!/usr/bin/env bash
captures() {
  local profile=$1 file found=false
  # The presence of session files disables legacy fallback, even if corrupt.
  {
    for file in "$STATE_DIR/usage/$profile/"*.json; do
      [ -f "$file" ] || continue
      found=true
      jq -ce 'select(type=="object")' "$file" 2>/dev/null || true
    done
    if ! $found && [ -f "$STATE_DIR/usage/$profile.json" ]; then
      jq -ce 'select(type=="object")' "$STATE_DIR/usage/$profile.json" 2>/dev/null || true
    fi
  } | jq -s .
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
    if [ -f "$dir/.claude.json" ]; then
      account=$(jq -c '{email:(.oauthAccount.emailAddress // null),organization:(.oauthAccount.organizationName // null)}' "$dir/.claude.json" 2>/dev/null) || account='{}'
    fi
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
  local profile=$1
  shift
  CLAUDE_CONFIG_DIR=$(profile_dir "$profile")
  [ -d "$CLAUDE_CONFIG_DIR" ] || die "Directory does not exist: $CLAUDE_CONFIG_DIR"
  export CLAUDE_CONFIG_DIR
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BASE_URL
  # The relay forwarder intentionally launches a separate Claude process.
  unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION
  exec "${CLAUDE_RELAY_CLAUDE_BIN:-claude}" "$@"
}
cmd_run() {
  local profile='' mode='' excludes=() count=0 separator=false
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
  launch_claude "$profile" "$@"
}
