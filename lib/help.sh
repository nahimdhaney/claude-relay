#!/usr/bin/env bash
relay_help() {
  case "${1:-}" in
    status) printf 'status [--json]\nCuenta, cuota, reinicios locales, antigüedad y puntaje; * indica el perfil actual.\n' ;;
    pick) printf 'pick [--exclude P]... [--json]\nElige el menor puntaje elegible (sin candidatos: exit 3).\n' ;;
    exhausted) printf 'exhausted <perfil> [--for DURATION | --until EPOCH] [--clear]\nMarca una cuenta agotada (puntaje 100); duración: 90m, 4h o 3600s. --clear borra la marca.\n' ;;
    run) printf 'run [--profile P | --pick] [--exclude P]... -- <args de claude>\nLanza claude sin las variables de autenticación heredadas. Sin opción usa el perfil actual.\n' ;;
    handoff) printf 'handoff [--from P] [--to P|auto] [--session ID | --transcript PATH] [--cwd DIR] [--quiet] [--json]\nCopia la sesión y subagentes; por defecto, la más reciente del cwd.\n' ;;
    resume) printf 'resume [--last | --session ID] [--to P|auto]\nCopia si hace falta y retoma en el cwd original. Sin selector usa --last.\n' ;;
    statusline) printf 'statusline\nLee JSON de stdin, guarda rate_limits y muestra cuota; nunca falla.\n' ;;
    hook) printf 'hook guard | hook stop-failure\nHooks internos: reciben JSON por stdin y nunca fallan.\n' ;;
    install) printf 'install [--profiles a,b,c | --profile nombre=dir]... [--settings PATH]... [--with-agent] [--warn-at N] [--handoff-at N] [--dry-run]\nInstala pool, statusline y hooks aditivos, con backups.\n' ;;
    uninstall) printf 'uninstall [--settings PATH]... [--purge]\nRetira comandos relay y restaura statusline. --purge borra config, uso y handoffs.\n' ;;
    doctor) printf 'doctor\nVerifica dependencias, pool, hooks y fecha de las mediciones.\n' ;;
    '') printf 'claude-relay 0.1.0 — perfiles, cuota y traspasos de Claude Code\n\nSubcomandos: status, pick, exhausted, run, handoff, resume, statusline, hook, install, uninstall, doctor\nUsa help <subcomando> para ver opciones. --version muestra la versión.\n' ;;
    *) die "Subcomando desconocido: $1" ;;
  esac
}
