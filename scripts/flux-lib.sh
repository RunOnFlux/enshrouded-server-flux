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
# Our own log lives on the install volume, NOT in savegame: savegame is what the hub backs up,
# transfers and syncs to the standby, and it should hold the world and nothing else.
FLUX_LOG="${FLUX_LOG:-${FLUX_GAME_DIR}/flux/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-enshrouded_server.exe}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-${STEAM_APP_ID:-2278520}}"
FLUX_A2S="${FLUX_A2S:-/opt/flux/flux-a2s.py}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
FLUX_DEFAULT_QUERY_PORT=15637

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
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

# The game's own process, as Wine names it: `X:\enshrouded\enshrouded_server.exe`. Proton's
# launcher (`proton run …`) starts it and EXITS AT ONCE with 0 (measured 2026-10-01), so the
# launcher's pid says nothing about the server; and its command line also contains the exe's
# name, which is why this matches the drive letter Wine puts in front.
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
