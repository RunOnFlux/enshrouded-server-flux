#!/bin/bash
# The watchdog, started by the supervisor for each generation. It restarts a server that is
# still alive as a process but has stopped serving:
#
#   - the query port is no longer bound (FLUX_WATCHDOG_UNBOUND_CHECKS checks in a row, after it
#     was bound once). This is the base image's own rule: its entrypoint held the container open
#     only while the port was bound, and ended it the moment it was not.
#   - the server stopped answering Steam's player query for FLUX_WATCHDOG_UNRESPONSIVE_MINUTES
#     (default 10, 0 turns this off), after it had answered once. A hung game keeps its process
#     and its port and drops off the server browser, and nothing else in the container notices.
#
# Neither starts counting until the server has served once, so the minutes of a first install
# or a world load are never mistaken for a hang. The restart is SIGINT, so the world is saved if
# the game can still save; the supervisor kills it after FLUX_STOP_GRACE if it cannot. It counts
# against the supervisor's restart budget like a crash.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

interval="${FLUX_WATCHDOG_INTERVAL:-30}"
max_unbound="${FLUX_WATCHDOG_UNBOUND_CHECKS:-3}"
max_silent_minutes="${FLUX_WATCHDOG_UNRESPONSIVE_MINUTES:-10}"
[[ "${max_silent_minutes}" =~ ^[0-9]+$ ]] || max_silent_minutes=10
max_silent=$((10#${max_silent_minutes} * 60))

port_seen=0
answered=0
unbound=0
silent=0

while :; do
  sleep "${interval}"
  # A restart already under way (the schedule, or a stop) is not ours to judge.
  [ -f "${FLUX_RESTART_MARKER}" ] && exit 0

  port="$(flux_query_port "${FLUX_CONFIG}")"
  if flux_port_bound "${port}"; then
    port_seen=1
    unbound=0
  elif [ "${port_seen}" = "1" ]; then
    unbound=$((unbound + 1))
  fi

  if flux_players_online >/dev/null; then
    answered=1
    silent=0
  elif [ "${answered}" = "1" ]; then
    silent=$((silent + interval))
  fi

  verdict="$(flux_watchdog_verdict "${unbound}" "${silent}" "${max_unbound}" "${max_silent}")"
  case "${verdict}" in
    unbound) why="the query port ${port} has not been bound for ${unbound} checks" ;;
    unresponsive) why="the server has not answered the player query for $((silent / 60)) minutes" ;;
    *) continue ;;
  esac

  [ -z "$(flux_game_pid)" ] && exit 0
  [ -f "${FLUX_RESTART_MARKER}" ] && exit 0
  printf 'watchdog: %s' "${why}" >"${FLUX_RESTART_MARKER}"
  flux_log "watchdog: ${why}; asking the server to save and exit"
  flux_signal_game INT
  exit 0
done
