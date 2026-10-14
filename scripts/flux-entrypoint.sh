#!/bin/bash
# PID 1, and the supervisor of the Enshrouded server.
#
# The base image's entrypoint (sknnr/enshrouded-dedicated-server) updates the server from Steam,
# starts it under Proton and then holds the container open while the query port is bound. When
# the server ends, the container ends, and nothing starts it again until the platform notices.
# It has no schedule of any kind, so a server only updated when its container was recreated.
#
# This supervisor keeps everything the base image does on a start (same Proton, same paths, same
# user, same SteamCMD install) and adds:
#
#   - a daily restart (flux-scheduler.sh, FLUX_RESTART_TIME), which also updates the server
#   - a watchdog (flux-watchdog.sh) that restarts a server which is running but not serving
#   - a new generation in place when the game ends, updating from Steam first, so a restart
#     never depends on the platform noticing
#   - SIGTERM/SIGINT from Docker turned into SIGINT to the game, as the base image did, and no
#     restart afterwards
#   - the container ends (exit 42) only after FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside
#     FLUX_RESTART_WINDOW seconds: a server that cannot stay up is the platform's to move
#   - mods through EML, from the `mods` volume, checked before every start, with a safe mode for a
#     set that stops the server (flux-mods.py, flux-modwatch.sh)
#
# enshrouded_server.json BELONGS TO THE GAMES HUB's Server Settings tab, with one exception: the
# port. With FLUX_QUERY_PORT set, the supervisor makes `queryPort` that number before every start
# and touches nothing else. The game announces the port it binds (A2S and the server list), and
# Flux publishes the same number outside, so several servers can share one node address. The
# write is in place (`cat > file`): the file is bind-mounted, and the base image's `mv` onto it
# failed on Flux with "Device or resource busy", so its env-driven rewrite never changed anything.
#
# Same shape as runonflux/vrising-server-flux and runonflux/palworld-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take to save before it is killed. Docker's own deadline
# on Flux is ten seconds, so this only matters for a restart, where nobody is waiting on us.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-60}"
FLUX_LAUNCH_GRACE="${FLUX_LAUNCH_GRACE:-60}"

g="${FLUX_GAME_DIR}"
proton="${STEAMCMD_PATH}/compatibilitytools.d/GE-Proton${GE_PROTON_VERSION}/proton"
wineserver="$(dirname "${proton}")/files/bin/wineserver"

rm -f "${FLUX_RESTART_MARKER}"

flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, base ${FLUX_BASE_IMAGE:-unknown}, GE-Proton${GE_PROTON_VERSION})"

launcher_pid=""
launched_at=0
game_seen=0
scheduler_pid=""
watchdog_pid=""
steam_pid=""
terminating=0
generation=0
restart_history=()
# Why the previous generation ended; empty before the first. Decides whether the next update
# validates (flux_update_validates).
last_reason=""
# This generation's mods: off, on or safe (flux_mods_mode), the plan's fingerprint, and whether
# Steam must put the install back first because EML's changes are in it.
mods_mode="off"
mods_fingerprint=""
mods_restore=0
modwatch_pid=""

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: asking the server to save and exit, no restart will follow"
  flux_signal_game INT
}
trap term_handler TERM INT

# One SteamCMD run, in the background and waited on, so a stop during a long download is
# answered at once instead of when the download ends (bash runs a trap only between
# commands). Returns SteamCMD's status, or 2 when a stop arrived.
run_steamcmd() {
  local rc
  "${STEAMCMD_PATH}/steamcmd.sh" +@sSteamCmdForcePlatformType windows +force_install_dir "${g}" \
    +login anonymous +app_update "${FLUX_STEAM_APP}" "$@" +quit &
  steam_pid=$!
  wait "${steam_pid}"
  rc=$?
  if [ "${terminating}" = "1" ]; then
    pkill -TERM -P "${steam_pid}" 2>/dev/null
    kill -TERM "${steam_pid}" 2>/dev/null
    steam_pid=""
    return 2
  fi
  steam_pid=""
  [ "${rc}" = "0" ] && return 0
  return 1
}

# $1 = why the previous generation ended (see flux_update_validates), $2 = 1 to validate whatever
# the reason (mods being taken off). Returns 0 when the server can start, 1 when there is nothing
# to start, 2 when a stop arrived. Sets steam_ok to 1 when SteamCMD finished, which is what tells
# the mods code the install really was put back.
steam_ok=0
update_server() {
  local attempt validate=() rc
  steam_ok=0
  if [ -n "${SKIP_UPDATE:-}" ] && [ -f "${g}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  if [ "${2:-0}" = "1" ] || flux_update_validates "$1"; then
    validate=(validate)
    flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}), checking every file"
  else
    flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  fi
  for attempt in 1 2 3 4 5; do
    run_steamcmd "${validate[@]}"
    rc=$?
    if [ "${rc}" = "0" ]; then
      [ "${#validate[@]}" -gt 0 ] && steam_ok=1
      return 0
    fi
    [ "${rc}" = "2" ] && return 2
    validate=(validate)
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    rm -f "${g}"/steamapps/appmanifest_*.acf
    sleep 5 &
    wait $!
    [ "${terminating}" = "1" ] && return 2
  done
  # A server that already has its files can still run the build it has.
  if [ -f "${g}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

prepare_files() {
  local state
  mkdir -p "${FLUX_SAVE_DIR}" "${g}/logs"
  if ! touch "${FLUX_SAVE_DIR}/.permtest" 2>/dev/null; then
    flux_log "ERROR the savegame folder ${FLUX_SAVE_DIR} is not writable by $(id -u):$(id -g)"
    return 1
  fi
  rm -f "${FLUX_SAVE_DIR}/.permtest"

  state="$(flux_config_state "${FLUX_CONFIG}")"
  case "${state}" in
    ok) ;;
    missing)
      # Only when run by hand without the file mount: Flux always mounts one.
      flux_log "enshrouded_server.json not found: copying the base image's example"
      cp /home/steam/enshrouded_server_example.json "${FLUX_CONFIG}"
      ;;
    empty) flux_log "enshrouded_server.json is empty: the server writes its own defaults on this start" ;;
    *) flux_log "WARN enshrouded_server.json is not valid JSON; the server may ignore it" ;;
  esac
  apply_query_port

  # The game's log on the container's output (the base image's trick): the game writes to
  # logs/enshrouded_server.log, and that name now points at PID 1's stdout.
  : >"${g}/logs/enshrouded_server.log" 2>/dev/null
  ln -sf /proc/1/fd/1 "${g}/logs/enshrouded_server.log"
}

# FLUX_QUERY_PORT into enshrouded_server.json, in place. See the header.
apply_query_port() {
  local port="${FLUX_QUERY_PORT:-}" content
  [ -n "${port}" ] || return 0
  if ! flux_valid_port "${port}"; then
    flux_log "WARN FLUX_QUERY_PORT='${port}' is not a port; leaving enshrouded_server.json as it is"
    return 0
  fi
  content="$(flux_config_with_port "${FLUX_CONFIG}" "${port}")" || return 0
  if printf '%s\n' "${content}" >"${FLUX_CONFIG}"; then
    flux_log "enshrouded_server.json: queryPort set to $((10#${port})) (FLUX_QUERY_PORT)"
  else
    flux_log "WARN could not write queryPort ${port} into enshrouded_server.json"
  fi
}

# ── Mods ──────────────────────────────────────────────────────────────────────────────────────

# Before the Steam update: what this start loads, and whether the install must be put back.
mods_plan() {
  local count safe bak=0 applied="" moved
  mods_mode="off" mods_fingerprint="" mods_restore=0
  mkdir -p "${FLUX_MODS_STATE}" 2>/dev/null
  if [ ! -d "${FLUX_MODS_DIR}" ]; then
    # A server deployed before the mods volume existed. Nothing of ours to take off either.
    printf '{"mods":[],"active":[],"fingerprint":""}\n' >"${FLUX_MODS_PLAN}"
  else
    # Mods put straight into the folder EML reads (the Files tab, before the library existed)
    # move into the library, so the sync below does not delete them.
    if [ -w "${FLUX_MODS_DIR}" ]; then
      moved="$(python3 "${FLUX_MODS_PY}" adopt "${FLUX_MODS_DIR}" "${FLUX_MODS_RUNTIME}" 2>/dev/null)"
      [ -n "${moved}" ] && flux_log "mods: moved into the mods volume: $(tr '\n' ' ' <<<"${moved}")"
    fi
    if ! python3 "${FLUX_MODS_PY}" plan "${FLUX_MODS_DIR}" >"${FLUX_MODS_PLAN}" 2>/dev/null; then
      flux_log "WARN mods: the mods volume could not be read; starting without mods"
      printf '{"mods":[],"active":[],"fingerprint":""}\n' >"${FLUX_MODS_PLAN}"
    fi
  fi
  count="$(jq -r '.active | length' "${FLUX_MODS_PLAN}" 2>/dev/null)"
  mods_fingerprint="$(jq -r '.fingerprint // ""' "${FLUX_MODS_PLAN}" 2>/dev/null)"
  safe="$(head -n 1 "${FLUX_MODS_SAFE}" 2>/dev/null)"
  mods_mode="$(flux_mods_mode "${count:-0}" "${mods_fingerprint}" "${safe}" "${FLUX_MODS_DISABLED:-}")"
  [ -f "${g}/enshrouded_server.kfc.bak" ] && bak=1
  applied="$(head -n 1 "${FLUX_MODS_APPLIED}" 2>/dev/null)"
  flux_mods_restore_needed "${mods_mode}" "${applied}" "${bak}" && mods_restore=1

  jq -r '.mods[] | select(.state != "active" and .state != "off") | "\(.entry): \(.reason)"' \
    "${FLUX_MODS_PLAN}" 2>/dev/null | while IFS= read -r line; do flux_log "WARN mods: not loading ${line}"; done
  case "${mods_mode}" in
    on) flux_log "mods: loading ${count} with EML ${FLUX_EML_VERSION:-}: $(jq -r '.active | join(", ")' "${FLUX_MODS_PLAN}")" ;;
    safe) flux_log "mods: this set of mods stopped the server last time ($(sed -n 2p "${FLUX_MODS_SAFE}" 2>/dev/null)); starting without them until it changes" ;;
  esac
  [ "${mods_restore}" = "1" ] && flux_log "mods: putting the install back to Steam's files, without EML's changes"
  return 0
}

# After the update: the folder EML reads, EML itself, and the status file for the games hub.
mods_apply() {
  local changes message
  if [ "${mods_restore}" = "1" ] && [ "${steam_ok}" = "1" ]; then
    # Steam has put every file back. EML's backup of the old data and the record of what it
    # patched describe an install that no longer exists.
    rm -f "${FLUX_MODS_APPLIED}" "${g}/enshrouded_server.kfc.bak"
  fi
  if [ "${mods_mode}" = "on" ]; then
    if ! changes="$(python3 "${FLUX_MODS_PY}" sync "${FLUX_MODS_DIR}" "${FLUX_MODS_RUNTIME}" "${FLUX_MODS_PLAN}" 2>&1)"; then
      flux_log "WARN mods: could not prepare the mods folder (${changes}); starting without mods"
      mods_mode="off"
    elif ! cmp -s "${FLUX_EML_DLL}" "${g}/dbghelp.dll" && ! cp "${FLUX_EML_DLL}" "${g}/dbghelp.dll"; then
      flux_log "WARN mods: could not put EML into the install; starting without mods"
      mods_mode="off"
    fi
    [ -n "${changes}" ] && [ "${mods_mode}" = "on" ] && flux_log "mods: $(tr '\n' ',' <<<"${changes}" | sed 's/,$//')"
  fi
  if [ "${mods_mode}" != "on" ]; then
    # No EML. Our copies leave the folder it reads; anything else there was put by hand and stays
    # (the next start with mods moves it into the library). Only our own copy of the DLL is
    # removed: a different one was put there by hand, and is left for whoever did.
    python3 "${FLUX_MODS_PY}" clear "${FLUX_MODS_RUNTIME}" >/dev/null 2>&1
    if [ -f "${g}/dbghelp.dll" ]; then
      if cmp -s "${FLUX_EML_DLL}" "${g}/dbghelp.dll"; then
        rm -f "${g}/dbghelp.dll"
      else
        flux_log "WARN mods: a dbghelp.dll that is not ours is in the install; leaving it"
      fi
    fi
  fi
  rm -rf "${FLUX_EML_LOG_DIR}"
  case "${mods_mode}" in
    on) message="Starting with $(jq -r '.active | length' "${FLUX_MODS_PLAN}") mods." ;;
    safe) message="$(sed -n 2p "${FLUX_MODS_SAFE}" 2>/dev/null). The server runs without mods until the set changes." ;;
    *) message="" ;;
  esac
  [ -d "${FLUX_MODS_DIR}" ] && python3 "${FLUX_MODS_PY}" status "${FLUX_MODS_STATUS}" "${FLUX_MODS_PLAN}" \
    "${mods_mode}" "$([ "${mods_mode}" = "on" ] && echo starting || echo running)" "${message}" "${FLUX_EML_VERSION:-unknown}" 2>/dev/null
  return 0
}

# After a generation with mods that ended before the watch could judge it (EML's panic killed
# the game rather than leaving it at a message box): the same verdict, from EML's own log.
mods_check_ended() {
  local report errors why
  [ "${mods_mode}" = "on" ] || return 0
  [ "$(head -n 1 "${FLUX_MODS_APPLIED}" 2>/dev/null)" = "${mods_fingerprint}" ] && return 0
  report="$(python3 "${FLUX_MODS_PY}" report "${FLUX_EML_LOG_DIR}" 2>/dev/null)"
  errors="$(jq -r '.errors | length' <<<"${report}" 2>/dev/null)"
  [[ "${errors}" =~ ^[1-9] ]] || return 0
  why="EML stopped the server: $(jq -r '.errors[0]' <<<"${report}" | head -c 600)"
  printf '%s\n%s\n' "${mods_fingerprint}" "${why}" >"${FLUX_MODS_SAFE}"
  python3 "${FLUX_MODS_PY}" status "${FLUX_MODS_STATUS}" "${FLUX_MODS_PLAN}" safe failed \
    "${why}. The server is starting again without mods; change or turn off the mod that failed, then restart." \
    "${FLUX_EML_VERSION:-unknown}" "${FLUX_EML_LOG_DIR}" 2>/dev/null
  printf 'mods: %s' "${why}"
}

# True while this generation is alive: the game is running, or Proton is still launching it.
# The launcher exits as soon as the game is started, and the game shows up a moment later, so
# until the game has been seen once, a generation younger than FLUX_LAUNCH_GRACE seconds counts
# as alive. Only until then: a game that has exited is gone, and holding on for the rest of the
# grace made an early `docker stop` overrun Docker's 10 s and end in SIGKILL.
generation_alive() {
  if [ -n "$(flux_game_pid)" ]; then
    game_seen=1
    return 0
  fi
  [ -n "${launcher_pid}" ] && kill -0 "${launcher_pid}" 2>/dev/null && return 0
  [ "${game_seen}" = "0" ] && [ "${terminating}" = "0" ] &&
    [ $(( $(date -u +%s) - launched_at )) -lt "${FLUX_LAUNCH_GRACE}" ]
}

start_generation() {
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"

  mods_plan
  update_server "${last_reason}" "${mods_restore}"
  case $? in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  # A stop that arrived during the Steam update: there is no world running to save, and
  # starting one now would only be killed mid-load.
  [ "${terminating}" = "1" ] && return 2
  prepare_files || return 1
  mods_apply

  flux_log "starting the server (generation ${generation}${mods_mode:+, mods ${mods_mode}})"
  launched_at="$(date -u +%s)"
  game_seen=0
  if [ "${mods_mode}" = "on" ]; then
    # EML reads `mods` and writes its log relative to the game's working directory, and Wine
    # only loads a dbghelp.dll from beside the exe when told the native one wins. A server
    # without mods starts exactly as it always has.
    (cd "${g}" && WINEDEBUG=-all WINEDLLOVERRIDES="dbghelp=native,builtin" \
      EML_LOG_FILE_PATH="${FLUX_EML_LOG_REL}" exec "${proton}" run "${g}/${FLUX_GAME_PROCESS}") &
    launcher_pid=$!
    /opt/flux/flux-modwatch.sh "${mods_fingerprint}" &
    modwatch_pid=$!
  else
    WINEDEBUG=-all "${proton}" run "${g}/${FLUX_GAME_PROCESS}" &
    launcher_pid=$!
  fi

  /opt/flux/flux-scheduler.sh &
  scheduler_pid=$!
  /opt/flux/flux-watchdog.sh &
  watchdog_pid=$!
  return 0
}

# Ends a helper script and the sleep it is waiting in, which would otherwise outlive it.
end_helper() {
  [ -n "$1" ] || return 0
  pkill -TERM -P "$1" 2>/dev/null
  kill -TERM "$1" 2>/dev/null
}

sweep_generation() {
  end_helper "${scheduler_pid}"
  end_helper "${watchdog_pid}"
  end_helper "${modwatch_pid}"
  scheduler_pid="" watchdog_pid="" modwatch_pid=""
  # Whatever Proton and Wine left behind for this generation: the game, then the prefix's
  # wineserver and every Windows service it started (services.exe, explorer.exe and the rest,
  # which otherwise pile up, one set per restart).
  flux_signal_game KILL
  WINEPREFIX="${STEAM_COMPAT_DATA_PATH}/pfx" "${wineserver}" -k 2>/dev/null
  sleep 1
  pkill -KILL -x wineserver 2>/dev/null
  pkill -KILL -f "${FLUX_WINE_SERVICES_PATTERN}" 2>/dev/null
  launcher_pid=""
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force.
wait_for_generation() {
  local asked_at=0 now
  while generation_alive; do
    sleep 1
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        flux_signal_game KILL
      fi
    fi
  done
  wait "${launcher_pid}" 2>/dev/null
  return 0
}

while true; do
  # A stop that arrived during the restart backoff: exit now rather than run a Steam update
  # that Docker will kill anyway.
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    # Nothing to run. A container that cannot install the game is the platform's problem.
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  [ -z "${reason}" ] && [ "${terminating}" = "0" ] && reason="$(mods_check_ended)"
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request"
    exit 0
  fi

  # No exit code: the only process this shell can wait on is Proton's launcher, which had
  # already exited 0 long before the game ended.
  [ -z "${reason}" ] && reason="the server ended on its own"
  last_reason="${reason}"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  # In the background and waited on: bash runs a trap only after a foreground command ends, so a
  # plain sleep here would hold a stop for the whole backoff, which is Docker's whole deadline.
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
