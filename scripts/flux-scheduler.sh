#!/bin/bash
# The scheduled restart, one per day, started by the supervisor for each generation.
#
#   FLUX_RESTART_TIME               HH:MM, 24 hour, in the container's TZ. Empty = no restart.
#   FLUX_RESTART_MAX_WAIT_MINUTES   how long a due restart waits for players to leave (0..180,
#                                   default 60). 0 restarts on time whoever is online.
#
# A restart is also when the server updates: the supervisor runs SteamCMD before every start.
# The image this replaces updated only when the container was recreated, so a server stayed on
# the old build, and turned away updated players, until someone restarted it by hand.
#
# THERE IS NO WARNING TO SEND. Enshrouded has no RCON, no admin console and no broadcast, so
# nothing inside the container can talk to players. Instead of restarting through them unwarned,
# a due restart asks the server how many players are online (Steam A2S_INFO on the query port)
# and, while anyone is, checks again every minute, up to FLUX_RESTART_MAX_WAIT_MINUTES. Then it
# restarts regardless. A server that does not answer the query is restarted at once: it is
# still loading, so nobody is on it, or it is hung, which is what a restart is for.
#
# THE RESTART ITSELF IS SIGINT, the same signal the base image sends on `docker stop`. The
# supervisor waits for the game to save and exit and starts the next generation in place.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

target="$(flux_restart_minute_of_day "${FLUX_RESTART_TIME:-}")" || {
  [ -n "${FLUX_RESTART_TIME:-}" ] && flux_log "WARN FLUX_RESTART_TIME='${FLUX_RESTART_TIME}' is not HH:MM; no scheduled restart"
  exit 0
}
max_wait="$(flux_max_wait_minutes "${FLUX_RESTART_MAX_WAIT_MINUTES:-60}")"

# The restart, as an absolute time, computed once, so the countdown cannot roll over to
# tomorrow halfway through.
now_h=0 now_m=0 now_s=0
IFS=: read -r now_h now_m now_s <<<"$(date +%H:%M:%S)"
due=$(( $(date +%s) + $(flux_seconds_until "${target}" $((10#${now_h} * 60 + 10#${now_m})) $((10#${now_s}))) ))

flux_log "scheduled restart at ${FLUX_RESTART_TIME} (${TZ:-UTC}), in $(( (due - $(date +%s)) / 60 )) minutes; waits up to ${max_wait} minutes for players to leave"

# Sleeps until the restart is due, in steps of at most five minutes so a clock that moves is
# noticed.
while :; do
  left=$(( due - $(date +%s) ))
  [ "${left}" -le 0 ] && break
  sleep $(( left > 300 ? 300 : left ))
done

waited=0
while :; do
  players="$(flux_players_online)" || players=""
  decision="$(flux_restart_decision "${players}" "${waited}" "${max_wait}")"
  [ "${decision}" = "restart" ] && break
  [ "${waited}" = "0" ] && flux_log "scheduled restart due, but ${players} player(s) online: waiting for them to leave (up to ${max_wait} minutes)"
  sleep 60
  waited=$((waited + 1))
done

if [ -z "${players}" ]; then
  why="the server did not answer the player query"
elif [ "${players}" = "0" ]; then
  why="no players online"
else
  why="${players} player(s) still online after waiting ${waited} minutes"
fi

pid="$(flux_game_pid)"
if [ -z "${pid}" ]; then
  flux_log "scheduled restart due, but the server is not running; nothing to restart"
  exit 0
fi
printf 'scheduled restart at %s' "${FLUX_RESTART_TIME}" >"${FLUX_RESTART_MARKER}"
flux_log "scheduled restart (${why}): asking the server to save and exit"
flux_signal_game INT
