#!/bin/bash
# Watches a start WITH MODS until the server is up, started by the supervisor for that
# generation only.
#
# EML has no way to fail quietly: a mod it cannot load or run ends in a panic whose handler opens
# a Windows message box, and on a server with no screen nobody clicks it. The game process stays
# (or dies) without ever binding its port, and the watchdog never starts counting, because it only
# judges a server that has served once. So this does:
#
#   - an ERROR in EML's log, or no bound port after FLUX_MODS_BOOT_TIMEOUT seconds: the mods
#     stopped the server. The set is remembered as unsafe (the next start goes without it, see
#     flux_mods_mode), the status file says why, and the game is killed (a message box does not
#     answer SIGINT). The supervisor starts the next generation, which also puts Steam's files
#     back, since EML may have patched half of them.
#   - the port bound: the mods loaded. The set is remembered as the one EML patched the install
#     for, and the status file carries EML's patch count.
#
#   $1 = the plan's fingerprint for this start
set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

fingerprint="${1:-}"
interval="${FLUX_MODS_WATCH_INTERVAL:-5}"
timeout="${FLUX_MODS_BOOT_TIMEOUT:-1800}"
[[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=1800
started="$(date -u +%s)"

status() { # mode phase message
  python3 "${FLUX_MODS_PY}" status "${FLUX_MODS_STATUS}" "${FLUX_MODS_PLAN}" "$1" "$2" "$3" \
    "${FLUX_EML_VERSION:-unknown}" "${FLUX_EML_LOG_DIR}" 2>/dev/null
}

while :; do
  sleep "${interval}"
  # A stop or restart already under way is not ours to judge.
  [ -f "${FLUX_RESTART_MARKER}" ] && exit 0

  report="$(python3 "${FLUX_MODS_PY}" report "${FLUX_EML_LOG_DIR}" 2>/dev/null)"
  errors="$(jq -r '.errors | length' <<<"${report}" 2>/dev/null)"
  [[ "${errors}" =~ ^[0-9]+$ ]] || errors=0
  bound=0
  flux_port_bound "$(flux_query_port "${FLUX_CONFIG}")" && bound=1
  elapsed=$(($(date -u +%s) - started))

  case "$(flux_mods_boot_verdict "${elapsed}" "${timeout}" "${errors}" "${bound}")" in
    wait) continue ;;
    loaded)
      printf '%s\n' "${fingerprint}" >"${FLUX_MODS_APPLIED}"
      : >"${FLUX_MODS_LOADED_MARKER}"
      rm -f "${FLUX_MODS_SAFE}"
      applied="$(jq -r '.applied // empty' <<<"${report}" 2>/dev/null)"
      if [ "${applied}" = "1" ]; then
        message="EML loaded the mods and applied 1 change to the game data."
      elif [ -n "${applied}" ]; then
        message="EML loaded the mods and applied ${applied} changes to the game data."
      else
        message="EML loaded the mods; the game data already carried their changes."
      fi
      # Up, so nothing it logged stopped it; still worth a look, and the status file lists them.
      [ "${errors}" -gt 0 ] && message="${message} EML also logged ${errors} error(s)."
      flux_log "mods: ${message}"
      status on running "${message}"
      exit 0
      ;;
    failed)
      if [ "${errors}" -gt 0 ]; then
        # One line: the safe-mode file is read by line, and EML's Lua errors carry a traceback.
        why="$(jq -r '.errors[0]' <<<"${report}" 2>/dev/null | flux_one_line | head -c 600)"
        why="EML stopped the server: ${why}"
      else
        why="the server did not come up within $((timeout / 60)) minutes with mods on"
      fi
      [ -f "${FLUX_RESTART_MARKER}" ] && exit 0
      printf '%s\n%s\n%s\n' "${fingerprint}" "${why}" "${FLUX_EML_VERSION:-}" >"${FLUX_MODS_SAFE}"
      status safe failed "${why}. The server is starting again without mods; change or turn off the mod that failed, then restart."
      printf 'mods: %s' "${why}" >"${FLUX_RESTART_MARKER}"
      flux_log "mods: ${why}; starting again without mods"
      flux_signal_game KILL
      exit 0
      ;;
  esac
done
