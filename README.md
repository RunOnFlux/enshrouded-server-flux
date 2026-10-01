# enshrouded-server-flux

The Enshrouded dedicated server image for the [Flux](https://runonflux.io/) marketplace and the
[games hub](https://runonflux.com/games/enshrouded): `runonflux/enshrouded-server-flux`.

It is built on the image the marketplace already deploys,
[sknnr/enshrouded-dedicated-server](https://github.com/jsknnr/enshrouded-server), pinned by
digest. It has the same Debian, GE-Proton, SteamCMD, `steam` user (10000:10000) and paths, so a
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

The base image's `SERVER_NAME`, `SERVER_PASSWORD`, `SERVER_SLOTS`, `PORT`, `SERVER_IP` and
`EXTERNAL_CONFIG` are not read. Edit `enshrouded_server.json` instead.

Mounts, as in the marketplace spec:

- `/home/steam/enshrouded`: the install
- `/home/steam/enshrouded/savegame`: the world
- `/home/steam/enshrouded/enshrouded_server.json`: the settings file

The supervisor's own log is `/home/steam/enshrouded/flux/flux.log`, and also goes to the
container output. It is kept off the savegame folder on purpose.

## How a stop and a restart work

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
