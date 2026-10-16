# enshrouded-server-flux

The Enshrouded dedicated server image for the [Flux](https://runonflux.io/) marketplace and the
[games hub](https://runonflux.com/games/enshrouded): `runonflux/enshrouded-server-flux`.

It is built on the image the marketplace already deploys,
[sknnr/enshrouded-dedicated-server](https://github.com/jsknnr/enshrouded-server), pinned by
digest. It has the same Debian, SteamCMD, `steam` user (10000:10000) and paths, so a
server moved onto it starts from the install, world and `enshrouded_server.json` it already has.
What it replaces is the entrypoint.

## What it changes

| | Base image | This image |
|---|---|---|
| Daily restart | None | `FLUX_RESTART_TIME`. It waits for players to leave, for up to `FLUX_RESTART_MAX_WAIT_MINUTES` |
| Updates | On container start, always with `validate` | On every start of the server, including scheduled restarts. `validate` runs on a container's first start, after a crash and after the watchdog. The daily restart skips it |
| Server ends or crashes | The container ends, and the platform has to notice | Restarted in place. The container only ends after 5 unplanned restarts in an hour (exit 42) |
| Server running but not serving | The container ended when the query port was no longer bound | Restarted in place when the port has been unbound for 3 checks, or when the server has not answered the player query for 10 minutes |
| First start on Flux | Exits with 1 after 60 s. FluxOS mounts `enshrouded_server.json` empty, so the base image watched for an empty port number. The game was up the whole time | Watches the game's process. Starts once |
| `enshrouded_server.json` | Rewritten from env on every start, through an `mv` onto the bind-mounted file that fails on Flux (`Device or resource busy`) | The games hub's Server Settings tab owns it. The image writes one key, `queryPort`, from `FLUX_QUERY_PORT`, in place |
| Port | Always 15637 | `FLUX_QUERY_PORT`: the server binds and announces that port, so several servers can share one node address |
| `docker stop` | SIGINT to the game | Same, and no restart afterwards |
| Mods | None | EML (Enshrouded Mod Loader) built in, fed from the `mods` volume, every mod checked before the start, and a safe mode when a set of mods stops the server. See [Mods](#mods) |

## Configuration

| Variable | Default | |
|---|---|---|
| `FLUX_QUERY_PORT` | empty (leave the file's port) | The one port the server uses. Written into `queryPort` before every start. On an empty file (Flux's first start) the file becomes `{"queryPort": P}` and the game fills in the rest |
| `FLUX_RESTART_TIME` | empty (off) | Daily restart, `HH:MM`, 24 hour, in `TZ` |
| `FLUX_RESTART_MAX_WAIT_MINUTES` | `60` | How long a due restart waits for the server to empty, 0 to 180. 0 restarts on time |
| `TZ` | UTC | Timezone of `FLUX_RESTART_TIME` |
| `FLUX_WATCHDOG_UNRESPONSIVE_MINUTES` | `10` | Restart a server that has not answered the player query for this long, 0 = never. Only counted after it has answered once |
| `FLUX_WATCHDOG_UNBOUND_CHECKS` / `FLUX_WATCHDOG_INTERVAL` | `3` / `30` | Restart when the query port has been unbound for this many checks, this many seconds apart |
| `SKIP_UPDATE` | empty | Any value: do not update from Steam (when the server is already installed) |
| `FLUX_STOP_GRACE` | `60` | Seconds a restart may take to save before it is forced. Docker's own stop timeout still applies to `docker stop` |
| `FLUX_RESTART_MAX_ATTEMPTS` / `FLUX_RESTART_WINDOW` | `5` / `3600` | Unplanned restarts allowed per window before the container ends with 42 |
| `FLUX_MODS_BOOT_TIMEOUT` | `1800` | Seconds a start with mods may take to open its port before the mods are blamed and the server starts without them |
| `FLUX_MODS_DISABLED` | empty | Any value: never load mods, whatever the `mods` volume holds |

The base image's `SERVER_NAME`, `SERVER_PASSWORD`, `SERVER_SLOTS`, `PORT`, `SERVER_IP` and
`EXTERNAL_CONFIG` are not read. Edit `enshrouded_server.json` instead.

Mounts, as in the marketplace spec:

- `/home/steam/enshrouded`: the install
- `/home/steam/enshrouded/savegame`: the world
- `/home/steam/enshrouded/enshrouded_server.json`: the settings file
- `/home/steam/mods`: the mods library (`m:mods:/home/steam/mods`, synced to the standby). Optional: without it the server runs as it always has

The supervisor's own log is `/home/steam/enshrouded/flux/flux.log`, and also goes to the
container output. It is kept off the savegame folder on purpose.

## How a stop and a restart work

Since 2026-10-15 (Enshrouded 1.0) the server runs under Wine, not the base image's GE-Proton:
1.0 needs the Steam client the server ships with, and Proton replaces it with its own (see the
Dockerfile). Since 2026-10-16 that Wine is Kron4ek's 10.0 staging-tkg with fsync (`WINEFSYNC=1`,
esync as the fallback): upstream Wine routes every thread wait through wineserver, and the game's
task threads made it cost half the server's CPU in the kernel. Measured on 1.0 under the fsync
build: the world loads in about 4 s, an idle server uses 0.43 cores (0.56 before) with a 0.9 ms
tick (1.9 ms), and `docker stop` saves and ends the server in about 3 s.

These were measured on 2026-10-01, on build 2278520 under GE-Proton10-26:

- **Proton's launcher exits at once.** `proton run enshrouded_server.exe` returns 0 within a
  few seconds. The server keeps running as `X:\enshrouded\enshrouded_server.exe`, so the
  supervisor watches that process, not the launcher's pid.
- **SIGINT saves.** The game switches to its Shutdown state, writes every save blob, closes the
  save container (`[savedata] Finished 'Close Container'`) and exits. That takes about a
  second, well inside Flux's 10 s stop.
- **Enshrouded cannot warn players.** It has no RCON, no admin console and no broadcast. So a
  due restart asks the server how many players are online (Steam A2S_INFO on the query port,
  `flux-a2s`). While anyone is online it checks again every minute, up to the limit, then
  restarts.
  - A server that does not answer is restarted at once: it is either loading, or hung.
- **The port is the one the server announces.** Enshrouded uses a single UDP port, `queryPort`
  (the separate game port went away in Content Update #2). Its A2S reply names that same port as
  the game port, and there is no setting to announce another one. So the published port has to be
  the bound port: `FLUX_QUERY_PORT` moves both. Checked with 41234 and 42000: bound, answering,
  announced, and the rest of the file (name, groups) untouched.
- **A restart is an update.** The supervisor runs SteamCMD before every start, so a scheduled
  restart is also how a server picks up a new game build.
- **A plain update does not repair the install.** With `enshrouded_server.kfc` deleted, a plain
  `app_update` left it missing; `validate` restored it. On the same install, validate took 30 s
  and a plain update 16 s. So everything except the daily restart validates.
- **A stop is answered at once, even during an update.** SteamCMD runs in the background and is
  waited on, so `docker stop` mid-download exits within a second, without starting the server.
- **The watchdog was checked with a frozen game.** With the game stopped (SIGSTOP), its process
  and port stay up but the query goes silent. The watchdog asked it to exit, the supervisor
  killed it after `FLUX_STOP_GRACE` and started a validated generation.
- **The time is worked out once per generation.** On a daylight saving change, the restart that
  day can be an hour early or late.

## Development

```bash
./tests/test-flux.sh
docker build -t enshrouded-server-flux:local .
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh
```

To run it by hand, the three mounts must be owned by 10000:10000. The first start downloads
about 9 GB.

## Mods

The image carries [EML](https://github.com/Brabb3l/kfc-parser), the Enshrouded Mod Loader
(GPL-3.0), pinned by version and checksum in the Dockerfile (`EML_VERSION`, now 0.1.2). EML is a
proxy `dbghelp.dll`: the game loads it, it runs each mod's Lua against the game's data, writes the
result into the install (`enshrouded_server.kfc`, keeping the original as `.kfc.bak`) and lets the
server start. Mods are server-side: players do not install anything.

**The library is the `mods` volume.** One entry per mod: a `.zip` (or a folder) with `mod.json` at
its top level. An entry ending in `.disabled` is off. The games hub's Mods tab manages it; the hub
repacks a mod downloaded from Nexus so its `mod.json` is at the top.

**Every start:**

1. `flux-mods.py plan` checks each entry the way EML would (`mod.json` present and valid JSON, the
   id `^[a-z][a-z0-9_-]*$`, a semantic version, known capabilities, valid dependency
   requirements), refuses a second mod with the same id, and drops a mod whose required
   dependency is not loaded (a Lua `require` that fails inside EML). It prints why each refused
   mod is refused, into the container log and the status file.
2. Nothing loads: mods are off. If EML changed the install before, Steam `validate`s it back
   (measured: `enshrouded_server.kfc` returns to the exact original hash), and our DLL and EML's
   backup are removed. A server that never had mods starts exactly as before.
3. Mods load: the loading ones are copied into `<install>/mods` (the folder EML reads; the
   library itself never is), `dbghelp.dll` goes beside the server, and the game starts from the
   install folder with `WINEDLLOVERRIDES="dbghelp=native,builtin"`.
4. `flux-modwatch.sh` watches that start.

**EML cannot fail quietly**, and that is what the watch is for. Any error, including a Lua error
in one mod, ends in a Rust panic whose handler opens a Windows message box; on a server with no
screen the game then never binds its port. The watch reads EML's log (`<install>/flux/eml-log`):

- an ERROR there, or no port after `FLUX_MODS_BOOT_TIMEOUT`: the set of mods is recorded as unsafe
  (`flux/mods-safe-mode`), the game is killed and started again WITHOUT mods (and validated back).
  It stays without them until the set changes, which is the only thing that can fix it. This does
  not count against the restart budget.
- the port bound: loaded, with EML's patch count.

**Status for the games hub:** `<install>/flux/mods-status.json`, rewritten on every start:
`mode` (off, on, safe), `phase`, `message`, `failedMod` (the id EML named), `applied` (patches),
and every library entry with its `state` (active, off, invalid, duplicate, missing-dependency) and
`reason`.

**Measured on 2026-10-14**, build `ea_update_08` (2026-05-11), GE-Proton10-26, EML 0.1.2: a test mod
setting `BalancingTable.playerBaseStamina` (100 to 500) loaded and applied 1 patch, and the server
was online 2 s later. A mod with `error()` in its Lua: detected in 4 s from EML's log, killed,
validated back, up without mods. A `mod.json` with id `Bad Mod`: refused before the start, the
other mods loaded.
