#!/usr/bin/env bash
measurement() {
  local data='{}'
  if [ -f "$STATE_DIR/usage/$1.json" ]; then
    data=$(jq -ce 'select(type=="object")' "$STATE_DIR/usage/$1.json" 2>/dev/null) || data='{}'
  fi
  printf '%s\n' "$data" | jq -c -L "$RELAY_ROOT/lib" --argjson unknown "$UNKNOWN_SCORE" 'include "usage"; measurement($unknown)'
}
cmd_status() {
  local json=false i=0 name dir m account rows='[]'
  case "${1:-}" in --json) json=true; shift ;; esac
  [ "$#" -eq 0 ] || die 'Uso: status [--json]'
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
    printf '  PERFIL\tCUENTA\t5 h\tREINICIO 5 h\t7 d\tREINICIO 7 d\tANTIGÜEDAD\tPUNTAJE\n'
    printf '%s\n' "$rows" | jq -r '
      def pct: if .==null then "sin dato" else "\(.effective)%" + (if .expired then " (reinició)" else "" end) end;
      def reset: if .==null then "—" else .resets_at|strflocaltime("%Y-%m-%d %H:%M:%S %Z") end;
      .[] | [(if .current then "* " else "  " end)+.profile,
      ([.account.email,.account.organization]|map(select(.!=null))|join(" · ")),
      (.five_hour|pct),(.five_hour|reset),(.seven_day|pct),(.seven_day|reset),
      (if .age_seconds==null then "sin dato" else "\(.age_seconds)s" end),(.score|tostring)] | @tsv'
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
  [ -n "$best" ] || { printf 'claude-relay: no hay perfiles candidatos.\n' >&2; return 3; }
  PICKED=$best PICKED_METRICS=$best_m
}
cmd_pick() {
  local json=false excludes=() count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in --json) json=true; shift ;; --exclude) need_value "$@"; excludes[$count]=$2; count=$((count+1)); shift 2 ;; *) die "Opción desconocida: $1" ;; esac
  done
  load_pool
  choose_profile ${excludes[@]+"${excludes[@]}"}
  if $json; then jq -n --arg p "$PICKED" --arg d "$(profile_dir "$PICKED")" --argjson m "$PICKED_METRICS" '$m+{profile:$p,config_dir:$d}'; else printf '%s\n' "$PICKED"; fi
}
launch_claude() {
  local profile=$1
  shift
  CLAUDE_CONFIG_DIR=$(profile_dir "$profile")
  [ -d "$CLAUDE_CONFIG_DIR" ] || die "No existe $CLAUDE_CONFIG_DIR"
  export CLAUDE_CONFIG_DIR
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BASE_URL
  # The relay forwarder intentionally launches a separate Claude process.
  unset CLAUDECODE
  exec "${CLAUDE_RELAY_CLAUDE_BIN:-claude}" "$@"
}
cmd_run() {
  local profile='' mode='' excludes=() count=0 separator=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile) need_value "$@"; [ -z "$mode" ] || die '--profile y --pick son excluyentes.'; mode=profile; profile=$2; shift 2 ;;
      --pick) [ -z "$mode" ] || die '--profile y --pick son excluyentes.'; mode=pick; shift ;;
      --exclude) need_value "$@"; excludes[$count]=$2; count=$((count+1)); shift 2 ;;
      --) separator=true; shift; break ;; *) die "Opción desconocida: $1" ;;
    esac
  done
  $separator || die 'Uso: run [--profile P | --pick] [--exclude P] -- <args>'
  load_pool
  if [ "$mode" = pick ]; then choose_profile ${excludes[@]+"${excludes[@]}"}; profile=$PICKED; fi
  profile=${profile:-$CURRENT_PROFILE}
  [ -n "$profile" ] || die 'Fuera del pool: indica --profile o --pick.'
  local excluded
  for excluded in ${excludes[@]+"${excludes[@]}"}; do [ "$profile" != "$excluded" ] || die "Perfil excluido: $profile"; done
  printf 'claude-relay: perfil %s\n' "$profile" >&2
  launch_claude "$profile" "$@"
}
