#!/usr/bin/env bash
relay_help() {
  case "${1:-}" in
    detect) printf 'detect [--json]\nList candidate profile paths, suggested names, login metadata and pool membership.\n' ;;
    status) printf 'status [--json]\nAccount, quota, local reset times, data age and score; * marks the current profile.\n' ;;
    pick) printf 'pick [--exclude P]... [--json]\nSelect the lowest eligible score (no candidates: exit 3).\n' ;;
    exhausted) printf 'exhausted <profile> [--for DURATION | --until EPOCH] [--clear]\nMark an account as exhausted (score 100); duration: 90m, 4h or 3600s. --clear removes the mark.\n' ;;
    run) printf 'run [--profile P | --pick] [--exclude P]... -- <claude args>\nLaunch claude without inherited authentication variables. With no selector, use the current profile.\n' ;;
    forward) printf 'forward --task-file PATH [--write]\nForward a private task file to another profile; deletes the file afterwards. --write enables approved edits.\n' ;;
    handoff) printf 'handoff [--from P] [--to P|auto] [--session ID | --transcript PATH] [--cwd DIR] [--quiet] [--json]\nCopy the session and subagents; default to the most recent session for the cwd.\n' ;;
    resume) printf 'resume [--last | --session ID] [--to P|auto]\nCopy if needed and resume in the original cwd. With no selector, use --last.\n' ;;
    statusline) printf 'statusline\nRead JSON from stdin, save rate_limits and display quota usage; never fails.\n' ;;
    hook) printf 'hook guard | hook stop-failure\nInternal hooks: receive JSON on stdin and never fail.\n' ;;
    install) printf 'install [--profiles a,b,c | --profile name=dir]... [--settings PATH]... [--with-agent] [--warn-at N] [--handoff-at N] [--dry-run]\nInstall with backups. Without profiles, reuse the pool or detect a single login.\n' ;;
    uninstall) printf 'uninstall [--settings PATH]... [--purge]\nRemove relay commands and restore the statusline. --purge deletes config, usage data and handoffs.\n' ;;
    doctor) printf 'doctor\nCheck dependencies, the pool, hooks and measurement timestamps.\n' ;;
    '') printf 'claude-relay — Claude Code profiles, quota usage and handoffs\n\nSubcommands: detect, status, pick, exhausted, run, forward, handoff, resume, statusline, hook, install, uninstall, doctor\nUse help <subcommand> to see options. --version prints the version.\n' ;;
    *) die "Unknown subcommand: $1" ;;
  esac
}
