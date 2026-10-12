#!/usr/bin/env bash
# Copy each regular file atomically, preserving a newer destination.
copy_private() (
  local src=$1 dst=$2 tmp
  [ ! -L "$src" ] && [ -f "$src" ] || die "Transcript is not a regular file: $src"
  [ ! -L "$dst" ] || die "Symlink destination rejected: $dst"
  if [ -f "$dst" ] && [ "$dst" -nt "$src" ]; then chmod 600 "$dst"; exit 0; fi
  new_private_dir "$(dirname "$dst")"
  tmp=$(mktemp "${dst}.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  if [ "$(uname -s)" = Darwin ]; then chmod -N "$tmp" 2>/dev/null || true; fi
  cat "$src" > "$tmp"
  touch -r "$src" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$dst"
)
copy_siblings() {
  local src=$1 dst=$2 path relative
  [ -d "$src" ] || return 0
  [ ! -L "$src" ] && [ ! -L "$dst" ] || die 'Symlink subagent directory rejected.'
  # Validate before copying anything; never follow symlinks or credential files.
  while IFS= read -r -d '' path; do
    case "${path##*/}" in .credentials.json|.claude.json) die 'Unexpected authentication file in transcripts.' ;; esac
    [ ! -L "$path" ] && { [ -d "$path" ] || [ -f "$path" ]; } || die "Not a regular file: $path"
  done < <(find "$src" -print0)
  while IFS= read -r -d '' path; do
    relative=${path#"$src"}
    if [ -d "$path" ]; then
      [ ! -L "$dst$relative" ] || die 'Symlink destination rejected.'
      new_private_dir "$dst$relative"
    else copy_private "$path" "$dst$relative"; fi
  done < <(find "$src" -print0)
}
# Reject symlinked destination ancestors rather than writing through them.
check_destination_dirs() {
  local path=$1 root=$2
  while [ "$path" != "$root" ] && [ "$path" != / ]; do
    [ ! -L "$path" ] || die "Symlink destination rejected: $path"
    path=$(dirname "$path")
  done
}
session_source() {
  local from_dir=$1 session=$2 transcript=$3 cwd=$4 allow_missing=${5:-false} candidate project newest='' projects parent missing
  SOURCE_MISSING=false
  projects=$(resolve_dir "$from_dir/projects" || true)
  if [ -z "$projects" ]; then
    $allow_missing && [ ! -e "$from_dir/projects" ] && [ ! -L "$from_dir/projects" ] || die 'Source projects directory does not exist.'
    projects="$from_dir/projects"
  fi
  if [ -n "$transcript" ]; then
    transcript=$(absolute_path "$transcript")
    [ ! -L "$transcript" ] || die 'Symlink transcript rejected.'
    case "$transcript" in "$from_dir/projects/"*) transcript="$projects/${transcript#"$from_dir/projects/"}" ;; esac
    parent=$(resolve_dir "${transcript%/*}" || true)
    if [ -z "$parent" ]; then
      $allow_missing || die 'Source project does not exist.'
      parent=${transcript%/*} missing=''
      # Resolve aliases in the nearest existing ancestor even when Claude
      # has not yet created the projects tree. Reject dangling links and ..
      # in the missing portion instead of treating them as trusted paths.
      while [ ! -d "$parent" ]; do
        [ ! -e "$parent" ] && [ ! -L "$parent" ] || die 'Invalid source project directory.'
        case "${parent##*/}" in ''|.|..) die 'Invalid source project directory.' ;; esac
        missing="/${parent##*/}$missing"
        parent=${parent%/*}; [ -n "$parent" ] || parent=/
      done
      parent="$(resolve_dir "$parent")$missing"
    fi
    transcript="$parent/${transcript##*/}"
    case "$transcript" in "$projects"/*/*.jsonl) ;; *) die 'The transcript does not belong to the source profile.' ;; esac
    project=${transcript#"$projects/"}
    project=${project%/*}
    case "$project" in ''|.|..|*/*) die 'The main transcript of a session is required.' ;; esac
    candidate=${transcript##*/}; candidate=${candidate%.jsonl}
    [ -z "$session" ] || [ "$candidate" = "$session" ] || die 'Session ID and transcript do not match.'
    session=$candidate
  else
    project=$(project_name "$cwd")
    if [ -n "$session" ]; then
      safe_name "$session" || die 'Invalid session ID.'
      transcript="$from_dir/projects/$project/$session.jsonl"
      if [ ! -f "$transcript" ]; then
        for candidate in "$from_dir"/projects/*/"$session.jsonl"; do
          [ -f "$candidate" ] || continue
          [ -z "$newest" ] || die 'Ambiguous session: use --transcript.'
          newest=$candidate
        done
        transcript=$newest
      fi
    else
      for candidate in "$from_dir/projects/$project"/*.jsonl; do
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then newest=$candidate; fi
      done
      transcript=$newest
    fi
    [ -n "$transcript" ] || die 'No session found for that cwd.'
    project=$(basename "$(dirname "$transcript")")
    session=${transcript##*/}; session=${session%.jsonl}
  fi
  safe_name "$session" || die 'Invalid session ID.'
  if $allow_missing && [ ! -e "$transcript" ] && [ ! -L "$transcript" ]; then
    SOURCE_MISSING=true
    SOURCE_TRANSCRIPT='' SESSION_ID=$session PROJECT=$project
    return 0
  fi
  [ -f "$transcript" ] && [ ! -L "$transcript" ] || die "Transcript does not exist: $transcript"
  # Ensure source project directories do not lead outside the selected config.
  parent=$(resolve_dir "$(dirname "$transcript")")
  [ "$parent" = "$(resolve_dir "$from_dir/projects/$project")" ] && [ "$parent" = "$projects/$project" ] || die 'Symlink project rejected.'
  SOURCE_TRANSCRIPT=$transcript SESSION_ID=$session PROJECT=$project
}
cmd_handoff() {
  local from='' to=auto session='' transcript='' cwd="$PWD" cwd_given=false quiet=false json=false from_dir to_dir dest md='' record inferred
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from|--to|--session|--transcript|--cwd)
        need_value "$@"
        case "$1" in --from) from=$2 ;; --to) to=$2 ;; --session) session=$2 ;; --transcript) transcript=$2 ;; --cwd) cwd=$2; cwd_given=true ;; esac
        shift 2 ;;
      --quiet) quiet=true; shift ;; --json) json=true; shift ;; *) die "Unknown option: $1" ;;
    esac
  done
  load_pool
  from=${from:-$CURRENT_PROFILE}
  [ -n "$from" ] || die 'Outside the pool: specify --from.'
  from_dir=$(profile_dir "$from")
  cwd=$(resolve_dir "$cwd") || die 'The cwd does not exist.'
  if [ "$to" = auto ]; then choose_profile "$from"; to=$PICKED; fi
  [ "$from" != "$to" ] || die 'Source and destination must differ.'
  to_dir=$(profile_dir "$to")
  [ -d "$to_dir" ] || die "Destination does not exist: $to_dir"
  session_source "$from_dir" "$session" "$transcript" "$cwd"
  if ! $cwd_given && { [ -n "$session" ] || [ -n "$transcript" ]; }; then
    inferred=$(jq -nr 'first(inputs | objects | .cwd | select(type=="string" and length>0)) // empty' "$SOURCE_TRANSCRIPT")
    if [ -n "$inferred" ]; then cwd=$(resolve_dir "$inferred") || die 'The original cwd no longer exists; specify --cwd.'; fi
  fi
  dest="$to_dir/projects/$PROJECT/$SESSION_ID.jsonl"
  check_destination_dirs "$(dirname "$dest")" "$to_dir"
  copy_private "$SOURCE_TRANSCRIPT" "$dest"
  copy_siblings "${SOURCE_TRANSCRIPT%.jsonl}" "${dest%.jsonl}"
  if [ -f "$STATE_DIR/sessions/$from-$SESSION_ID.json" ]; then
    md=$(jq -er '.handoff_md // ""' "$STATE_DIR/sessions/$from-$SESSION_ID.json")
  elif [ -f "$STATE_DIR/last-handoff.json" ]; then
    md=$(jq -r --arg s "$SESSION_ID" --arg f "$from" 'if .session_id==$s and .from==$f then .handoff_md // "" else "" end' "$STATE_DIR/last-handoff.json")
  fi
  record=$(jq -n --arg from "$from" --arg to "$to" --arg sid "$SESSION_ID" --arg cwd "$cwd" --arg transcript "$dest" --arg source "$SOURCE_TRANSCRIPT" --arg md "$md" '{from:$from,to:$to,session_id:$sid,cwd:$cwd,transcript:$transcript,source_transcript:$source,at:now} + if $md=="" then {} else {handoff_md:$md} end')
  printf '%s\n' "$record" | atomic_json "$STATE_DIR/last-handoff.json"
  if $json; then printf '%s\n' "$record"; elif ! $quiet; then
    printf 'Session copied from %s to %s.\nclaude-relay resume --last\n' "$from" "$to"
    printf 'cd %q && CLAUDE_CONFIG_DIR=%q claude --resume %q\n' "$cwd" "$to_dir" "$SESSION_ID"
    [ -z "$md" ] || printf 'Handoff: %s\n' "$md"
  fi
}
cmd_resume() {
  local last=false session='' to='' record from cwd source dest md
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --last) last=true; shift ;;
      --session|--to) need_value "$@"; if [ "$1" = --session ]; then session=$2; else to=$2; fi; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if $last && [ -n "$session" ]; then die '--last and --session are mutually exclusive.'; fi
  if [ -n "$session" ]; then
    cmd_handoff --session "$session" --to "${to:-auto}" --quiet
  else
    [ -f "$STATE_DIR/last-handoff.json" ] || die 'No handoff recorded.'
    record=$(cat "$STATE_DIR/last-handoff.json")
    from=$(printf '%s' "$record" | jq -er .from)
    session=$(printf '%s' "$record" | jq -er .session_id)
    cwd=$(printf '%s' "$record" | jq -er .cwd)
    dest=$(printf '%s' "$record" | jq -r '.to // "auto"')
    source=$(printf '%s' "$record" | jq -er '.source_transcript // .transcript')
    # Re-copy available source files: the conversation (or a subagent) may
    # have continued since the previous handoff. Newer destinations survive.
    if [ -f "$source" ] || [ -n "$to" ] || [ "$dest" = auto ] || [ ! -f "$(printf '%s' "$record" | jq -r .transcript)" ]; then
      cmd_handoff --from "$from" --to "${to:-$dest}" --session "$session" --transcript "$source" --cwd "$cwd" --quiet
    fi
  fi
  load_pool
  record=$(cat "$STATE_DIR/last-handoff.json")
  to=$(printf '%s' "$record" | jq -er .to)
  cwd=$(printf '%s' "$record" | jq -er .cwd)
  session=$(printf '%s' "$record" | jq -er .session_id)
  md=$(printf '%s' "$record" | jq -r '.handoff_md // ""')
  [ -z "$md" ] || printf 'Handoff: %s\n' "$md" >&2
  safe_name "$session" || die 'Invalid session ID.'
  cwd=$(resolve_dir "$cwd") || die 'The cwd does not exist.'
  cd "$cwd"
  unset CLAUDE_RELAY_DEPTH
  launch_claude "$to" interactive --resume "$session"
}
