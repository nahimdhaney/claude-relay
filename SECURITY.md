# Security

claude-relay is a local continuity and handoff tool for your own Claude Code
accounts. It makes no network requests. Each profile must already be logged in
separately; relay never reads, copies or changes credentials, the keychain or
`.credentials.json`.

## Data access

- Reads hook and statusline JSON on stdin, quota captures, pool/configuration,
  installation receipts, Claude Code settings and session transcripts.
- Projects only `oauthAccount.emailAddress` and `oauthAccount.organizationName`
  from each profile's `.claude.json` for account discovery and status. It never
  outputs or copies the rest of that file.
- Writes usage captures, exhaustion and warning markers, handoff notes and
  transfer records under the relay state directory. `events.log` contains only
  allowlisted error fields, sanitized and truncated; error messages can still
  contain private information.
- Copies the selected conversation and its sibling subagent transcripts between
  profiles. These can contain sensitive project content. It does not copy
  credentials, settings, source trees, branches or worktrees.
- Installs additive hooks and a statusline wrapper, an executable symlink and
  optionally `~/.claude/agents/relay.md`. Settings, configuration, receipts and
  replaced agent files are backed up. JSON is validated before atomic replacement.
- Relay state/configuration directories are private (700); written files and
  backups are 600. Existing settings retain their original mode. New transcript
  directories are 700; existing directory modes are retained and checked by
  doctor. Transcript copies preserve bytes and mtime without source modes or
  ACLs. Backups remain after uninstall; `--purge` removes relay state
  and configuration. Protect or delete retained settings/agent backups yourself.

## Threat model

Hooks execute on every prompt and after tools from the **checkout path**. Keep
that checkout, its parents, your profiles and relay state/configuration somewhere
only you can write. Pin a release tag and review updates before adopting them.
Anyone able to modify the checkout or your trusted settings can execute code
with your permissions. Relay is not a sandbox against another process running
as you, an administrator, or concurrent hostile filesystem replacement.

Hook/statusline input, transcripts and account metadata are data, never shell
code. Input must be a single JSON object. Profile/session names are validated,
transcript paths are checked against the selected profile, and symlinked write
locations are rejected. The optional forwarding agent sends the task through a
private temporary file created with Write and passed to the deterministic
`forward --task-file` command. It never places task text in shell code or
command arguments. The command validates ownership, mode 600 and regular-file
status, rejects symlinks and deletes the owned task file afterwards. Editing
requires explicit approval in the delegating prompt and `--write`; requests
inside task text cannot authorize edits. Recursive forwarding is bounded by
`max_depth` (default 1), and `forward` refuses any inherited depth. Interactive
`resume` unsets depth.

The previous statusline is **trusted local code**: its configured command runs
through Bash, receiving the original JSON only on stdin. Do not install an
untrusted statusline or change it to evaluate input. Shell quoting in generated
commands protects paths; it does not make arbitrary configured commands safe.
Hooks and statusline failures return zero with no output to preserve the session.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/nahimdhaney/claude-relay/security/advisories/new).
Include the affected version, a minimal reproduction with synthetic data and
the expected impact. Do not include credentials, real transcripts or personal
account details, and do not disclose security reports in public issues.
