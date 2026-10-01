#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and the A2S client against a fake server.
# No Docker, no Proton, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"; kill "${fake_pid:-}" 2>/dev/null' EXIT

# --- Restart time ------------------------------------------------------------------------------
check "05:00 is minute 300" "300" "$(flux_restart_minute_of_day 05:00)"
check "5:07 is minute 307" "307" "$(flux_restart_minute_of_day 5:07)"
check "23:59 is the last minute" "1439" "$(flux_restart_minute_of_day 23:59)"
check "00:08 is not octal" "8" "$(flux_restart_minute_of_day 00:08)"
check "24:00 is refused" "1" "$(status flux_restart_minute_of_day 24:00)"
check "05:60 is refused" "1" "$(status flux_restart_minute_of_day 05:60)"
check "empty means no restart" "1" "$(status flux_restart_minute_of_day '')"
check "a cron line is refused" "1" "$(status flux_restart_minute_of_day '0 5 * * *')"

check "an hour ahead" "3600" "$(flux_seconds_until 300 240 0)"
check "the seconds already past count" "3570" "$(flux_seconds_until 300 240 30)"
check "earlier today means tomorrow" "82800" "$(flux_seconds_until 300 360 0)"
check "due this very minute means tomorrow" "86370" "$(flux_seconds_until 300 300 30)"
check "exactly now means tomorrow" "86400" "$(flux_seconds_until 300 300 0)"

# --- Waiting for players -----------------------------------------------------------------------
check "max wait defaults to 60" "60" "$(flux_max_wait_minutes '')"
check "max wait is capped at 180" "180" "$(flux_max_wait_minutes 999)"
check "max wait of 0 is allowed" "0" "$(flux_max_wait_minutes 0)"
check "max wait 08 is not octal" "8" "$(flux_max_wait_minutes 08)"
check "a non-number max wait is 60" "60" "$(flux_max_wait_minutes soon)"

check "nobody online restarts" "restart" "$(flux_restart_decision 0 0 60)"
check "players online wait" "wait" "$(flux_restart_decision 3 0 60)"
check "still waiting at 59" "wait" "$(flux_restart_decision 1 59 60)"
check "the wait runs out" "restart" "$(flux_restart_decision 1 60 60)"
check "max wait 0 never waits" "restart" "$(flux_restart_decision 5 0 0)"
check "no answer restarts" "restart" "$(flux_restart_decision '' 0 60)"
check "garbage restarts" "restart" "$(flux_restart_decision 'x' 0 60)"

# --- Watchdog ----------------------------------------------------------------------------------
# The kernel's own format, header line included. 3D15 is 15637.
cat >"${tmp}/udp" <<'T'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  412: 00000000:3D15 00000000:0000 07 00000000:00000000 00:00000000 00000000 10000        0 1234 2 0000000000000000 0
  500: 0100007F:A3D1 00000000:0000 07 00000000:00000000 00:00000000 00000000 10000        0 1235 2 0000000000000000 0
T
cat >"${tmp}/udp6" <<'T'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
   12: 00000000000000000000000000000000:3D16 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000 10000        0 99 2 0000000000000000 0
T
: >"${tmp}/udp-empty"
check "the query port is bound" "0" "$(status flux_port_bound 15637 "${tmp}/udp" "${tmp}/udp6")"
check "bound on IPv6 only" "0" "$(status flux_port_bound 15638 "${tmp}/udp" "${tmp}/udp6")"
check "a port nobody has" "1" "$(status flux_port_bound 27015 "${tmp}/udp" "${tmp}/udp6")"
check "a remote port does not count" "1" "$(status flux_port_bound 0 "${tmp}/udp-empty")"
check "41937 (A3D1) is not 15637 (3D15)" "1" "$(status flux_port_bound 15637 "${tmp}/udp6" "${tmp}/udp-empty")"

check "a healthy server" "ok" "$(flux_watchdog_verdict 0 0 3 600)"
check "port gone two checks" "ok" "$(flux_watchdog_verdict 2 0 3 600)"
check "port gone three checks" "unbound" "$(flux_watchdog_verdict 3 0 3 600)"
check "silent nine minutes" "ok" "$(flux_watchdog_verdict 0 540 3 600)"
check "silent ten minutes" "unresponsive" "$(flux_watchdog_verdict 0 600 3 600)"
check "the silence rule turned off" "ok" "$(flux_watchdog_verdict 0 99999 3 0)"

# --- Update validation -------------------------------------------------------------------------
check "a container's first start validates" "0" "$(status flux_update_validates '')"
check "a crash validates" "0" "$(status flux_update_validates 'the server ended on its own')"
check "the watchdog validates" "0" "$(status flux_update_validates 'watchdog: the query port 15637 has not been bound for 3 checks')"
check "the daily restart does not" "1" "$(status flux_update_validates 'scheduled restart at 05:00')"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "no history" "" "$(flux_restarts_in_window 1000 200)"
check "a scheduled restart is not counted" "1" "$(status flux_restart_counts 'scheduled restart at 05:00')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own')"
check "a watchdog restart is counted" "0" "$(status flux_restart_counts 'watchdog: the server has not answered the player query for 10 minutes')"

# --- The game's process -------------------------------------------------------------------------
matches() { printf '%s\n' "$1" | grep -cE "${FLUX_GAME_PATTERN}"; }
check "Wine's game process matches" "1" "$(matches 'X:\enshrouded\enshrouded_server.exe')"
check "Proton's launcher does not" "0" "$(matches '/home/steam/steamcmd/compatibilitytools.d/GE-Proton10-26/proton run /home/steam/enshrouded/enshrouded_server.exe')"
check "the image's own entrypoint does not" "0" "$(matches '/bin/bash /home/steam/entrypoint.sh enshrouded_server.exe')"
check "Wine's services match the sweep" "1" "$(printf '%s\n' 'C:\windows\system32\services.exe' | grep -cE "${FLUX_WINE_SERVICES_PATTERN}")"
check "the game is not one of them" "0" "$(printf '%s\n' 'X:\enshrouded\enshrouded_server.exe' | grep -cE "${FLUX_WINE_SERVICES_PATTERN}")"
check "a lookalike name does not" "0" "$(matches 'X:\enshrouded\enshrouded_serverXexe')"

# --- enshrouded_server.json --------------------------------------------------------------------
: >"${tmp}/empty.json"
printf '{"queryPort": 16000, "name": "x"}' >"${tmp}/ok.json"
printf '{"name": "x"}' >"${tmp}/noport.json"
printf '{"queryPort": "abc"}' >"${tmp}/badport.json"
printf '{"name": ' >"${tmp}/broken.json"
check "a missing file" "missing" "$(flux_config_state "${tmp}/nope.json")"
check "FluxOS's empty file mount" "empty" "$(flux_config_state "${tmp}/empty.json")"
check "a valid file" "ok" "$(flux_config_state "${tmp}/ok.json")"
check "a broken file" "invalid" "$(flux_config_state "${tmp}/broken.json")"
check "the port the file sets" "16000" "$(flux_query_port "${tmp}/ok.json")"
check "no port in the file" "15637" "$(flux_query_port "${tmp}/noport.json")"
check "a port that is not a number" "15637" "$(flux_query_port "${tmp}/badport.json")"
check "an empty file" "15637" "$(flux_query_port "${tmp}/empty.json")"
check "no file" "15637" "$(flux_query_port "${tmp}/nope.json")"

# --- A2S client, against a fake Steam query server ---------------------------------------------
cat >"${tmp}/fake.py" <<'PY'
import socket, struct, sys
mode, players = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1], flush=True)
H = b"\xff\xff\xff\xff"
info = (H + b"\x49\x11" + b"Enshrouded Server\x00" + b"map\x00" + b"enshrouded\x00"
        + b"Enshrouded\x00" + struct.pack("<h", 0) + bytes([players, 16, 0]) + b"dw\x01")
while True:
    data, addr = s.recvfrom(4096)
    if mode == "silent":
        continue
    if mode == "garbage":
        s.sendto(b"hello", addr)
    elif mode == "challenge" and not data.endswith(b"\x01\x02\x03\x04"):
        s.sendto(H + b"\x41\x01\x02\x03\x04", addr)
    else:
        s.sendto(info, addr)
PY
fake() { # mode, players -> starts the fake, sets ${port}
  kill "${fake_pid:-}" 2>/dev/null
  rm -f "${tmp}/port"
  python3 "${tmp}/fake.py" "$1" "$2" >"${tmp}/port" &
  fake_pid=$!
  for _ in $(seq 50); do [ -s "${tmp}/port" ] && break; sleep 0.1; done
  port="$(cat "${tmp}/port")"
}
fake plain 3
check "players from a plain reply" "3" "$(python3 scripts/flux-a2s.py "${port}")"
fake challenge 7
check "players after a challenge" "7" "$(python3 scripts/flux-a2s.py "${port}")"
fake plain 0
check "an empty server" "0" "$(python3 scripts/flux-a2s.py "${port}")"
fake garbage 0
check "a reply that is not A2S exits 2" "2" "$(status python3 scripts/flux-a2s.py "${port}")"
fake silent 0
check "no reply exits 1" "1" "$(status python3 scripts/flux-a2s.py "${port}")"
kill "${fake_pid}" 2>/dev/null

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
