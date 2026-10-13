#!/usr/bin/env bash
# Relay spend ledger: private per-run costs and token counts, never text.
SPEND_WINDOW=18000 SPEND_RETENTION=604800

prune_spend() (
  local cutoff
  [ ! -L "$STATE_DIR" ] && [ -d "$STATE_DIR/spend" ] && [ ! -L "$STATE_DIR/spend" ] || return 0
  cutoff=$(mktemp "$STATE_DIR/.spend-prune.XXXXXX") || return 0
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr --argjson r "$SPEND_RETENTION" 'now-$r | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff"
  find "$STATE_DIR/spend" -mindepth 2 -maxdepth 2 -type f ! -newer "$cutoff" -exec rm -f {} + 2>/dev/null || true
)

# A stream is one or more JSON objects, each with a string .type. The envelope
# is its last result with a boolean is_error; the usage event is its last
# rate_limit_event with an object of windows.
RUN_JQ='def is_stream: length>0 and all(.[]; type=="object" and (.type|type)=="string");
  def envelope: map(select(.type=="result" and (.is_error|type)=="boolean")) | last;
  def usage_event: map(select(.type=="rate_limit_event" and (.rate_limit_info|type)=="object"
    and (.rate_limit_info.unifiedWindows|type)=="object")) | last;
  def finite: type=="number" and (isinfinite|not) and (isnan|not)
    and . < 1.7976931348623157e308 and . > -1.7976931348623157e308;'

# A separate strict worker preserves errexit when forward handles its failure.
# Each part runs in its own errexit subshell, so one failure cannot skip another.
cmd_record_run() (
  exec 1>&2
  [ "$#" -eq 3 ] || die 'Usage: __record-run <profile> <session> <buffer>'
  local profile=$1 session=$2 buffer=$3 tasks parent part failed=0
  load_pool
  profile_dir "$profile" >/dev/null
  valid_session_id "$session" || die 'Invalid session ID.'
  [ ! -L "$STATE_DIR" ] && [ ! -L "$STATE_DIR/tasks" ] && [ ! -L "${buffer%/*}" ] || die 'Symlink task directory rejected.'
  tasks=$(resolve_dir "$STATE_DIR/tasks") || die 'No tasks directory.'
  parent=$(resolve_dir "${buffer%/*}") || die 'Invalid buffer.'
  [ "$parent" = "$tasks" ] || die 'Buffer must be inside the tasks directory.'
  case "${buffer##*/}" in out-*) ;; *) die 'Invalid buffer name.' ;; esac
  buffer="$parent/${buffer##*/}"
  [ ! -L "$buffer" ] && [ -f "$buffer" ] && [ -O "$buffer" ] || die 'Buffer must be an owned regular file.'
  [ "$(file_mode "$buffer")" = 600 ] || die 'Output buffer must have mode 600.'
  jq -se "$RUN_JQ"'is_stream' "$buffer" >/dev/null 2>&1 || return 0
  set +e
  for part in record_spend record_usage record_rejection; do
    (set -e; "$part" "$profile" "$session" "$buffer")
    [ "$?" -eq 0 ] || failed=1
  done
  set -e
  [ "$failed" -eq 0 ]
)

record_spend() {
  local profile=$1 session=$2 buffer=$3 dir record final epoch tries=0 entry totals json
  jq -se "$RUN_JQ"'envelope!=null' "$buffer" >/dev/null || return 0
  [ ! -L "$STATE_DIR/forwarded" ] || die 'Symlink directory rejected.'
  record="$STATE_DIR/forwarded/$session.json"
  [ ! -L "$record" ] || die 'Symlink forwarded record rejected.'
  totals='null'
  if [ -f "$record" ]; then
    totals=$(jq -cs 'if length==1 and (.[0]|type)=="object" then .[0].totals else null end' "$record" 2>/dev/null) || totals='null'
  fi
  epoch=$(jq -nr 'now|floor')
  # Keep the normalized cumulative totals alongside the per-run delta.
  entry=$(jq -sc --arg p "$profile" --arg s "$session" --argjson at "$epoch" --argjson base "$totals" "$RUN_JQ"'
    def obj: if type=="object" then . else {} end;
    def num($max): if type=="number" then
      if (isinfinite|not) and (isnan|not) and .>=0 and .<=$max then . else null end
      else null end;
    def tok: num(1e12) // 0;
    def less($b): if $b==null then . elif . >= $b then . - $b else . end;
    envelope as $r |
    {cost_usd:($r.total_cost_usd|num(100000)),
     models:($r.modelUsage | obj | to_entries
       | map(select((.key|test("^[A-Za-z0-9._:\\[\\]-]{1,128}\\z")) and (.value|type)=="object")
             | {key, value:{in:(.value.inputTokens|tok),out:(.value.outputTokens|tok),
                            cache_read:(.value.cacheReadInputTokens|tok),cache_write:(.value.cacheCreationInputTokens|tok)}})
       | from_entries)} as $now |
    ($base|obj) as $b |
    [{profile:$p,session_id:$s,at:$at,
      cost_usd:(if $now.cost_usd==null then null else ($now.cost_usd|less($b.cost_usd|num(100000))) end),
      is_error:$r.is_error,
      models:($now.models | with_entries(.key as $k | .value |= with_entries(.key as $f |
        .value |= less($b.models|obj|.[$k]|obj|.[$f]|num(1e12)))))},
     $now]' "$buffer")
  dir="$STATE_DIR/spend/$profile"
  private_dir "$dir"
  prune_spend
  json=$(printf '%s' "$entry" | jq -c '.[0]')
  # noclobber opens with O_EXCL: a record is never overwritten, on any filesystem.
  while :; do
    final="$dir/$session-$epoch-$RANDOM$RANDOM.json"
    if ( set -C; printf '%s\n' "$json" > "$final" ) 2>/dev/null; then break; fi
    tries=$((tries+1)); [ "$tries" -lt 5 ] || die 'Could not allocate a ledger file name.'
  done
  chmod 600 "$final"
  if [ -f "$record" ]; then
    jq -c --argjson t "$(printf '%s' "$entry" | jq -c '.[1]')" 'select(type=="object") | .totals=$t' "$record" | atomic_json "$record"
  fi
}

# Only numeric windows and the reset time leave the buffer, never text.
usage_data() {
  jq -sc --arg p "$1" --arg s "$2" "$RUN_JQ"'
    usage_event | if .==null then {capture:null,until:null} else
      .rate_limit_info as $i |
      (reduce ("five_hour","seven_day") as $k ({}; $i.unifiedWindows[$k] as $w |
        if ($w|type)=="object" and ($w.utilization|finite) and ($w.resetsAt|finite) and $w.resetsAt>=0 then
          .[$k]={used_percentage:($w.utilization*100 | if .<0 then 0 elif .>100 then 100 else . end | .*100 | round/100),
                 resets_at:$w.resetsAt}
        else . end)) as $rl |
      {capture:(if $rl=={} then null
                else {profile:$p,captured_at:now,session_id:$s,model:null,source:"relay",rate_limits:$rl} end),
       until:(if $i.status=="rejected" and ($i.resetsAt|finite) and $i.resetsAt>now then $i.resetsAt else null end)}
    end' "$3"
}

# Stored like a statusline capture, under the child profile and forward's session.
record_usage() {
  local data capture
  data=$(usage_data "$@")
  capture=$(printf '%s' "$data" | jq -c '.capture // empty')
  [ -n "$capture" ] || return 0
  CURRENT_PROFILE=$1
  store_capture "$capture" >/dev/null
}

record_rejection() {
  local data until
  data=$(usage_data "$@")
  until=$(printf '%s' "$data" | jq -r '.until // empty')
  [ -n "$until" ] || return 0
  mark_exhausted "$1" relay until "$until"
}

# Relay spend over the last 5 hours; old files are skipped before parsing.
# errors counts failed runs, which are often the cheapest (e.g. a lost login).
relay_spend() (
  local profile=$1 dir="$STATE_DIR/spend/$1" cutoff file files=() count=0 data
  local zero='{"cost_usd":0,"runs":0,"complete":true,"errors":0}'
  local filter='def finite: if type=="number" then (isinfinite|not) and (isnan|not) else false end;
    def ok: type=="object" and .profile==$p and (.at|finite) and .at>=now-$w and .at<=now+60
      and (.cost_usd==null or ((.cost_usd|finite) and .cost_usd>=0));'
  if [ -L "$STATE_DIR" ] || [ -L "$STATE_DIR/spend" ] || [ -L "$dir" ] || [ ! -d "$dir" ]; then
    printf '%s\n' "$zero"; return 0
  fi
  cutoff=$(mktemp "$STATE_DIR/.spend-window.XXXXXX") || { printf '%s\n' "$zero"; return 0; }
  trap 'rm -f "$cutoff"' EXIT
  touch -t "$(jq -nr --argjson w "$SPEND_WINDOW" 'now-$w-60 | strflocaltime("%Y%m%d%H%M.%S")')" "$cutoff" || { printf '%s\n' "$zero"; return 0; }
  while IFS= read -r -d '' file; do
    [ ! -L "$file" ] || continue
    files[$count]=$file; count=$((count+1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.json' -newer "$cutoff" -print0 2>/dev/null)
  if [ "$count" -eq 0 ]; then printf '%s\n' "$zero"; return 0; fi
  if ! data=$(jq -cn --arg p "$profile" --argjson w "$SPEND_WINDOW" "$filter"'[inputs|select(ok)]' "${files[@]}" 2>/dev/null); then
    # Slurp each fallback file so trailing garbage cannot count a valid prefix.
    data=$(for file in "${files[@]}"; do
      jq -cs --arg p "$profile" --argjson w "$SPEND_WINDOW" "$filter"'.[]|select(ok)' "$file" 2>/dev/null || true
    done | jq -cs .)
  fi
  printf '%s' "$data" | jq -c '{cost_usd:(map(.cost_usd // 0)|add // 0),runs:length,complete:all(.[]; .cost_usd!=null),errors:map(select(.is_error==true))|length}'
)
