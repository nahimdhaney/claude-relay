# claude-relay

`claude-relay` ayuda a continuar un trabajo de Claude Code entre perfiles con
cuentas distintas. Cada perfil usa su propio `CLAUDE_CONFIG_DIR`. La herramienta
guarda la cuota que recibe la statusline, elige el perfil con más margen y copia
una conversación para retomarla con `claude --resume`.

Antes de agotar la cuota, los hooks piden al modelo que escriba un handoff con el
estado del trabajo. El cambio de cuenta se hace desde tu terminal; el hook no
lanza otra sesión interactiva por su cuenta.

## Requisitos e instalación

Necesitas Claude Code instalado y autenticado por separado en los perfiles que
vayas a usar, Bash 3.2 o posterior y `jq` 1.6 o posterior. Se utilizan las
utilidades habituales de macOS/Linux. No hay dependencias de red ni se consultan
endpoints de cuota.

Clona este repositorio, entra en él y ejecuta:

```bash
./install.sh --dry-run
./install.sh
export PATH="$HOME/.local/bin:$PATH"
claude-relay doctor
```

Sin opciones se usa `default=$HOME/.claude`; ese directorio debe existir. Añade
la línea de PATH a la configuración de tu shell para conservarla. Mantén el
checkout en su ubicación: el ejecutable instalado es un symlink al repositorio.

Si ya utilizas `claude-profile`:

```bash
./install.sh --profiles personal,trabajo --with-agent
```

Los nombres se resuelven bajo `${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}`.
También puedes indicar directorios arbitrarios, incluyendo rutas con espacios:

```bash
./install.sh \
  --profile "personal=$HOME/.claude" \
  --profile "trabajo=$HOME/perfiles/Claude trabajo" \
  --warn-at 90 --handoff-at 97 --with-agent
```

Usa únicamente cuentas y perfiles que tengas autorización para utilizar. Relay
no inicia sesión, no transporta credenciales y no comparte autenticación entre
perfiles. Para `status`, solo extrae email y organización de
`<config_dir>/.claude.json`.

Puedes repetir `--profiles`, `--profile` y `--settings`. El pool se reemplaza por
la lista indicada, en ese orden. Si no pasas `--settings`, se modifica
`~/.claude/settings.json` cuando `claude-profile` está disponible en PATH (es su
fuente de sincronización); en otro caso, el `settings.json` de cada perfil.

La instalación agrega grupos a `UserPromptSubmit`, `PostToolUse` y `StopFailure`
(sin matcher), conserva los hooks ajenos y envuelve la statusline anterior.
Repetir la instalación migra el antiguo matcher `rate_limit` sin duplicar
grupos ni cambiar los matchers de hooks ajenos. Antes de cada escritura se crea
`settings.json.relay-backup-<fecha>.<sufijo>` y el JSON nuevo se valida antes del
reemplazo atómico. `--dry-run` muestra los cambios sin escribir archivos.

## Uso diario

```bash
claude-relay status
claude-relay status --json
claude-relay pick
claude-relay pick --exclude trabajo --json
claude-relay run --pick --
claude-relay run --profile personal -- --model sonnet
```

`status` muestra la cuenta, el porcentaje y reinicio local de ambas ventanas,
la antigüedad del dato, el puntaje y `*` en el perfil actual. Este se identifica
comparando la ruta resuelta de `CLAUDE_CONFIG_DIR` (por defecto `~/.claude`) con
las rutas del pool. Fuera del pool, indica explícitamente `--profile` o `--pick`.
`run` sin selector usa el perfil actual.

El puntaje es el mayor porcentaje entre las ventanas de 5 horas y 7 días. Una
ventana cuyo reinicio ya pasó cuenta como 0 y se marca «reinició». Sin ninguna
ventana válida se usa 50 por defecto. `pick` elige el menor puntaje, descarta
perfiles sin directorio o con puntaje de 97 o más y desempata por orden del pool.
Si no hay candidatos, devuelve código 3. Los perfiles explícitos permiten una
elección manual aunque no cumplan ese filtro.

Una cuenta marcada como agotada tiene puntaje 100 hasta que vence la marca;
`status` muestra «agotada hasta HH:MM» en hora local. Puedes marcarla o liberar
la marca manualmente:

```bash
claude-relay exhausted personal
claude-relay exhausted personal --for 90m   # también 4h o 3600s
claude-relay exhausted personal --until 1791828000  # epoch en segundos
claude-relay exhausted personal --clear
```

Sin plazo explícito, se usa el último `five_hour.resets_at` conocido si sigue
en el futuro; si no, `exhausted_ttl` (3600 segundos por defecto). `--for`,
`--until` y `--clear` son excluyentes. Una captura nueva con cuota válida y
puntaje menor que `handoff_at` borra la marca si `captured_at` es posterior a
su creación. Un dato ausente, anterior o todavía alto no la borra.

Al llegar a 90 %, el modelo recibe una advertencia para ir cerrando. Al llegar
a 97 %, recibe la ruta exacta de un handoff y sus secciones: objetivo, estado,
archivos y ramas, decisiones, próximos pasos, verificación y riesgos. El modelo
debe escribirlo en el idioma de la conversación. Cada nivel se avisa una vez
por perfil, sesión y reinicio de la ventana que lo disparó.

Cuando el modelo indique que el handoff está listo, desde tu terminal:

```bash
claude-relay resume --last
# O elige un destino:
claude-relay resume --last --to trabajo
```

El hook registra la sesión incluso antes de copiarla, por lo que `--last` puede
hacer el traspaso pendiente. El hook `StopFailure` registra todos los errores
recibidos y busca señales de límite de uso en sus campos de error. Si detecta
un límite, marca primero la cuenta agotada e intenta copiar la sesión al mejor
perfil. Envía una notificación de escritorio si hay un notificador disponible;
si falta el transcript o falla el traspaso, avisa «cuenta X agotada; no se pudo
copiar la sesión». El registro permite investigar si los errores de límite del
plan llegan realmente a ese hook.

También puedes hacerlo manualmente, desde el directorio del proyecto:

```bash
claude-relay handoff --from personal --to auto
claude-relay handoff --from personal --to trabajo --session ID --cwd "$PWD"
claude-relay handoff --from personal --to trabajo \
  --transcript /ruta/config/projects/proyecto/ID.jsonl --cwd /ruta/proyecto --json
claude-relay resume --last
claude-relay resume --session ID --to auto
```

Sin ID ni transcript, se elige el `.jsonl` más reciente por mtime en el proyecto
del cwd. Con un selector explícito y sin `--cwd`, se intenta recuperar el cwd
del transcript; si no lo contiene se usa el directorio actual. Un ID presente
en varios proyectos requiere `--transcript`. Se conserva el nombre del
directorio de proyecto de origen, sin recalcularlo para el destino.

Se copia también el directorio hermano de subagentes. Un archivo destino más
nuevo conserva su contenido. Los transcripts y handoffs se guardan con permisos
600 y los directorios nuevos con 700; las copias de archivos son atómicas.
Se rechazan enlaces simbólicos en los transcripts y sus destinos. No se copian
credenciales, configuración, archivos del proyecto, ramas ni worktrees: ambos
perfiles deben tener acceso al mismo cwd. `resume` muestra la ruta del handoff
y ejecuta `claude --resume ID` allí; no lo adjunta como un prompt nuevo.

`run` y `resume` eliminan las variables heredadas `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`,
`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY` y `ANTHROPIC_BASE_URL` antes de
lanzar Claude. Para pruebas o un ejecutable alternativo se puede definir
`CLAUDE_RELAY_CLAUDE_BIN` (ruta de un binario, sin argumentos).
También se eliminan `CLAUDECODE` y `CLAUDE_CODE_CHILD_SESSION`, para permitir el
proceso separado que solicita el forwarder y que Claude guarde sus transcripts
para futuros handoffs y reanudaciones.

## Configuración y estado

El archivo `${XDG_CONFIG_HOME:-$HOME/.config}/claude-relay/pool` contiene una línea
`nombre<TAB>config_dir` por perfil. Admite comentarios que empiecen con `#`.
Los nombres admiten letras ASCII, números, puntos, guiones y guiones bajos, y
empiezan con letra o número. Las rutas no admiten tabs ni saltos de línea.

En el mismo directorio, `config` es texto `clave=valor`, sin expansión de shell:

```ini
warn_at=90
handoff_at=97
unknown_score=50
exhausted_ttl=3600
wrapped_statusline=printf 'mi statusline'
```

`CLAUDE_RELAY_WARN_AT`, `CLAUDE_RELAY_HANDOFF_AT` y
`CLAUDE_RELAY_EXHAUSTED_TTL` tienen precedencia sobre sus claves. El TTL es un
entero positivo en segundos. Los
porcentajes deben estar entre 0 y 100, con `warn_at <= handoff_at`. La statusline
previa recibe exactamente el mismo JSON por stdin y su salida se concatena con
` │ `. Su comando se ejecuta mediante Bash, como código de configuración local.
Si falla, la statusline de relay tampoco imprime salida.

El estado está bajo `${XDG_STATE_HOME:-$HOME/.local/state}/claude-relay/`:

- `usage/<perfil>.json`: última medición recibida.
- `exhausted/<perfil>.json`: `{profile, at, until, source}`; tiempos epoch,
  origen `manual` o `stop-failure`. Mientras `until > now`, `status --json`
  expone `score:100`, `exhausted:true` y `exhausted_until`; no inventa ventanas.
- `events.log`: una línea JSON por StopFailure, modo 600. Incluye hora ISO UTC,
  perfil, session_id, claves superiores ordenadas y solo los campos presentes
  `error`, `error_type`, `error_details`, `matcher`, `reason`, `message`.
  El session_id y esos valores se sanean y truncan a 200 caracteres; no se
  registran transcripts ni otros valores del payload.
- `handoffs/<proyecto>/<fecha>-<sid8>.md`: handoffs privados.
- `last-handoff.json`: último traspaso o traspaso pendiente.
- `warned/`: marcas de avisos ya entregados.
- `sessions/`: asociación persistente entre una sesión y su handoff.

`installed-settings.json`, en el directorio de configuración, registra los
settings modificados y las statuslines originales. Permite restaurar todas sus
opciones y manejar statuslines diferentes por perfil. No contiene credenciales.

## Subagente opcional

`--with-agent` instala `agents/relay.md` en `~/.claude/agents/relay.md`. Es un
forwarder con modelo Haiku y solo herramienta Bash: pasa la tarea completa en
una llamada a `claude-relay run --pick --exclude <actual> -- -p ...`. El hijo
**no ve la conversación**; el encargo debe contener todo el contexto necesario.
El uso se carga a la cuenta elegida y el wrapper informa qué perfil se usó.

El modo de permisos predeterminado es `plan`; si la tarea pide escribir, usa
`acceptEdits`. Para tareas largas solicita `run_in_background`. No asumas que
esas corridas actualizan la cuota que ve relay.

## Diagnóstico, pruebas y desinstalación

```bash
claude-relay doctor
claude-relay help
claude-relay help handoff
claude-relay --version
bash tests/run.sh
/bin/bash tests/run.sh
# Si tienes shellcheck:
shellcheck -x bin/claude-relay install.sh lib/*.sh tests/*.sh
claude-relay uninstall
# También elimina configuración, mediciones y handoffs:
claude-relay uninstall --purge
```

La suite crea HOME, XDG, perfiles, temporales y un `claude` falso dentro de
`tests/.sandbox.*`, y los elimina al salir. No instala sobre tu configuración
real, no ejecuta Claude real ni envía notificaciones reales.

`uninstall` admite `--settings PATH` repetido; sin esa opción usa los settings
registrados. Quita comandos que contienen `claude-relay`, restaura la statusline
previa si relay todavía ocupa ese lugar y conserva los cambios ajenos. Borra el
symlink propio y el agente si coincide con la plantilla instalada. Los backups
de settings quedan junto a sus originales, incluso con `--purge`.

## Limitaciones y términos

Observado en pruebas reales el **2026-10-12**, con **Claude Code 2.1.296**:

- Los asientos **Team sí reciben `rate_limits`**, pero solo `five_hour`, sin
  `seven_day`.
- Bajo `claude -p` la statusline **no se ejecuta**, por lo que el uso headless
  no queda medido por relay, incluido el subagente.
- Una cuenta que ya está en su límite nunca obtiene una respuesta exitosa y
  no produce medición. Por eso existen las marcas de agotamiento: evitan que
  esa cuenta aparezca como «sin dato» con puntaje 50 y vuelva a ser elegida.
- El primer lanzamiento interactivo en una carpeta nueva muestra el prompt
  de confianza del workspace; hay que resolverlo en la terminal.

Otras limitaciones:

- `rate_limits` solo llega por la statusline y después de la primera respuesta.
  Una o ambas ventanas pueden faltar; relay no inventa una medición.
- Una entrada sin `rate_limits` no borra una medición válida previa. Revisa su
  antigüedad: otra sesión, otra máquina o un cambio de cuenta dentro del mismo
  directorio pueden dejarla desactualizada. No hay sondeo de cuota en red.
- Aún no se ha confirmado si «You've hit your session limit · resets 2:10pm»
  llega a `StopFailure`. Se instala sin matcher para observar los eventos en
  `events.log`; si no llega, usa `exhausted` manualmente. El TTL de respaldo
  es una estimación y puede requerir `--for` o `--until`.
- El formato y la ubicación de los transcripts son internos de Claude Code y
  pueden cambiar. El SPEC registra una comprobación manual de `--resume` entre
  perfiles con Claude Code 2.1.296; esta suite usa un binario falso y no certifica
  compatibilidad con cada versión. Comprueba una sesión de prueba al actualizar.
- El handoff depende de que el modelo tenga tiempo y permisos para escribirlo.
  El placeholder creado por el hook puede estar vacío si la cuota se agota
  antes. No se garantiza un traspaso si no hay otro perfil disponible.
- Los hooks y la statusline silencian errores y terminan con código 0. Usa
  `doctor` y los subcomandos manuales para investigar problemas. Una statusline
  ajena lenta puede aumentar el tiempo de ejecución del wrapper. El objetivo
  para los caminos comunes es menos de 100 ms; no es un límite garantizado.
  La suite informa tiempos orientativos, que dependen de la máquina y su carga.

Los términos de Anthropic indican que los límites de los planes asumen
«ordinary, individual usage». Cada usuario es responsable de utilizar la
herramienta y sus cuentas dentro de los términos aplicables. Esta nota no es
asesoramiento legal.
