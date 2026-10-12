#!/usr/bin/env bash
# Sourced by the CLI, which enables strict mode and umask 077.
die() { printf 'claude-relay: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1"; }
safe_name() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }
absolute_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; '~') printf '%s\n' "$HOME" ;; '~/'*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac
}
resolve_dir() (
  local path=$1
  case "$path" in /*) ;; *) path=$(absolute_path "$path") ;; esac
  cd -P "$path" 2>/dev/null && pwd -P
)
init_config() {
  CONFIG_DIR="$(absolute_path "${XDG_CONFIG_HOME:-$HOME/.config}")/claude-relay"
  STATE_DIR="$(absolute_path "${XDG_STATE_HOME:-$HOME/.local/state}")/claude-relay"
  POOL_FILE="$CONFIG_DIR/pool"
  WARN_AT=90 HANDOFF_AT=97 UNKNOWN_SCORE=50 EXHAUSTED_TTL=3600 CAPTURE_MAX_AGE=21600 MAX_DEPTH=1 WRAPPED_STATUSLINE=
  local key value
  if [ -f "$CONFIG_DIR/config" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
      case "$key" in
        warn_at) WARN_AT=$value ;; handoff_at) HANDOFF_AT=$value ;;
        unknown_score) UNKNOWN_SCORE=$value ;; wrapped_statusline) WRAPPED_STATUSLINE=$value ;;
        exhausted_ttl) EXHAUSTED_TTL=$value ;;
        capture_max_age) CAPTURE_MAX_AGE=$value ;;
        max_depth) MAX_DEPTH=$value ;;
      esac
    done < "$CONFIG_DIR/config"
  fi
  WARN_AT=${CLAUDE_RELAY_WARN_AT:-$WARN_AT}
  HANDOFF_AT=${CLAUDE_RELAY_HANDOFF_AT:-$HANDOFF_AT}
  EXHAUSTED_TTL=${CLAUDE_RELAY_EXHAUSTED_TTL:-$EXHAUSTED_TTL}
  CAPTURE_MAX_AGE=${CLAUDE_RELAY_CAPTURE_MAX_AGE:-$CAPTURE_MAX_AGE}
  MAX_DEPTH=${CLAUDE_RELAY_MAX_DEPTH:-$MAX_DEPTH}
  # Bad local configuration must not silently disable session integrations.
  if [ "${SAFE_WORKER:-false}" = true ]; then
    local defaults
    defaults=$(jq -nr --arg w "$WARN_AT" --arg h "$HANDOFF_AT" --arg u "$UNKNOWN_SCORE" --arg t "$EXHAUSTED_TTL" --arg a "$CAPTURE_MAX_AGE" --arg d "$MAX_DEPTH" '
      def pct($v;$default): try ($v|tonumber|if .>=0 and .<=100 then . else $default end) catch $default;
      def positive($v;$default): try ($v|tonumber|if .>0 and .==floor then . else $default end) catch $default;
      [pct($w;90),pct($h;97),pct($u;50),positive($t;3600),positive($a;21600)] |
      if .[0]>.[1] then .[0]=90 | .[1]=97 else . end | @tsv')
    IFS=$'\t' read -r WARN_AT HANDOFF_AT UNKNOWN_SCORE EXHAUSTED_TTL CAPTURE_MAX_AGE <<< "$defaults"
    valid_depth "$MAX_DEPTH" || MAX_DEPTH=1
    return
  fi
  jq -en --arg w "$WARN_AT" --arg h "$HANDOFF_AT" --arg u "$UNKNOWN_SCORE" '
    [$w,$h,$u] | map(tonumber) | all(.>=0 and .<=100) and (.[0]<=.[1])' >/dev/null || die 'Invalid thresholds (0–100, warn_at <= handoff_at).'
  jq -en --arg ttl "$EXHAUSTED_TTL" '$ttl|tonumber|.>0 and .==floor' >/dev/null || die 'exhausted_ttl must be a positive integer (seconds).'
  jq -en --arg age "$CAPTURE_MAX_AGE" '$age|tonumber|.>0 and .==floor' >/dev/null || die 'capture_max_age must be a positive integer (seconds).'
  valid_depth "$MAX_DEPTH" || die 'max_depth must be an integer from 0 to 2147483646.'
}
# Validate before arithmetic expansion, which otherwise interprets shell data.
valid_depth() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ] && [ "$1" -le 2147483646 ]
}
# Relay-owned trees must not redirect writes through symlinks. Only tighten
# their directories, never the user's HOME or XDG parents.
private_dir() {
  local path=$1 parent
  case "$path" in
    "$STATE_DIR"|"$CONFIG_DIR") [ ! -L "$path" ] || die "Symlink directory rejected: $path" ;;
    "$STATE_DIR"/*|"$CONFIG_DIR"/*)
      parent=${path%/*}; private_dir "$parent"
      [ ! -L "$path" ] || die "Symlink directory rejected: $path" ;;
    *)
      [ ! -L "$path" ] || die "Symlink directory rejected: $path"
      mkdir -p "$path"
      return ;;
  esac
  mkdir -p "$path"
  chmod 700 "$path"
}
prepare_file() {
  [ ! -L "$1" ] || die "Symlink file rejected: $1"
  private_dir "${1%/*}"
  [ ! -e "$1" ] || [ -f "$1" ] || die "Not a regular file: $1"
}
# Accept one object only. Slurping validates the entire stream before effects.
validate_input() {
  printf '%s' "$1" | jq -se 'length==1 and (.[0]|type)=="object"' >/dev/null
}
load_pool() {
  POOL_NAMES=() POOL_DIRS=() POOL_COUNT=0 CURRENT_PROFILE=
  local name dir extra resolved current i
  [ -f "$POOL_FILE" ] || die "Pool does not exist: $POOL_FILE; run install."
  current=$(resolve_dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" || true)
  CURRENT_CONFIG_DIR=${current:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
  while IFS=$'\t' read -r name dir extra || [ -n "$name" ]; do
    case "$name" in ''|'#'*) continue ;; esac
    safe_name "$name" || die "Invalid profile name: $name"
    [ -n "$dir" ] && [ -z "$extra" ] || die "Invalid line in pool: $name"
    case "$dir" in /*) ;; *) dir=$(absolute_path "$dir") ;; esac
    resolved=$(resolve_dir "$dir" || true)
    [ -z "$resolved" ] || dir=$resolved
    i=0
    while [ "$i" -lt "$POOL_COUNT" ]; do
      [ "${POOL_NAMES[$i]}" != "$name" ] && [ "${POOL_DIRS[$i]}" != "$dir" ] || die "Duplicate profile or directory: $name"
      i=$((i+1))
    done
    POOL_NAMES[$POOL_COUNT]=$name POOL_DIRS[$POOL_COUNT]=$dir
    POOL_COUNT=$((POOL_COUNT+1))
    if [ -n "$current" ] && [ "$current" = "$dir" ]; then CURRENT_PROFILE=$name; fi
  done < "$POOL_FILE"
  [ "$POOL_COUNT" -gt 0 ] || die 'Empty pool.'
}
profile_dir() {
  local i=0
  while [ "$i" -lt "$POOL_COUNT" ]; do
    if [ "${POOL_NAMES[$i]}" = "$1" ]; then printf '%s\n' "${POOL_DIRS[$i]}"; return; fi
    i=$((i+1))
  done
  die "Unknown profile: $1"
}
# All persisted JSON is checked before replacing an existing file.
atomic_json() (
  local target=$1 tmp
  prepare_file "$target"
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp"
  jq -e 'type=="object" or type=="array"' "$tmp" >/dev/null
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
)
project_name() { printf '%s' "$1" | jq -Rsr 'gsub("[^a-zA-Z0-9]";"-")'; }
now_stamp() { jq -nr 'now | strflocaltime("%Y%m%d-%H%M%S")'; }

private_task_dir() {
  local dir
  for dir in "$STATE_DIR" "$STATE_DIR/tasks"; do
    [ ! -L "$dir" ] || die "Symlink directory rejected: $dir"
    [ ! -e "$dir" ] || { [ -d "$dir" ] && [ -O "$dir" ]; } || die "Task directory must be owned by the current user: $dir"
  done
  private_dir "$STATE_DIR/tasks"
}
prune_task_files() (
  local cutoff file
  [ -d "$STATE_DIR/tasks" ] && [ ! -L "$STATE_DIR/tasks" ] || return 0
  cutoff=$(mktemp "$STATE_DIR/.task-prune.XXXXXX")
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr 'now-86400 | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff"
  for file in "$STATE_DIR/tasks/"task-*.txt; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ -O "$file" ] || continue
    [ "$file" -nt "$cutoff" ] || rm -f "$file"
  done
)

# POSIX ls exposes mode bits on both macOS and Linux without stat variants.
file_mode() {
  local bits
  bits=$(LC_ALL=C ls -ld "$1")
  bits=${bits:0:10}
  printf '%s' "$bits" | jq -Rr '
    . as $s |
    ((if ($s[3:4]|test("[sS]")) then 4 else 0 end) +
     (if ($s[6:7]|test("[sS]")) then 2 else 0 end) +
     (if ($s[9:10]|test("[tT]")) then 1 else 0 end)) as $special |
    [1,4,7] | map(. as $i |
      (if $s[$i:$i+1]=="r" then 4 else 0 end) +
      (if $s[$i+1:$i+2]=="w" then 2 else 0 end) +
      (if ($s[$i+2:$i+3]|test("[xst]")) then 1 else 0 end)) | join("") | (if $special==0 then "" else ($special|tostring) end) + .'
}
# New transcript directories are private; existing user directories are retained.
new_private_dir() {
  local path=$1
  [ ! -L "$path" ] || die "Symlink directory rejected: $path"
  [ ! -d "$path" ] || return 0
  new_private_dir "${path%/*}"
  mkdir "$path"
  chmod 700 "$path"
}
