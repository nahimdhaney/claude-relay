# claude-relay — especificación v0.1

Herramienta para usar varias cuentas de Claude Code (perfiles con distinto
`CLAUDE_CONFIG_DIR`) sin perder el trabajo cuando una se queda sin cuota:

1. **Medir** la cuota de plan de cada perfil (5 h y 7 días).
2. **Elegir** el perfil con más margen (`pick`) y lanzar Claude ahí (`run`).
3. **Avisar** al modelo cuando la cuota del perfil actual cruza un umbral, para
   que escriba un handoff antes de quedarse sin tokens.
4. **Traspasar** la sesión a otro perfil: copiar el transcript y retomarlo con
   `claude --resume` (verificado a mano en Claude Code 2.1.296), más el handoff.

Tiene que ser exportable: cualquier persona lo clona, corre `./install.sh` y
funciona, use o no `claude-profile`.

## Hechos de Claude Code en los que se apoya (docs oficiales)

- El JSON que recibe el comando de `statusLine` por stdin trae
  `rate_limits.five_hour.{used_percentage,resets_at}` y
  `rate_limits.seven_day.{used_percentage,resets_at}` (`used_percentage` 0–100,
  `resets_at` epoch en segundos). Solo para suscriptores de claude.ai, solo
  después de la primera respuesta de la sesión, y cada ventana puede faltar.
  En asientos Team no está confirmado: si falta, el perfil queda "sin dato".
  Ningún hook recibe `rate_limits`; por eso la statusline lo guarda en un
  archivo. Trae además `session_id`, `transcript_path`, `cwd`, `model`.
- La entrada de los hooks (JSON por stdin) trae `session_id`, `transcript_path`,
  `cwd`, `hook_event_name`. Los hooks heredan el entorno, así que
  `CLAUDE_CONFIG_DIR` dice qué perfil corre (si no está, es `~/.claude`).
- `UserPromptSubmit` y `PostToolUse` pueden inyectar contexto al modelo con
  `{"hookSpecificOutput":{"hookEventName":"<evento>","additionalContext":"..."}}`
  en stdout y exit 0.
- `StopFailure` corre cuando el turno termina por error de API; matcher
  `rate_limit`. Su salida se ignora: solo sirve para efectos laterales.
- Transcripts: `<config>/projects/<proyecto>/<session_id>.jsonl` (más un
  directorio hermano `<session_id>/` con transcripts de subagentes si existe).
  `<proyecto>` es el cwd con todo lo no alfanumérico reemplazado por `-`.
  Usar el nombre del directorio de origen tal cual, no recalcularlo.
  `claude --resume <id>` en el perfil destino, con cwd igual al original,
  retoma la conversación. El formato es interno y puede cambiar: documentarlo.
- Variables de auth que hay que quitar del entorno al lanzar otro perfil:
  `ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  ANTHROPIC_BASE_URL`.
- `claude -p` (headless) no expone la cuota del plan y no está claro que corra
  la statusline: el gasto de corridas `-p` puede no quedar medido. Documentarlo.

## Restricciones

- Bash compatible con **bash 3.2** (el de macOS): nada de arrays asociativos,
  `mapfile`, `${var,,}`, `declare -A`. `#!/usr/bin/env bash`, `set -euo pipefail`.
- Dependencias: `jq` (>= 1.6) y coreutils POSIX. Nada de flags solo GNU o solo
  BSD (`date -d`, `stat -c`, `sed -i` sin sufijo…); para fechas usar `jq now`.
  Debe correr en macOS y Linux.
- Hooks y statusline rápidos (objetivo < 100 ms): salir temprano si el perfil
  no está en el pool o no hay dato.
- Nunca leer, copiar ni imprimir credenciales (`.credentials.json`, keychain,
  `.claude.json` completo). Del `.claude.json` solo se lee
  `oauthAccount.emailAddress` y `oauthAccount.organizationName` para `status`.
- Archivos que contienen transcripts o handoffs: `umask 077`, modo 600/700.
- Escrituras atómicas (archivo temporal + `mv`).
- Ningún hook puede romper la sesión: ante cualquier error, exit 0 sin salida.
- Sin dependencias de red.

## Estructura del repo

```
bin/claude-relay          CLI único (subcomandos)
lib/                      funciones compartidas (sourced por bin/)
agents/relay.md           subagente envoltorio (opcional al instalar)
install.sh                atajo: bin/claude-relay install "$@"
tests/run.sh              suite en bash puro, sin dependencias extra
tests/fixtures/           JSON de ejemplo (statusline, hooks)
README.md                 en español: qué hace, instalar, usar, límites, términos
docs/SPEC.md              este archivo
```

## Configuración

- Pool: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/pool`, una línea por
  perfil `nombre<TAB>config_dir`, `#` comentarios. Orden = prioridad de desempate.
- Opciones: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/config` (`clave=valor`):
  `warn_at=90`, `handoff_at=97`, `unknown_score=50`, `wrapped_statusline=<cmd>`.
  Variables de entorno `CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` pisan.
- Estado: `${XDG_STATE_HOME:-~/.local/state}/claude-relay/`:
  `usage/<perfil>.json`, `handoffs/<proyecto>/<YYYYmmdd-HHMMSS>-<sid8>.md`,
  `last-handoff.json`, `warned/<perfil>-<sid>-<nivel>-<resets_at>`.
- Perfil actual = el nombre del pool cuyo `config_dir` coincide (ruta resuelta)
  con `${CLAUDE_CONFIG_DIR:-~/.claude}`. Si no coincide ninguno: no es del pool.

## Subcomandos

`claude-relay status [--json]`
: Tabla: perfil, cuenta (email · org), 5 h %, 7 d %, cuándo reinicia cada
  ventana (hora local), antigüedad del dato, puntaje, y marca `*` en el perfil
  actual. Una ventana cuyo `resets_at` ya pasó se muestra como 0 % ("reinició").

`claude-relay pick [--exclude P]... [--json]`
: Imprime el nombre del mejor perfil. Puntaje = máximo `used_percentage` de las
  ventanas vigentes (vencidas = 0); sin dato = `unknown_score`. Se descartan los
  perfiles con puntaje >= `handoff_at` y los perfiles cuyo config_dir no existe.
  Menor puntaje gana; empate → orden del pool. Sin candidatos → exit 3 y mensaje
  a stderr.

`claude-relay run [--profile P | --pick] [--exclude P]... -- <args de claude>`
: `exec` de `claude` con `CLAUDE_CONFIG_DIR` del perfil y sin las variables de
  auth. Binario configurable con `CLAUDE_RELAY_CLAUDE_BIN` (para tests).

`claude-relay handoff [--from P] [--to P|auto] [--session ID | --transcript PATH] [--cwd DIR] [--quiet] [--json]`
: Copia el transcript de la sesión al perfil destino (`auto` = `pick
  --exclude <origen>`). Sin `--session`/`--transcript`: la sesión más reciente
  (mtime) del proyecto del cwd en el perfil de origen (por defecto el actual).
  Copia también el directorio hermano `<sid>/` si existe. No pisa un archivo
  destino más nuevo que el origen. Registra `last-handoff.json` (`from`, `to`,
  `session_id`, `cwd`, `transcript`, `handoff_md` si hay uno para esa sesión,
  `at`). Imprime el comando para retomar:
  `claude-relay resume --last` y el equivalente crudo
  `cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <sid>`.

`claude-relay resume [--last | --session ID] [--to P|auto]`
: Hace el `handoff` (si hace falta) y luego `cd <cwd>` + `exec claude --resume
  <sid>` en el destino. Si hay handoff `.md` para la sesión, muestra su ruta
  antes de lanzar.

`claude-relay statusline`
: Comando para `statusLine`. Lee stdin; si hay `rate_limits` y el perfil está en
  el pool, escribe `usage/<perfil>.json` =
  `{profile, captured_at, session_id, rate_limits}` (atómico). Imprime una línea
  corta: `<perfil> · 5h 23% · 7d 41%` (o `sin dato`). Si hay
  `wrapped_statusline`, le pasa el mismo stdin y agrega su salida después,
  separada por ` │ `. Nunca falla.

`claude-relay hook guard`
: Para `UserPromptSubmit` y `PostToolUse`. Lee stdin (session_id,
  transcript_path, cwd, hook_event_name). Lee `usage/<perfil-actual>.json`;
  si el dato es de otra sesión igual sirve (es la misma cuenta). Nivel =
  puntaje como en `pick`.
  - nivel >= `warn_at` y aún no avisado (marca en `warned/` por perfil,
    sesión, nivel y `resets_at` de la ventana que disparó) → contexto suave:
    cuota en X %, ir cerrando, no empezar tareas largas.
  - nivel >= `handoff_at` y aún no avisado → contexto fuerte: dejar de empezar
    trabajo nuevo; escribir YA el handoff en la ruta exacta
    `handoffs/<proyecto>/<ts>-<sid8>.md` con secciones: Objetivo, Estado
    (hecho / en curso / pendiente), Archivos y ramas tocados, Decisiones y por
    qué, Próximos pasos concretos, Comandos para verificar, Riesgos/dudas;
    escribirlo en el idioma de la conversación; después decirle al usuario que
    corra `claude-relay resume --last` (o `--to <mejor perfil>`, nombrando el
    que devuelve `pick` en ese momento) en su terminal. El hook también
    registra esa ruta como handoff de la sesión para que `handoff`/`resume` la
    encuentren.
  - Salida JSON con `hookSpecificOutput.hookEventName` igual al evento recibido.
  - Fuera del pool, sin dato o error → exit 0 sin salida.

`claude-relay hook stop-failure`
: Para `StopFailure` (matcher `rate_limit`). Hace `handoff --to auto --session
  <sid> --quiet` con el transcript recibido y avisa al usuario con una
  notificación de escritorio (`osascript` en macOS, `notify-send` si existe en
  Linux; si no hay, nada). El aviso dice a qué perfil se copió y que corra
  `claude-relay resume --last`. Exit 0 siempre.

`claude-relay install [--profiles a,b,c | --profile nombre=dir]... [--settings PATH]... [--with-agent] [--warn-at N] [--handoff-at N] [--dry-run]`
: - Escribe el pool. `--profiles a,b` resuelve cada nombre a
    `${CLAUDE_PROFILES_ROOT:-~/.claude-profiles}/<nombre>` (debe existir);
    `--profile nombre=dir` para rutas arbitrarias. Si no se da nada, usa
    `default=~/.claude`.
  - Symlink `~/.local/bin/claude-relay` → `bin/claude-relay` del repo (avisar si
    `~/.local/bin` no está en PATH).
  - Settings destino: los `--settings` dados; si no, `~/.claude/settings.json`
    cuando `claude-profile` está en PATH (porque re-sincroniza desde ahí);
    si no, el `settings.json` de cada config_dir del pool.
  - Merge con jq, **aditivo e idempotente**: agrega a `hooks.UserPromptSubmit`,
    `hooks.PostToolUse` (sin matcher = todas las herramientas) y
    `hooks.StopFailure` (matcher `rate_limit`) un grupo cuyo comando es
    `<ruta absoluta>/claude-relay hook ...`. No toca los demás hooks. Si ya hay
    `statusLine` que no es de relay, la guarda en `wrapped_statusline` y pone
    `{"type":"command","command":"<ruta>/claude-relay statusline","refreshInterval":60}`.
  - Backup `settings.json.relay-backup-<ts>` antes de escribir. Validar el JSON
    resultante antes del `mv`.
  - `--with-agent` copia `agents/relay.md` a `~/.claude/agents/relay.md`.
  - `--dry-run` muestra el diff y no escribe nada.

`claude-relay uninstall [--settings PATH]... [--purge]`
: Saca solo lo que tiene `claude-relay` en el comando, restaura
  `wrapped_statusline` si la había, borra el symlink y el agente instalado.
  `--purge` borra también config y estado.

`claude-relay doctor`
: Chequea jq, versión de bash, `claude` en PATH, pool válido, settings con los
  hooks instalados, y para cada perfil si hay dato de uso y de cuándo.

`claude-relay --version`, `claude-relay help [subcomando]`.

## agents/relay.md

Subagente envoltorio (frontmatter `name: relay`, `tools: Bash`, `model: haiku`),
en el estilo de un forwarder: no investiga ni resuelve, solo reenvía la tarea
completa con **una** llamada Bash a
`claude-relay run --pick --exclude <perfil actual> -- -p "<tarea>" --output-format text`
(perfil actual: `claude-relay status --json`). Lectura por defecto
(`--permission-mode plan`); si la tarea pide escribir, `--permission-mode
acceptEdits`. Avisar que el hijo no ve la conversación (la tarea debe ir
completa), que se cobra a la cuenta elegida y cuál se usó. Tareas largas:
`run_in_background`.

## Tests (tests/run.sh)

Bash puro con `HOME`, `XDG_*` y config_dirs temporales y un `claude` falso en
PATH que registra argv, cwd y `CLAUDE_CONFIG_DIR` / vars de auth. Casos mínimos:

- statusline escribe `usage/<perfil>.json` con y sin `rate_limits`; fuera del
  pool no escribe; con `wrapped_statusline` concatena la salida.
- pick: menor puntaje gana; ventana vencida cuenta 0; sin dato = 50; >= 97
  descartado; `--exclude`; empate por orden; sin candidatos → exit 3.
- guard: < 90 sin salida; 90 → aviso suave una sola vez por sesión; 97 → aviso
  fuerte con la ruta del handoff; JSON válido con el `hookEventName` correcto;
  fuera del pool / JSON roto → exit 0 sin salida.
- handoff: copia jsonl y directorio hermano a `projects/<mismo nombre>/`,
  permisos 600, registra `last-handoff.json`, no pisa destino más nuevo, elige
  la sesión más reciente del cwd si no se da una.
- run/resume: el claude falso recibe el `CLAUDE_CONFIG_DIR` correcto, sin
  variables de auth, con `--resume <sid>` y el cwd original.
- install/uninstall sobre un settings.json con hooks ajenos (como los de
  Superset): idempotente (dos installs = mismo resultado), conserva lo ajeno,
  uninstall vuelve al original byte a byte salvo formato de jq; statusLine
  previa envuelta y restaurada; `--dry-run` no escribe.
- stop-failure copia al mejor perfil y no falla sin notificador.

Correr `shellcheck` si está instalado (no obligatorio).
