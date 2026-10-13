#!/usr/bin/env bash
# Sourced by run.sh; every fixture and launched process uses its sandbox.
write_pool
usage a 98; usage b 10; usage c 20
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"

# 1: Refusals never delete or alter the supplied file, including ordinary notes.
printf 'private notes\n' > "$SANDBOX/notes.txt"
chmod 644 "$SANDBOX/notes.txt"
cp "$FAKE_LOG" "$SANDBOX/launch7-before"
rc=0; relay forward --task-file "$SANDBOX/notes.txt" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check test -f "$SANDBOX/notes.txt"
check equals "$(cat "$SANDBOX/notes.txt" 2>/dev/null)" 'private notes'
check cmp -s "$FAKE_LOG" "$SANDBOX/launch7-before"
# Even an otherwise valid private file outside tasks is never accepted.
chmod 600 "$SANDBOX/notes.txt"
rc=0; relay forward --task-file "$SANDBOX/notes.txt" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
check test "$rc" -ne 0
check equals "$(cat "$SANDBOX/notes.txt")" 'private notes'
check cmp -s "$FAKE_LOG" "$SANDBOX/launch7-before"
chmod 644 "$SANDBOX/notes.txt"

# 2: A path is fresh and absent; Write may create 644 within the private dir.
rc=0; TASK7=$(relay task-path 2> "$SANDBOX/err") || rc=$?
check equals "$rc" 0
check test -n "$TASK7"
if [ "$rc" -eq 0 ]; then
  check test ! -e "$TASK7"
  check equals "${TASK7%/*}" "$STATE/tasks"
  check equals "$(LC_ALL=C ls -ld "$STATE/tasks" | cut -c1-10)" 'drwx------'
  check test "$TASK7" != "$(relay task-path)"
  printf 'literal task\n' > "$TASK7"
  chmod 644 "$TASK7"
  cp "$CLAUDE_RELAY_CLAUDE_BIN" "$SANDBOX/fake7-original"
  printf '\nLC_ALL=C ls -l "$TASK7" | cut -c1-10 > "$TASK7_MODE"\ncat > "$TASK7_STDIN"\nexit 7\n' >> "$CLAUDE_RELAY_CLAUDE_BIN"
  export TASK7 TASK7_MODE="$SANDBOX/task7-mode" TASK7_STDIN="$SANDBOX/task7-stdin"
  rc=0; relay forward --task-file "$TASK7" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check equals "$rc" 7
  check equals "$(cat "$TASK7_MODE")" '-rw-------'
  check equals "$(cat "$TASK7_STDIN")" 'literal task'
  check test ! -e "$TASK7"
  cp "$SANDBOX/fake7-original" "$CLAUDE_RELAY_CLAUDE_BIN"
  export REAL_CHMOD7=$(command -v chmod)
  for rejection in depth max_depth outside_profile config pool unavailable symlink directory mode; do
    TASK7=$(relay task-path)
    printf 'keep me\n' > "$TASK7"
    chmod 644 "$TASK7"
    case "$rejection" in
      depth) export CLAUDE_RELAY_DEPTH=0 ;;
      max_depth) export CLAUDE_RELAY_MAX_DEPTH=0 ;;
      outside_profile) export CLAUDE_CONFIG_DIR="$SANDBOX/nonpool" ;;
      mode)
        cat > "$SANDBOX/fake/chmod" <<'CHMOD7'
#!/usr/bin/env bash
if [ "${1:-}" = 600 ] && [ "${2:-}" = "$TASK7" ]; then exit 1; fi
exec "$REAL_CHMOD7" "$@"
CHMOD7
        "$REAL_CHMOD7" +x "$SANDBOX/fake/chmod" ;;
      config) printf 'handoff_at=bad\n' > "$XDG_CONFIG_HOME/claude-relay/config" ;;
      pool) mv "$XDG_CONFIG_HOME/claude-relay/pool" "$SANDBOX/pool7" ;;
      unavailable) usage b 100; usage c 100 ;;
      symlink) rm "$TASK7"; ln -s "$SANDBOX/notes.txt" "$TASK7" ;;
      directory) rm "$TASK7"; mkdir "$TASK7" ;;
    esac
    rc=0; relay forward --task-file "$TASK7" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
    check test "$rc" -ne 0
    check test -e "$TASK7"
    if [ "$rejection" != symlink ] && [ "$rejection" != directory ]; then
      check equals "$(cat "$TASK7")" 'keep me'
      check equals "$(LC_ALL=C ls -l "$TASK7" | cut -c1-10)" '-rw-r--r--'
    fi
    rm -f "$SANDBOX/fake/chmod"
    rm -rf "$TASK7"
    unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH
    export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
    printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
    if [ "$rejection" = pool ]; then mv "$SANDBOX/pool7" "$XDG_CONFIG_HOME/claude-relay/pool"; fi
    usage b 10; usage c 20
  done
  # Neither a tasks symlink nor a symlinked child directory can redirect access.
  mv "$STATE/tasks" "$STATE/tasks7-kept"
  ln -s "$SANDBOX" "$STATE/tasks"
  rc=0; relay task-path > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
  check test ! -s "$SANDBOX/out"
  rc=0; relay forward --task-file "$STATE/tasks/notes.txt" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
  check equals "$(cat "$SANDBOX/notes.txt")" 'private notes'
  rm "$STATE/tasks"; mv "$STATE/tasks7-kept" "$STATE/tasks"
  ln -s "$SANDBOX" "$STATE/tasks/escape"
  rc=0; relay forward --task-file "$STATE/tasks/escape/notes.txt" > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check test "$rc" -ne 0
  check equals "$(cat "$SANDBOX/notes.txt")" 'private notes'
  rm "$STATE/tasks/escape"
  # Old task files are pruned; fresh tasks and symlink targets survive.
  printf old > "$STATE/tasks/task-old.txt"
  printf fresh > "$STATE/tasks/task-fresh.txt"
  touch -t "$(jq -nr 'now-86460 | strflocaltime("%Y%m%d%H%M.%S")')" "$STATE/tasks/task-old.txt"
  ln -s "$SANDBOX/notes.txt" "$STATE/tasks/task-link.txt"
  relay task-path > "$SANDBOX/out"
  check test ! -e "$STATE/tasks/task-old.txt"
  check test -f "$STATE/tasks/task-fresh.txt"
  check test -L "$STATE/tasks/task-link.txt"
fi
check grep -q 'claude-relay task-path' "$ROOT/agents/relay.md"
check test "$(grep -Ec 'chmod|TMPDIR|/tmp' "$ROOT/agents/relay.md" || true)" -eq 0

# 3: A linked projects root works; absent transcripts still warn without paths.
rm -rf "$STATE/warned"
mv "$CLAUDE_PROFILES_ROOT/a/projects" "$SANDBOX/projects7"
ln -s "$SANDBOX/projects7" "$CLAUDE_PROFILES_ROOT/a/projects"
guard_input | relay hook guard > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("Write the handoff NOW")'
check test ! -s "$SANDBOX/err"
rm -rf "$STATE/warned"
guard_input | jq --arg t "$SANDBOX/projects7/$PROJECT/session-one.jsonl" '.transcript_path=$t' | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("Write the handoff NOW")'
rm -rf "$STATE/warned"
mv "$SOURCE" "$SANDBOX/transcript7-kept"
cp "$STATE/last-handoff.json" "$SANDBOX/last7-before"
guard_input | relay hook guard > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("98") and contains("Stop starting new work") and (contains("/")|not) and (contains("resume --last")|not)'
check cmp -s "$STATE/last-handoff.json" "$SANDBOX/last7-before"
check test ! -s "$SANDBOX/err"
# The later arrival of the transcript must allow the full handoff instruction.
mv "$SANDBOX/transcript7-kept" "$SOURCE"
guard_input | relay hook guard > "$SANDBOX/out"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("Write the handoff NOW")'
rm "$CLAUDE_PROFILES_ROOT/a/projects"
mv "$SANDBOX/projects7" "$CLAUDE_PROFILES_ROOT/a/projects"
# Resolve a profile alias even before its projects tree has been created.
rm -rf "$STATE/warned"
mv "$CLAUDE_PROFILES_ROOT/a/projects" "$SANDBOX/projects7"
ln -s "$CLAUDE_PROFILES_ROOT/a" "$SANDBOX/profile7-alias"
guard_input | jq --arg t "$SANDBOX/profile7-alias/projects/new-project/session-one.jsonl" '.transcript_path=$t' | CLAUDE_CONFIG_DIR="$SANDBOX/profile7-alias" relay hook guard > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$SANDBOX/out" '.hookSpecificOutput.additionalContext | contains("98") and contains("Stop starting new work") and (contains("/")|not)'
check test ! -s "$SANDBOX/err"
rm "$SANDBOX/profile7-alias"
mv "$SANDBOX/projects7" "$CLAUDE_PROFILES_ROOT/a/projects"

# 4: Moving a legacy hook must not disclose sibling commands in the diff.
printf '%s\n' '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"/old/claude-relay hook guard"},{"type":"command","command":"sibling-tool --key SIBLING_SECRET"},{"type":"command","command":"TOKEN=ASSIGNMENT_SECRET tool"}]}]}}' > "$SANDBOX/settings7.json"
cp "$SANDBOX/settings7.json" "$SANDBOX/settings7-before"
relay install --profiles a,b --settings "$SANDBOX/settings7.json" --dry-run > "$SANDBOX/preview7"
check test "$(grep -Ec 'SIBLING_SECRET|ASSIGNMENT_SECRET' "$SANDBOX/preview7" || true)" -eq 0
check grep -q 'chars, preserved' "$SANDBOX/preview7"
check cmp -s "$SANDBOX/settings7.json" "$SANDBOX/settings7-before"
(RELAY_ROOT=$ROOT; source "$ROOT/lib/install.sh"; preview_settings < "$SANDBOX/settings7.json") > "$SANDBOX/redacted7"
check test "$(grep -Ec 'SIBLING_SECRET|ASSIGNMENT_SECRET' "$SANDBOX/redacted7" || true)" -eq 0
check json_is "$SANDBOX/redacted7" '.hooks.PostToolUse[0].hooks[0].command=="/old/claude-relay hook guard"'

# 5: A recent stamp skips scans/deletions; an expired stamp permits them.
mkdir -p "$STATE/warned"
printf old > "$STATE/warned/throttle7"
touch -t 200001010000 "$STATE/warned/throttle7"
jq -n '{at:now}' > "$STATE/prune.json"
cp "$STATE/prune.json" "$SANDBOX/prune7-before"
capture_input throttle7 model-a 20 | relay statusline > "$SANDBOX/out"
check test -f "$STATE/warned/throttle7"
check cmp -s "$STATE/prune.json" "$SANDBOX/prune7-before"
jq -n '{at:(now-601)}' > "$STATE/prune.json"
capture_input throttle7 model-a 21 | relay statusline > "$SANDBOX/out"
check test ! -e "$STATE/warned/throttle7"
check json_is "$STATE/prune.json" '.at > now-60'
# Malformed stamps must recover instead of permanently disabling pruning.
printf old > "$STATE/warned/throttle7"
touch -t 200001010000 "$STATE/warned/throttle7"
printf 'broken' > "$STATE/prune.json"
capture_input throttle7 model-a 22 | relay statusline > "$SANDBOX/out"
check test ! -e "$STATE/warned/throttle7"
check json_is "$STATE/prune.json" '.at > now-60'

# 6 and 8: Pasted install commands and release verification stay explicit.
check test "$(grep -c '^set -e' "$ROOT/README.md" || true)" -eq 0
check grep -Eq '^git clone .* && cd .* && git checkout v'"$(cat "$ROOT/VERSION")"' && ./install.sh --dry-run$' "$ROOT/README.md"
for doc in SECURITY.md AGENTS.md; do
  check grep -q "git verify-tag v$(cat "$ROOT/VERSION")" "$ROOT/$doc"
  check grep -q 'GitHub release notes' "$ROOT/$doc"
  check grep -Eq 'commit SHA|commit.*SHA' "$ROOT/$doc"
  check grep -q 'never.*main' "$ROOT/$doc"
done
check equals "$(head -1 "$ROOT/docs/SPEC.md")" "# claude-relay — specification v$(cat "$ROOT/VERSION")"

# 7: Interactive launches clear inherited depth; print launches increment it.
for depth in unset 0 99 invalid; do
  if [ "$depth" = unset ]; then unset CLAUDE_RELAY_DEPTH; else export CLAUDE_RELAY_DEPTH=$depth; fi
  rc=0; CLAUDE_RELAY_MAX_DEPTH=0 relay run --profile a -- < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
  check equals "$rc" 0
  check json_is "$FAKE_LOG" '.depth=="unset" and .args==[]'
done
unset CLAUDE_RELAY_DEPTH
for print_flag in -p --print; do
  CLAUDE_RELAY_MAX_DEPTH=2 CLAUDE_RELAY_DEPTH=1 relay run --profile a -- "$print_flag" < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err"
  check json_is "$FAKE_LOG" '.depth=="2"'
done
CLAUDE_RELAY_DEPTH=99 relay run --profile a -- -- -p < /dev/null > "$SANDBOX/out" 2> "$SANDBOX/err"
check json_is "$FAKE_LOG" '.depth=="unset" and .args==["--","-p"]'
