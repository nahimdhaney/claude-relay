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

## Hechos de Claude Code en los que se apoya

Observaciones reales del 2026-10-12 con Claude Code 2.1.296 incluidas abajo.

- El JSON que recibe el comando de `statusLine` por stdin trae
  `rate_limits.five_hour.{used_percentage,resets_at}` y
  `rate_limits.seven_day.{used_percentage,resets_at}` (`used_percentage` 0–100,
  `resets_at` epoch en segundos). Solo para suscriptores de claude.ai, solo
  después de la primera respuesta de la sesión, y cada ventana puede faltar.
  Verificado en asientos Team: reciben `five_hour`, sin `seven_day`.
  Ningún hook recibe `rate_limits`; por eso la statusline lo guarda en un
  archivo. Trae además `session_id`, `transcript_path`, `cwd`, `model`.
- La entrada de los hooks (JSON por stdin) trae `session_id`, `transcript_path`,
  `cwd`, `hook_event_name`. Los hooks heredan el entorno, así que
  `CLAUDE_CONFIG_DIR` dice qué perfil corre (si no está, es `~/.claude`).
- `UserPromptSubmit` y `PostToolUse` pueden inyectar contexto al modelo con
  `{"hookSpecificOutput":{"hookEventName":"<evento>","additionalContext":"..."}}`
  en stdout y exit 0.
- `StopFailure` corre cuando el turno termina por error de API. No está
  confirmado si el error de plan «You've hit your session limit · resets
  2:10pm» llega con matcher `rate_limit`; relay se instala sin matcher y
  registra los eventos para investigarlo. Su salida se ignora.
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
- `claude -p` (headless) no ejecuta la statusline: su gasto no queda medido.
- Una cuenta ya agotada nunca obtiene una respuesta exitosa ni una medición;
  requiere una marca de agotamiento independiente de `rate_limits`.
- El primer lanzamiento interactivo en una carpeta nueva muestra el prompt
  de confianza del workspace.
- `CLAUDE_CODE_CHILD_SESSION=1` heredado desactiva el guardado de transcripts.
  `run` y `resume` quitan ese marcador junto con `CLAUDECODE`.

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
tests/round2.sh           regresiones de agotamiento, hooks y lanzamiento
tests/fixtures/           JSON de ejemplo (statusline, hooks)
README.md                 en español: qué hace, instalar, usar, límites, términos
docs/SPEC.md              este archivo
```

## Configuración

- Pool: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/pool`, una línea por
  perfil `nombre<TAB>config_dir`, `#` comentarios. Orden = prioridad de desempate.
- Opciones: `${XDG_CONFIG_HOME:-~/.config}/claude-relay/config` (`clave=valor`):
  `warn_at=90`, `handoff_at=97`, `unknown_score=50`, `exhausted_ttl=3600`,
  `wrapped_statusline=<cmd>`. `exhausted_ttl` es un entero positivo en segundos.
  Variables de entorno `CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` y
  `CLAUDE_RELAY_EXHAUSTED_TTL` pisan sus claves correspondientes.
- Estado: `${XDG_STATE_HOME:-~/.local/state}/claude-relay/`:
  `usage/<perfil>.json`, `handoffs/<proyecto>/<YYYYmmdd-HHMMSS>-<sid8>.md`,
  `last-handoff.json`, `warned/<perfil>-<sid>-<nivel>-<resets_at>`,
  `exhausted/<perfil>.json`, `events.log`.
- Perfil actual = el nombre del pool cuyo `config_dir` coincide (ruta resuelta)
  con `${CLAUDE_CONFIG_DIR:-~/.claude}`. Si no coincide ninguno: no es del pool.

## Subcomandos

`claude-relay status [--json]`
: Tabla: perfil, cuenta (email · org), 5 h %, 7 d %, cuándo reinicia cada
  ventana (hora local), antigüedad del dato, puntaje, y marca `*` en el perfil
  actual. Una ventana cuyo `resets_at` ya pasó se muestra como 0 % ("reinició").
  Con marca de agotamiento vigente, muestra «agotada hasta HH:MM» (hora local).
  El JSON incluye `exhausted:true`, `exhausted_until` y `score:100`; sin marca
  vigente incluye `exhausted:false` y el puntaje de uso normal.

`claude-relay pick [--exclude P]... [--json]`
: Imprime el nombre del mejor perfil. Puntaje = máximo `used_percentage` de las
  ventanas vigentes (vencidas = 0); sin dato = `unknown_score`. Se descartan los
  perfiles con puntaje >= `handoff_at` y los perfiles cuyo config_dir no existe.
  Menor puntaje gana; empate → orden del pool. Sin candidatos → exit 3 y mensaje
  a stderr.

`claude-relay exhausted <perfil> [--for DURATION | --until EPOCH] [--clear]`
: Escribe atómicamente `exhausted/<perfil>.json` (modo 600) =
  `{profile, at, until, source}`. `at` y `until` son epoch en segundos;
  `source` es `manual` o `stop-failure`. Por defecto `until` es el último
  `five_hour.resets_at` conocido si está en el futuro; si no, `now + exhausted_ttl`.
  `--for` acepta enteros positivos con sufijo `s`, `m` o `h` (3600s, 90m, 4h).
  `--until` acepta un epoch entero no negativo. `--clear` borra la marca de
  forma idempotente; esas tres opciones son excluyentes. Requiere un perfil
  del pool. Mientras `until > now`, `measurement()` informa puntaje 100 y
  `exhausted:true`, incluso sin mediciones, impidiendo su selección automática.
  Una marca vencida deja de influir sin borrar las mediciones previas.

`claude-relay run [--profile P | --pick] [--exclude P]... -- <args de claude>`
: `exec` de `claude` con `CLAUDE_CONFIG_DIR` del perfil y sin las variables de
  auth ni `CLAUDECODE` / `CLAUDE_CODE_CHILD_SESSION`; esto permite guardar los
  transcripts del proceso separado. Aplica también a `resume`. Binario
  configurable con `CLAUDE_RELAY_CLAUDE_BIN` (para tests).

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
  Una captura con ventana válida, puntaje menor que `handoff_at` y
  `captured_at > marker.at` borra la marca de agotamiento. Capturas sin ventanas,
  anteriores/iguales a la marca o con puntaje alto no la borran.

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
: Para todos los `StopFailure`, sin matcher. En este orden:
  1. Añade una línea JSON saneada a `events.log` (modo 600): `at` ISO UTC,
     `profile`, `session_id`, `keys` (claves superiores ordenadas) y los valores
     presentes de `error`, `error_type`, `error_details`, `matcher`, `reason`,
     `message`. Reemplaza controles en los valores por espacios y trunca cada
     valor y el session_id a 200 caracteres. No registra transcripts ni ningún
     otro valor de entrada.
  2. Detecta límite si alguno de esos seis campos equivale a `rate_limit` o su
     texto completo coincide, sin distinguir mayúsculas, con
     `rate.?limit|usage limit|session limit|weekly limit|hit your .*limit|limit reached`.
     Otros errores solo se registran; no marcan, copian ni notifican.
  3. Marca el perfil actual agotado antes de intentar copiar.
  4. Intenta `handoff --to auto` con el transcript recibido. Notifica el perfil
     destino y `claude-relay resume --last` si funcionó; si falta el transcript
     o falla la copia/selección, notifica «cuenta X agotada; no se pudo copiar
     la sesión». Usa `osascript` en macOS o `notify-send` en Linux si existe.
  Fuera del pool o entrada inválida, sin salida; exit 0 siempre. La copia corre
  en un proceso separado para conservar el manejo de errores de Bash.

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
    `hooks.StopFailure` (sin matcher) un grupo cuyo comando es
    `<ruta absoluta>/claude-relay hook ...`. Migra entradas relay antiguas con
    matcher `rate_limit`; no toca los demás hooks ni sus matchers, incluso si
    compartían grupo con relay. Si ya hay
    `statusLine` que no es de relay, la guarda en `wrapped_statusline` y pone
    `{"type":"command","command":"<ruta>/claude-relay statusline","refreshInterval":60}`.
  - Backup `settings.json.relay-backup-<ts>` antes de escribir. Validar el JSON
    resultante antes del `mv`.
  - `--with-agent` copia `agents/relay.md` a `~/.claude/agents/relay.md`.
  - `--dry-run` muestra el diff y no escribe nada.

`claude-relay uninstall [--settings PATH]... [--purge]`
: Saca solo lo que tiene `claude-relay` en el comando, restaura
  `wrapped_statusline` si la había, borra el symlink y el agente instalado.
  Quita entradas relay tanto antiguas (matcher `rate_limit`) como nuevas
  (sin matcher), conservando los hooks ajenos e idempotencia.
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
- agotamiento: sin medición se descarta; TTL por config/env, reset futuro,
  plazos manuales, expiración, borrado idempotente y recuperación solo con una
  captura más nueva y por debajo del umbral.
- stop-failure: registro saneado y privado, clasificación de los seis campos,
  errores ajenos sin handoff, marca antes de copiar, notificación aun sin
  transcript o con error de copia; no falla sin notificador.
- migración de StopFailure con matcher antiguo, incluso en grupos mixtos.
- el claude falso recibe `CLAUDE_CODE_CHILD_SESSION` sin definir tanto en run
  como resume. La muestra Team sin `seven_day` se mide correctamente.

Correr `bash tests/run.sh` y `/bin/bash tests/run.sh`: las 106 pruebas previas
más las regresiones nuevas deben pasar. Correr `shellcheck` si está instalado.
La suite no verifica Claude real, prompts de confianza ni ejecución de
statusline en modo headless; esas observaciones son de las pruebas manuales.
