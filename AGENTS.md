# Installing claude-relay (instructions for coding agents)

You are a coding agent (Claude Code, Codex, Cursor or similar) and the user asked
you to install claude-relay. Follow these steps in order. Stop and ask the user
whenever a step says so. Do not improvise around a failed step: report it.

## Rules

- Never read, print or copy credential files (`.credentials.json`, the macOS
  keychain, `~/.claude.json` contents beyond what `claude-relay status` shows).
- Never edit Claude Code `settings.json` files by hand. The installer merges its
  entries, keeps everything else, and writes a backup first.
- Install only the profiles the user names. Never add a work or employer account
  unless the user explicitly asks for it.
- The forwarding agent is opt-in: ask the user whether they want it. Add
  `--with-agent` only if they explicitly agree, including in the preview.
- Show the user the `--dry-run` output and get a yes before the real install.

## 1. Check requirements

```bash
command -v git jq claude
bash --version | head -1     # 3.2 or later
jq --version                 # 1.6 or later
```

If `jq` is missing, ask the user before installing it (`brew install jq` on
macOS, `sudo apt-get install jq` on Debian/Ubuntu).

## 2. Get the code

Clone into a stable location. The installed hooks run from this checkout, so it
should not be a folder the user edits day to day. Only the user should be
able to write to it. If the target already exists, stop and report it instead
of overwriting it.

```bash
git clone https://github.com/nahimdhaney/claude-relay.git ~/.local/share/claude-relay
cd ~/.local/share/claude-relay
git checkout v0.3.0
```

Pin a release tag or commit SHA, never `main`. Before installing or updating,
compare `git rev-parse HEAD` with the release commit SHA listed in the
GitHub release notes for that version. When tags are signed, run
`git verify-tag v0.3.0` and verify the signer against a trusted maintainer key.
A matching name alone does not authenticate a tag. Stop if the SHA differs or
an expected signature cannot be verified.

## 3. Find the user's Claude Code profiles

A profile is a Claude Code config directory with its own login. Look for:

```bash
./bin/claude-relay detect
```

The detector lists candidate paths, suggested names, login metadata and pool
membership; it does not sign in or inspect credentials. Show the user only candidate names and emails, once; do not repeat the detector
output elsewhere. **Ask which profiles to include** and what to call each one. Each included profile must already be logged in (the user runs
`claude` with that `CLAUDE_CONFIG_DIR` and signs in; never do the login flow
yourself).

## 4. Preview, then install

With profiles under `~/.claude-profiles/<name>`:

```bash
./install.sh --profiles personal,side --dry-run
```

With arbitrary directories:

```bash
./install.sh --profile "personal=$HOME/.claude" --profile "side=$HOME/.claude-side" --dry-run
```

Show the output to the user. It lists the pool, the config, and a diff of every
`settings.json` that will change. After the user agrees, run the same command
without `--dry-run`.

If the installer says `~/.local/bin` is not on `PATH`, tell the user which line
to add to their shell profile (`export PATH="$HOME/.local/bin:$PATH"`); do not
edit it unless they ask. Use `./bin/claude-relay` for verification if it is not
yet on PATH.

## 5. Verify

```bash
claude-relay doctor
claude-relay status
```

`doctor` must exit 0. `status` shows "no data" for every profile until each one
has had at least one reply in an interactive session; that is expected.

## 6. Tell the user

- Restart open Claude Code sessions, or they keep the old settings until they
  reload them.
- Quota percentages come from interactive sessions only. Relay records
  forwarded runs' cost to break ties between profiles with equal scores.
- Daily use: `claude-relay status`, `claude-relay pick`, and
  `claude-relay resume --last` after a handoff.
- To remove it: `claude-relay uninstall` (add `--purge` to delete its state).

Use this tool for continuity across accounts you legitimately hold. Anthropic's
[legal and compliance documentation](https://code.claude.com/docs/en/legal-and-compliance)
says advertised plan limits assume “ordinary, individual usage”. You must comply
with Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
and [Usage Policy](https://www.anthropic.com/legal/aup), and any other terms
applicable to your accounts. Not affiliated with Anthropic.
