#!/usr/bin/env bash
# Sourced by run.sh: v0.2.2 child models, continued sessions, agent backups
# and the doctor CLAUDE.md note. Every path and process stays in the sandbox.
write_pool
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
unset CLAUDE_RELAY_DEPTH CLAUDE_RELAY_MAX_DEPTH CLAUDE_RELAY_CHILD_MODEL
export CLAUDE_CONFIG_DIR="$CLAUDE_PROFILES_ROOT/a"
rm -rf "$STATE/forwarded" "$STATE/exhausted"
usage a 98; usage b 10; usage c 20
WORK22="$SANDBOX/project space"
WORK22_RESOLVED=$(cd "$WORK22" && pwd -P)
UUID22='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
SID22=
# Write a fresh task (mode 644) and forward it from a directory; sets rc.
forward22() {
  local dir=$1
  shift
  TASK22=$(relay task-path)
  printf 'task twenty-two\n' > "$TASK22"
  chmod 644 "$TASK22"
  rc=0; (cd "$dir" && relay forward --task-file "$TASK22" "$@") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
}
log22() { jq -e --arg re "$UUID22" --arg sid "$SID22" "$1" "$FAKE_LOG" > /dev/null; }
record22() { jq -e --arg sid "$SID22" --arg cwd "$WORK22_RESOLVED" "$1" "$STATE/forwarded/$SID22.json" > /dev/null; }
# A refusal keeps the task byte for byte with its mode and launches nothing.
refused22() {
  [ "$rc" -ne 0 ] && [ -f "$TASK22" ] && [ "$(cat "$TASK22")" = 'task twenty-two' ] &&
    [ "$(LC_ALL=C ls -l "$TASK22" | cut -c1-10)" = '-rw-r--r--' ] && cmp -s "$FAKE_LOG" "$SANDBOX/launch22-before"
}
count22() { find "$1" -type f -name "$2" | wc -l | tr -d ' '; }

# 1: A new child gets a known random session ID and a private record.
forward22 "$WORK22"
check equals "$rc" 0
check log22 '.args[0:4]==["-p","--output-format","json","--session-id"] and (.args[4]|test($re)) and .args[5:]==["--permission-mode","plan"] and (.config|endswith("/b"))'
SID22=$(jq -r '.args[4]' "$FAKE_LOG")
check grep -qxF "claude-relay: profile b, session $SID22" "$SANDBOX/err"
check test ! -e "$TASK22"
check record22 '.session_id==$sid and .profile=="b" and .cwd==$cwd and (.created_at|type)=="number" and .last_used_at==.created_at and .created_at>now-60 and .created_at<=now'
check equals "$(jq -r 'keys|join(",")' "$STATE/forwarded/$SID22.json")" 'created_at,cwd,last_used_at,profile,session_id'
check equals "$(LC_ALL=C ls -l "$STATE/forwarded/$SID22.json" | cut -c1-10)" '-rw-------'
check equals "$(LC_ALL=C ls -ld "$STATE/forwarded" | cut -c1-10)" 'drwx------'
forward22 "$WORK22"
SID22B=$(jq -r '.args[4]' "$FAKE_LOG")
check test "$SID22B" != "$SID22"
check test -f "$STATE/forwarded/$SID22B.json"

# 2: --continue resumes in the recorded profile, even when pick prefers another.
jq '.created_at=(now-1000) | .last_used_at=(now-1000)' "$STATE/forwarded/$SID22.json" > "$SANDBOX/record22"
mv "$SANDBOX/record22" "$STATE/forwarded/$SID22.json"
usage b 50; usage c 5
forward22 "$WORK22" --continue "$SID22"
check equals "$rc" 0
check log22 '.args==["-p","--output-format","json","--resume",$sid,"--permission-mode","plan"] and (.config|endswith("/b")) and .depth=="1"'
check grep -qxF "claude-relay: profile b, session $SID22" "$SANDBOX/err"
check test ! -e "$TASK22"
check record22 '.last_used_at>now-60 and .created_at<now-900 and .profile=="b" and .cwd==$cwd'
forward22 "$WORK22" --model sonnet --continue "$SID22" --write
check equals "$rc" 0
check log22 '.args==["-p","--output-format","json","--resume",$sid,"--model","sonnet","--permission-mode","acceptEdits"]'
check equals "$(count22 "$STATE/forwarded" '*.json')" 2

# 3: Unknown, malformed or traversal IDs and another cwd are refused untouched.
cp "$FAKE_LOG" "$SANDBOX/launch22-before"
forward22 "$WORK22" --continue 00000000-0000-4000-8000-000000000000
check refused22
check grep -q 'Unknown forwarded session' "$SANDBOX/err"
for bad in ../../outside ABCDEF00-0000-4000-8000-000000000000 "$SID22/../$SID22" "$SID22.json" "x$SID22"; do
  forward22 "$WORK22" --continue "$bad"
  check refused22
done
forward22 "$SANDBOX" --continue "$SID22"
check refused22
check grep -q 'another directory' "$SANDBOX/err"
rm -f "$STATE/tasks/"task-*.txt

# 4: Model precedence is flag > environment > config, and every source is validated.
usage b 10; usage c 20
forward22 "$WORK22"
check log22 'any(.args[]; .=="--model") | not'
printf 'child_model=\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
forward22 "$WORK22"
check log22 'any(.args[]; .=="--model") | not'
printf 'child_model=haiku\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
forward22 "$WORK22"
check log22 '.args[3]=="--session-id" and .args[5:7]==["--model","haiku"] and .args[-1]=="plan"'
export CLAUDE_RELAY_CHILD_MODEL=sonnet
forward22 "$WORK22"
check log22 '.args[5:7]==["--model","sonnet"]'
forward22 "$WORK22" --model 'claude-opus-5-5[1m]'
check log22 '.args[5:7]==["--model","claude-opus-5-5[1m]"]'
forward22 "$WORK22" --model us.anthropic.claude_x:1
check log22 '.args[5:7]==["--model","us.anthropic.claude_x:1"]'
cp "$FAKE_LOG" "$SANDBOX/launch22-before"
for bad in 'bad model' -p '$(touch INJECTED22)' 'a;b' .dot x/y "$(printf 'a\nb')"; do
  forward22 "$SANDBOX" --model "$bad"
  check refused22
done
check test ! -e "$SANDBOX/INJECTED22"
export CLAUDE_RELAY_CHILD_MODEL='bad model'
forward22 "$WORK22" --model opus
check refused22
check grep -q 'CLAUDE_RELAY_CHILD_MODEL' "$SANDBOX/err"
unset CLAUDE_RELAY_CHILD_MODEL
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\nchild_model=bad;model\n' > "$XDG_CONFIG_HOME/claude-relay/config"
forward22 "$WORK22" --model opus
check refused22
check grep -q 'child_model' "$SANDBOX/err"
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
rm -f "$STATE/tasks/"task-*.txt

# 5: Records unused for 30 days are pruned during forward; recent use keeps them.
OLD22=11111111-1111-4111-8111-111111111111 KEEP22=22222222-2222-4222-8222-222222222222
jq -n --arg s "$OLD22" --arg cwd "$WORK22_RESOLVED" '{session_id:$s,profile:"b",cwd:$cwd,created_at:(now-3000000),last_used_at:(now-2592100)}' > "$STATE/forwarded/$OLD22.json"
jq -n --arg s "$KEEP22" --arg cwd "$WORK22_RESOLVED" '{session_id:$s,profile:"b",cwd:$cwd,created_at:(now-3000000),last_used_at:(now-100)}' > "$STATE/forwarded/$KEEP22.json"
forward22 "$WORK22"
check equals "$rc" 0
check test ! -e "$STATE/forwarded/$OLD22.json"
check test -f "$STATE/forwarded/$KEEP22.json"
cp "$FAKE_LOG" "$SANDBOX/launch22-before"
forward22 "$WORK22" --continue "$OLD22"
check refused22
rm -f "$STATE/tasks/"task-*.txt

# 6: Agent backups live in private state; legacy ones migrate out of agents/.
AGENTS22="$HOME/.claude/agents"
SETTINGS22="$SANDBOX/settings22.json"
relay uninstall > "$SANDBOX/out"
rm -rf "$STATE/backups"
mkdir -p "$AGENTS22"
printf 'legacy backup\n' > "$AGENTS22/relay.md.relay-backup-20260101-000000.abc123"
chmod 644 "$AGENTS22/relay.md.relay-backup-20260101-000000.abc123"
printf 'not a relay backup\n' > "$AGENTS22/other.md.relay-backup-1"
printf 'link target\n' > "$SANDBOX/notes22.txt"
ln -s "$SANDBOX/notes22.txt" "$AGENTS22/relay.md.relay-backup-link"
printf 'child_model=haiku\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
relay install --profiles a,b,c --settings "$SETTINGS22" --with-agent --dry-run > "$SANDBOX/out" 2> "$SANDBOX/err"
check test -f "$AGENTS22/relay.md.relay-backup-20260101-000000.abc123"
check test ! -e "$STATE/backups"
relay install --profiles a,b,c --settings "$SETTINGS22" --with-agent > "$SANDBOX/out" 2> "$SANDBOX/err"
check grep -qx 'child_model=haiku' "$XDG_CONFIG_HOME/claude-relay/config"
check test ! -e "$AGENTS22/relay.md.relay-backup-20260101-000000.abc123"
check equals "$(cat "$STATE/backups/relay.md.relay-backup-20260101-000000.abc123" 2>/dev/null)" 'legacy backup'
check equals "$(LC_ALL=C ls -l "$STATE/backups/relay.md.relay-backup-20260101-000000.abc123" | cut -c1-10)" '-rw-------'
check equals "$(LC_ALL=C ls -ld "$STATE/backups" | cut -c1-10)" 'drwx------'
check test -L "$AGENTS22/relay.md.relay-backup-link"
check equals "$(cat "$SANDBOX/notes22.txt")" 'link target'
check equals "$(cat "$AGENTS22/other.md.relay-backup-1")" 'not a relay backup'
check equals "$(count22 "$AGENTS22" 'relay.md.relay-backup-*')" 0
check equals "$(count22 "$STATE/backups" 'relay.md.relay-backup-*')" 1
# Replacing the agent backs it up into state, never beside it.
relay install --profiles a,b,c --settings "$SETTINGS22" --with-agent > "$SANDBOX/out" 2> "$SANDBOX/err"
check equals "$(count22 "$AGENTS22" 'relay.md.relay-backup-*')" 0
check equals "$(count22 "$STATE/backups" 'relay.md.relay-backup-*')" 2
backup22=false
for file in "$STATE/backups/"relay.md.relay-backup-*; do
  if cmp -s "$file" "$ROOT/agents/relay.md" && [ "$(LC_ALL=C ls -l "$file" | cut -c1-10)" = '-rw-------' ]; then backup22=true; fi
done
check "$backup22"
relay uninstall > "$SANDBOX/out"
check test ! -e "$AGENTS22/relay.md"
check equals "$(count22 "$AGENTS22" 'relay.md.relay-backup-*')" 0
check equals "$(count22 "$STATE/backups" 'relay.md.relay-backup-*')" 3
rm -f "$AGENTS22/relay.md.relay-backup-link" "$AGENTS22/other.md.relay-backup-1"
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"

# 7: doctor notes differing CLAUDE.md instructions once, without failing.
notes22() { grep -c 'read different CLAUDE.md' "$SANDBOX/doctor22" || true; }
rm -f "$CLAUDE_PROFILES_ROOT/a/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/c/CLAUDE.md"
rc_same=0; relay doctor > "$SANDBOX/doctor22" 2> "$SANDBOX/err" || rc_same=$?
check equals "$(notes22)" 0
for profile in a b c; do printf 'same\n' > "$CLAUDE_PROFILES_ROOT/$profile/CLAUDE.md"; done
relay doctor > "$SANDBOX/doctor22" 2> "$SANDBOX/err" || true
check equals "$(notes22)" 0
printf 'shared\n' > "$SANDBOX/instructions22.md"
rm -f "$CLAUDE_PROFILES_ROOT/a/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/c/CLAUDE.md"
ln -s "$SANDBOX/instructions22.md" "$CLAUDE_PROFILES_ROOT/a/CLAUDE.md"
ln -s "$SANDBOX/instructions22.md" "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md"
# A relative link to the same file has the same identity.
ln -s ../../instructions22.md "$CLAUDE_PROFILES_ROOT/c/CLAUDE.md"
relay doctor > "$SANDBOX/doctor22" 2> "$SANDBOX/err" || true
check equals "$(notes22)" 0
rm "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/c/CLAUDE.md"
printf 'b only\n' > "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md"
read -r sum22 _ < <(cksum < "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md")
rc_diff=0; relay doctor > "$SANDBOX/doctor22" 2> "$SANDBOX/err" || rc_diff=$?
check equals "$(notes22)" 1
check grep -qxF "Note: pool profiles read different CLAUDE.md instructions: a=$(cd "$SANDBOX" && pwd -P)/instructions22.md, b=cksum $sum22, c=none" "$SANDBOX/doctor22"
check equals "$rc_diff" "$rc_same"
rm -f "$CLAUDE_PROFILES_ROOT/a/CLAUDE.md" "$CLAUDE_PROFILES_ROOT/b/CLAUDE.md"

# 8: Help and the forwarder template describe the new options.
relay help forward > "$SANDBOX/help22"
check grep -q -- '--continue SESSION_ID' "$SANDBOX/help22"
check grep -q -- '--model ALIAS' "$SANDBOX/help22"
check grep -q -- '--model <alias>' "$ROOT/agents/relay.md"
check grep -q -- '--continue X' "$ROOT/agents/relay.md"
check grep -q 'session S' "$ROOT/agents/relay.md"
usage a 98; usage b 10; usage c 20

# Child tool allowlist: config, environment override, empty environment disables,
# control characters refused before anything launches.
unset CLAUDE_RELAY_CHILD_MODEL CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
forward22 "$WORK22"
check log22 'any(.args[]; .=="--allowedTools") | not'
printf 'child_allowed_tools=Bash(bash tests/run.sh) Bash(git diff:*)\n' >> "$XDG_CONFIG_HOME/claude-relay/config"
forward22 "$WORK22"
check log22 '.args[-4:]==["--allowedTools","Bash(bash tests/run.sh) Bash(git diff:*)","--permission-mode","plan"]'
forward22 "$WORK22" --write
check log22 '.args[-4:]==["--allowedTools","Bash(bash tests/run.sh) Bash(git diff:*)","--permission-mode","acceptEdits"]'
export CLAUDE_RELAY_CHILD_ALLOWED_TOOLS='Read'
forward22 "$WORK22"
check log22 '.args[-4:]==["--allowedTools","Read","--permission-mode","plan"]'
export CLAUDE_RELAY_CHILD_ALLOWED_TOOLS=''
forward22 "$WORK22"
check log22 'any(.args[]; .=="--allowedTools") | not'
CLAUDE_RELAY_CHILD_ALLOWED_TOOLS=$(printf 'Read\nBash')
export CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
cp "$FAKE_LOG" "$SANDBOX/launch22-before"
forward22 "$WORK22"
check refused22
check grep -q 'child_allowed_tools' "$SANDBOX/err"
unset CLAUDE_RELAY_CHILD_ALLOWED_TOOLS
printf 'warn_at=90\nhandoff_at=97\nunknown_score=50\n' > "$XDG_CONFIG_HOME/claude-relay/config"
