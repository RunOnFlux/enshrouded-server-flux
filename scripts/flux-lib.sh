#!/bin/bash
# Shared helpers for the Enshrouded image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Proton or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. ENSHROUDED_PATH, ENSHROUDED_CONFIG, STEAMCMD_PATH and GE_PROTON_VERSION come from the
# base image (sknnr/enshrouded-dedicated-server). The marketplace spec mounts the install
# (ml:), the savegame folder (g:, synced to the standby node) and enshrouded_server.json (f:)
# at exactly these paths, and the games hub's panel reads them: do not move them.
# ---------------------------------------------------------------------------------------------
FLUX_GAME_DIR="${FLUX_GAME_DIR:-${ENSHROUDED_PATH:-/home/steam/enshrouded}}"
FLUX_CONFIG="${FLUX_CONFIG:-${ENSHROUDED_CONFIG:-${FLUX_GAME_DIR}/enshrouded_server.json}}"
FLUX_SAVE_DIR="${FLUX_SAVE_DIR:-${FLUX_GAME_DIR}/savegame}"
# flux.log is on the install volume (the `ml:` mount: local, never synced), NOT in savegame (which
# the hub backs up, transfers and syncs to the standby: it holds the world and nothing else). It is
# written on every line, so on a synced volume it would be constant Syncthing traffic. One rotated
# copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_GAME_DIR}/flux}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-enshrouded_server.exe}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-${STEAM_APP_ID:-2278520}}"
FLUX_A2S="${FLUX_A2S:-/opt/flux/flux-a2s.py}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
FLUX_DEFAULT_QUERY_PORT=15637

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

# ---------------------------------------------------------------------------------------------
# enshrouded_server.json. The image never writes it: the games hub's Server Settings tab owns
# it. These only read it.
# ---------------------------------------------------------------------------------------------

# $1 = the file. Prints missing, empty, invalid or ok.
flux_config_state() {
  local file="$1"
  if [ ! -e "${file}" ]; then
    printf 'missing'
  elif [ ! -s "${file}" ]; then
    printf 'empty'
  elif jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'invalid'
  fi
}

# $1 = a requested port. True for a whole number 1..65535.
flux_valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# $1 = the file, $2 = the port it must set (FLUX_QUERY_PORT). Prints the JSON the file should
# hold, or nothing (status 1) when the file can be left as it is:
#   - empty or missing: just `{"queryPort": P}`. The game fills in every other key with its own
#     defaults on that start and keeps the port (verified 2026-10-01: 41234 bound, announced in
#     A2S, file completed to the full default set).
#   - valid JSON with another port: the same object with queryPort replaced, nothing else touched.
#   - valid JSON with this port already, or not valid JSON: nothing. A broken file is the
#     customer's to fix; rewriting it would throw their settings away.
flux_config_with_port() {
  local file="$1" port="$2" state
  state="$(flux_config_state "${file}")"
  case "${state}" in
    missing | empty) printf '{"queryPort": %d}\n' "$((10#${port}))" ;;
    ok)
      [ "$(jq -r '.queryPort // empty' "${file}" 2>/dev/null)" = "$((10#${port}))" ] && return 1
      jq --argjson p "$((10#${port}))" '.queryPort = $p' "${file}"
      ;;
    *) return 1 ;;
  esac
}

# $1 = the file. Prints the query port it sets, or 15637 (the game's default, and the port the
# marketplace spec publishes) when the file does not say.
flux_query_port() {
  local port
  port="$(jq -r '.queryPort // empty' "$1" 2>/dev/null)"
  if [[ "${port}" =~ ^[0-9]{1,5}$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]; then
    printf '%s' "${port}"
  else
    printf '%s' "${FLUX_DEFAULT_QUERY_PORT}"
  fi
}

# ---------------------------------------------------------------------------------------------
# The scheduled restart.
# ---------------------------------------------------------------------------------------------

# $1 = "HH:MM" (24 hour). Prints the minutes after midnight. Returns 1 for anything else,
# including an empty value, which means "no scheduled restart".
flux_restart_minute_of_day() {
  local value="$1" h m
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%s' $((h * 60 + m))
}

# $1 = minute of the day the restart is set for, $2 = the current minute of the day,
# $3 = the current second of that minute. Prints how many seconds until the next restart, in
# the same timezone both minutes were taken in. A restart due this very minute is tomorrow's:
# otherwise a server that restarts at 05:00 and is back up at 05:00:40 restarts again.
flux_seconds_until() {
  local target="$1" now_min="$2" now_sec="${3:-0}" delta
  delta=$(((target - now_min) * 60 - now_sec))
  [ "${delta}" -le 0 ] && delta=$((delta + 86400))
  printf '%s' "${delta}"
}

# $1 = the longest the owner lets a restart wait for players to leave, in minutes. Prints it
# clamped to 0..180 (default 60). Past three hours a "daily" restart starts drifting into the
# next evening's play.
flux_max_wait_minutes() {
  local value="${1:-60}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=60
  value=$((10#${value}))
  [ "${value}" -gt 180 ] && value=180
  printf '%s' "${value}"
}

# What to do when the restart is due. Enshrouded cannot warn its players (no RCON, no
# broadcast), so instead of restarting through them the restart waits for the server to empty,
# up to a limit.
#   $1 = players online: a number, or empty when the server did not answer the query
#   $2 = minutes already waited, $3 = the most minutes to wait
# Prints "restart" or "wait".
# A server that does not answer is restarted: it is either still loading (nobody can be on it)
# or hung, and a hung server is exactly what a restart is for.
flux_restart_decision() {
  local players="$1" waited="$2" max="$3"
  if ! [[ "${players}" =~ ^[0-9]+$ ]]; then
    printf 'restart'
  elif [ "${players}" -eq 0 ]; then
    printf 'restart'
  elif [ "${waited}" -ge "${max}" ]; then
    printf 'restart'
  else
    printf 'wait'
  fi
}

# ---------------------------------------------------------------------------------------------
# The watchdog: a server that is alive as a process but has stopped serving.
# ---------------------------------------------------------------------------------------------

# $1 = the port, $2.. = the kernel's UDP socket tables (default /proc/net/udp and udp6).
# True when something in this container has the port bound. Containers have their own network
# namespace, so that something is the game.
flux_port_bound() {
  local port="$1" hex
  shift
  [ "$#" -eq 0 ] && set -- /proc/net/udp /proc/net/udp6
  hex="$(printf '%04X' "${port}")"
  awk -v want=":${hex}" 'FNR > 1 && substr($2, length($2) - 4) == want { found = 1 } END { exit !found }' "$@" 2>/dev/null
}

# What the watchdog makes of the latest checks.
#   $1 = consecutive checks the query port has been unbound, after it was bound once
#   $2 = seconds the server has not answered the player query, after it answered once
#   $3 = the most checks the port may be unbound, $4 = the most seconds without an answer (0 =
#        never restart for that)
# Prints ok, unbound or unresponsive.
flux_watchdog_verdict() {
  local unbound="$1" silent="$2" max_unbound="$3" max_silent="$4"
  if [ "${unbound}" -ge "${max_unbound}" ]; then
    printf 'unbound'
  elif [ "${max_silent}" -gt 0 ] && [ "${silent}" -ge "${max_silent}" ]; then
    printf 'unresponsive'
  else
    printf 'ok'
  fi
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. Only a server that ended on its own (or that the watchdog
# ended) counts against the budget: a scheduled restart is the plan working, and a stop was
# asked for.
flux_restart_counts() {
  case "$1" in
    scheduled*) return 1 ;;
    # Mods that stopped the server: the next start goes without them (safe mode), so this is a
    # fix being made, not a server that cannot stay up.
    mods:*) return 1 ;;
    *) return 0 ;;
  esac
}

# $1 = why the last generation ended, empty for the container's first start. True when the
# next Steam update must `validate`. A plain app_update does NOT repair a missing or damaged
# file (measured 2026-10-01: enshrouded_server.kfc deleted, plain update left it missing,
# validate restored it), and validate cost 30 s against 16 s on the same install. So the
# cheap update is kept for the daily restart and everything else validates: the first start
# of a container, a crash, the watchdog.
flux_update_validates() {
  case "$1" in
    scheduled*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

# The game's own process, as Wine names it: `Z:\home\steam\enshrouded\enshrouded_server.exe`
# (it was `X:\enshrouded\…` under Proton, until 2026-10-15). The launcher (`wine …`, and
# `proton run …` before it) can exit while the game runs on, so its pid says nothing about the
# server; and its command line also contains the exe's name, which is why this matches the drive
# letter Wine puts in front.
FLUX_GAME_PATTERN="${FLUX_GAME_PATTERN:-^[A-Z]:.*${FLUX_GAME_PROCESS//./\\.}}"

# Wine's own Windows services for the prefix (C:\windows\system32\services.exe and the rest).
# shellcheck disable=SC2034  # read by flux-entrypoint.sh
FLUX_WINE_SERVICES_PATTERN="^[A-Z]:\\\\windows\\\\"

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PATTERN}" 2>/dev/null | head -1
}

# Ctrl+C to the game. It saves and exits in about a second (measured 2026-10-01: Shutdown state,
# every save blob written, `Close Container`, then the process ends).
flux_signal_game() {
  pkill "-${1:-INT}" -f "${FLUX_GAME_PATTERN}" 2>/dev/null
}

# Players online, or nothing (and status 1) when the server does not answer.
flux_players_online() {
  python3 "${FLUX_A2S}" "$(flux_query_port "${FLUX_CONFIG}")" 2>/dev/null
}

# ---------------------------------------------------------------------------------------------
# Mods: EML, the Enshrouded Mod Loader (github.com/Brabb3l/kfc-parser). See flux-mods.py.
#
# The customer's library is the `mods` volume (FLUX_MODS_DIR, synced to the standby). EML never
# sees it: before every start the supervisor checks each entry and copies the ones that will load
# into `<game dir>/mods`, the folder EML reads, and puts EML's dbghelp.dll beside the server.
# With nothing to load, both are taken away and the install is put back to Steam's files.
# ---------------------------------------------------------------------------------------------
FLUX_MODS_DIR="${FLUX_MODS_DIR:-/home/steam/mods}"
FLUX_MODS_RUNTIME="${FLUX_MODS_RUNTIME:-${FLUX_GAME_DIR}/mods}"
FLUX_MODS_STATE="${FLUX_MODS_STATE:-${FLUX_GAME_DIR}/flux}"
FLUX_MODS_STATUS="${FLUX_MODS_STATUS:-${FLUX_MODS_STATE}/mods-status.json}"
FLUX_MODS_SAFE="${FLUX_MODS_SAFE:-${FLUX_MODS_STATE}/mods-safe-mode}"
FLUX_MODS_APPLIED="${FLUX_MODS_APPLIED:-${FLUX_MODS_STATE}/mods-applied}"
FLUX_MODS_PLAN="${FLUX_MODS_PLAN:-/tmp/flux-mods-plan.json}"
# Set by the watch when THIS generation came up with its mods. Per container (in /tmp), because a
# set that loaded yesterday says nothing about today: a game update can break it.
FLUX_MODS_LOADED_MARKER="${FLUX_MODS_LOADED_MARKER:-/tmp/flux-mods-loaded}"
# EML's log, per start. Relative, because EML resolves it from the game's working directory
# (the install), and the game is a Windows process that cannot take a Linux path.
FLUX_EML_LOG_REL="${FLUX_EML_LOG_REL:-flux/eml-log}"
# shellcheck disable=SC2034  # read by flux-entrypoint.sh and flux-modwatch.sh
FLUX_EML_LOG_DIR="${FLUX_GAME_DIR}/${FLUX_EML_LOG_REL}"
FLUX_EML_DLL="${FLUX_EML_DLL:-/opt/flux/eml/dbghelp.dll}"
FLUX_MODS_PY="${FLUX_MODS_PY:-/opt/flux/flux-mods.py}"

# stdin on one line: newlines and tabs become single spaces, the ends trimmed. For text that goes
# into a file read line by line (the safe-mode file), such as EML's errors with their traceback.
flux_one_line() {
  tr '\n\t' '  ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# The fingerprint the safe mode holds against this image, from the safe-mode file's lines:
#   $1 = the fingerprint it was set for, $2 = the EML version that failed, $3 = this image's EML.
# Empty when the safe mode was set by another EML: a newer loader may run the same mods, so the
# set gets one more try instead of staying off for good.
flux_mods_safe_for() {
  local fingerprint="$1" failed_eml="$2" eml="$3"
  [ -n "${failed_eml}" ] && [ "${failed_eml}" != "${eml}" ] && return 0
  printf '%s' "${fingerprint}"
}

# What this start does with mods.
#   $1 = mods the plan loads, $2 = the plan's fingerprint, $3 = the fingerprint the safe mode was
#   set for (empty when none), $4 = FLUX_MODS_DISABLED (any value turns mods off)
# Prints off, on or safe. Safe is the same set of mods that already stopped the server once: it
# starts without them until the set changes (or EML does, flux_mods_safe_for).
flux_mods_mode() {
  local count="$1" fingerprint="$2" safe="$3" disabled="$4"
  if [ -n "${disabled}" ] || ! [[ "${count}" =~ ^[0-9]+$ ]] || [ "${count}" -eq 0 ]; then
    printf 'off'
  elif [ -n "${safe}" ] && [ "${safe}" = "${fingerprint}" ]; then
    printf 'safe'
  else
    printf 'on'
  fi
}

# $1 = this start's mode, $2 = the fingerprint EML last patched the install for (empty when it
# never did, or the install has been put back since), $3 = 1 when EML's backup of the game data
# (enshrouded_server.kfc.bak) is in the install. True when the install still carries EML's
# changes and this start runs without them, so Steam must `validate` it back to the original.
flux_mods_restore_needed() {
  [ "$1" = "on" ] && return 1
  [ -n "$2" ] || [ "$3" = "1" ]
}

# $1 = seconds since the server was launched with mods, $2 = the most it may take to open its
# port, $3 = errors in EML's log so far, $4 = 1 once the port is bound.
# Prints wait, loaded or failed. EML stops the server with a message box nobody can click, so a
# server with mods that does not come up in time is treated as stopped by them. The port wins
# over an error: EML logs some ERRORs it carries on from, and a server that bound its port is up,
# whatever its log says. An error that stopped it never lets it get that far.
flux_mods_boot_verdict() {
  local elapsed="$1" timeout="$2" errors="$3" bound="$4"
  if [ "${bound}" = "1" ]; then
    printf 'loaded'
  elif [ "${errors}" -gt 0 ]; then
    printf 'failed'
  elif [ "${elapsed}" -ge "${timeout}" ]; then
    printf 'failed'
  else
    printf 'wait'
  fi
}
