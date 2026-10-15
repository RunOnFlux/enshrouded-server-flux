# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Enshrouded dedicated server for Flux,
`runonflux/enshrouded-server-flux`. It is built ON `sknnr/enshrouded-dedicated-server`, pinned by
digest in the Dockerfile, and replaces only its entrypoint. Same family as
`~/work/vrising-server-flux` and `~/work/palworld-server-flux`; read them for the patterns
this one follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`. The game runs as a child, and a finished generation is followed by the
next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t enshrouded-server-flux:local .
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Each generation runs a SteamCMD update, checks the folder
  and settings file, then launches `wine Z:\...\enshrouded_server.exe` and the scheduler.
  SIGTERM/SIGINT become SIGINT to the game.
- `scripts/flux-scheduler.sh`: the daily restart (`FLUX_RESTART_TIME`). It waits for players to
  leave.
- `scripts/flux-watchdog.sh`: restarts a server whose query port is gone, or that has stopped
  answering the player query.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly. Every decision takes its inputs as arguments.
- `scripts/flux-a2s.py`: the player count over Steam A2S_INFO, `flux-a2s` on the PATH.
- `scripts/flux-mods.py`: EML mods: `plan` (check the library as EML would), `sync`/`clear` (the
  folder EML reads), `adopt`, `report` (EML's log), `status` (the file the hub reads).
- `scripts/flux-modwatch.sh`: watches a start with mods; an EML error or no port means safe mode.

## Things that will bite you

- **Plain Wine, not Proton (since 2026-10-15).** Enshrouded 1.0 asks Steam for SteamUtils011.
  Under GE-Proton10-26 the server stops at `Failed to initialize Steamworks system...Version
  Mismatch` (Proton swaps in its own lsteamclient, which does not know it); under GE-Proton11-9 it
  hangs before its first log line. Plain Wine uses the steamclient64.dll the server ships with.
  Do not move back to Proton without running 1.0 to `Switching state ... to Run` first.
- **The launcher can exit while the game runs.** The game runs as
  `Z:\home\steam\enshrouded\enshrouded_server.exe` (it was `X:\enshrouded\...` under Proton).
  Watch `flux_game_pid`, never the launcher's pid. The launcher's own command line also contains
  `enshrouded_server.exe`, so a bare `pgrep -f enshrouded_server.exe` matches the wrong process.
  Match the drive letter (`FLUX_GAME_PATTERN`).
- **Never write `enshrouded_server.json` beyond `queryPort`.** The games hub's Server Settings tab
  owns it; the only key the image writes is the port from `FLUX_QUERY_PORT` (the hub rolls a random
  port per server, and the game announces the port it binds, so outside and inside must match). FluxOS
  mounts it as an empty file; on that first start the game writes its own defaults, including
  a random password for the Default group.
- **`mv` onto the settings file fails** (it is a bind-mounted file: `Device or resource busy`).
  If a write is ever needed, write in place (`cat tmp > file`).
- **Enshrouded has no RCON.** Nothing can message players. The scheduler waits for an empty
  server instead (A2S), and restarts anyway after the limit.
- **Wine's services pile up** (services.exe, explorer.exe and so on: one set per generation)
  unless the sweep kills the prefix's wineserver and them.
- **The games hub depends on these paths**: the install, `savegame/` (a `g:` synced volume) and
  the settings file. Our log is in `flux/` on the install volume, never in `savegame/`.
- **A plain `app_update` does not repair a damaged install**, only `validate` does. Keep the
  daily restart cheap, and keep validate everywhere else (`flux_update_validates`).
- **Anything long in PID 1 must run in the background and be waited on** (SteamCMD, sleeps):
  bash runs the stop trap only between commands.
- **Flux stops a container with Docker's default 10 seconds.** SIGINT saves in about 1 s.
  Anything added to the stop path has to fit in that.
- **EML panics into a message box.** Any mod error (bad `mod.json`, Lua error) stops the game
  before it binds its port, silently. Never hand EML anything `flux-mods.py plan` refused, and keep
  the safe mode: an EML error in its log, or no port in time, means start again without mods.
- **EML writes into the install.** Taking mods off is not enough to undo them: Steam `validate`
  puts `enshrouded_server.kfc` back (`flux_mods_restore_needed`). Keep that, or a server keeps
  playing with mods its owner removed.
- **The library (`/home/steam/mods`) is never EML's folder.** EML reads `<install>/mods`, which the
  supervisor rebuilds; `.flux-synced.json` there lists our copies so they are never adopted back.
- **Moving EML** is a version AND a checksum in the Dockerfile, then a real test: the README's Mods
  section has the one that was run.
