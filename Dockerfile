# Enshrouded dedicated server image for Flux.
#
# Built ON the image the Flux marketplace already deploys, sknnr/enshrouded-dedicated-server,
# pinned by digest: the same Debian, SteamCMD, steam user (10000:10000) and paths (Wine replaces
# its GE-Proton, see below).
# A server moved onto this image starts from the install, world and enshrouded_server.json it
# already has. What it adds is a supervisor that restarts in place, restarts on a daily
# schedule (updating from Steam each time) and never rewrites the settings file. See README.md.
#
# proton-v2.3.2 is what `latest` pointed at when this image was made (2026-10-01). Moving the
# base is a deliberate change, tested on a real server, never a side effect of a rebuild.
ARG BASE_IMAGE=sknnr/enshrouded-dedicated-server:proton-v2.3.2@sha256:c410b742812cc55723cdaa97950f94cdef1b1f8a332bceedce13da9b681c98ee
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG FLUX_IMAGE_VERSION=dev

# EML, the Enshrouded Mod Loader (github.com/Brabb3l/kfc-parser, GPL-3.0): the proxy dbghelp.dll
# the supervisor puts beside the server when the `mods` volume has mods to load. Pinned by version
# AND checksum, so a moved release tag cannot change what runs on customer servers. Moving it is a
# deliberate change, tested with real mods on a real server.
ARG EML_VERSION=0.1.2
ARG EML_DBGHELP_SHA256=7a1334fadbcf68fa3099d6757ad3e110d7196945cf3a2b102e44f451d0295dcd

# Wine, in place of the base image's GE-Proton (2026-10-15, Enshrouded 1.0). The 1.0 server asks
# Steam for SteamUtils011. Proton routes the game's Steam client through its own lsteamclient,
# and 10-26's does not know that interface, so the server stopped at "Failed to initialize
# Steamworks system...Version Mismatch". GE-Proton11-9 knows it, but the game hangs there before
# its first log line. Plain Wine loads the steamclient64.dll the server ships with (it has
# SteamUtils011) and runs 1.0. The prefix is the container's own, made on the first start. Proton
# is removed, so nothing can launch through it.
#
# Which Wine (2026-10-16): Wine 10.0 staging-tkg from Kron4ek/Wine-Builds, for its fsync and esync.
# Upstream Wine (Debian's 10.0, WineHQ staging 11) sends every event wait and SetEvent of the
# game's task threads through wineserver: an idle server made ~11,000 wineserver calls a second,
# spent 73% of its CPU in the kernel, and a customer server with 3 players logged "Bad Performance"
# every 5 s on 2.5 of its 5 cores. fsync does those waits on futexes in the game's own process.
# Measured idle on 5 vCPU: wineserver 0.25 -> 0.01 cores, kernel 0.41 -> 0.09, game tick 1.9 ->
# 0.9 ms. Newer TKG builds (10.16 on) dropped fsync/esync for ntsync, which needs /dev/ntsync, a
# device Flux cannot pass into a container. The wow64 build is 64-bit only (no i386 libraries).
# Pinned by checksum; moving it is a version AND a checksum, then a real 1.0 run.
ARG WINE_TKG_VERSION=10.0
ARG WINE_TKG_SHA256=fe9b45a6ac181c7fe6290ea83e3a6d4abb8ca08d79236ffd95ede5413a9faa80

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends xz-utils && \
    rm -rf /var/lib/apt/lists/* \
      "${STEAMCMD_PATH}/compatibilitytools.d/GE-Proton${GE_PROTON_VERSION}" \
      "${STEAMCMD_PATH}/steamapps/compatdata" && \
    pkg="wine-${WINE_TKG_VERSION}-staging-tkg-amd64-wow64" && \
    curl -fsSL -o "/tmp/${pkg}.tar.xz" \
      "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_TKG_VERSION}/${pkg}.tar.xz" && \
    echo "${WINE_TKG_SHA256}  /tmp/${pkg}.tar.xz" | sha256sum -c - && \
    tar -xJf "/tmp/${pkg}.tar.xz" -C /opt && mv "/opt/${pkg}" /opt/wine && rm "/tmp/${pkg}.tar.xz"
# mscoree/mshtml off: no Mono or Gecko installer prompt while the prefix is made.
# WINEFSYNC needs futex_waitv (Linux 5.16+, allowed by Docker's default seccomp profile); where it
# is missing Wine says so and falls back to esync (eventfd), and only then to wineserver.
ENV PATH=/opt/wine/bin:${PATH} \
    WINEPREFIX=/home/steam/.wine-enshrouded \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEFSYNC=1 \
    WINEESYNC=1 \
    GE_PROTON_VERSION=
RUN mkdir -p /opt/flux/eml && \
    curl -fsSL -o /opt/flux/eml/dbghelp.dll \
      "https://github.com/Brabb3l/kfc-parser/releases/download/v${EML_VERSION}/dbghelp.dll" && \
    echo "${EML_DBGHELP_SHA256}  /opt/flux/eml/dbghelp.dll" | sha256sum -c - && \
    printf 'EML %s, dbghelp.dll from https://github.com/Brabb3l/kfc-parser/releases/tag/v%s\nSource and licence (GPL-3.0): https://github.com/Brabb3l/kfc-parser\n' \
      "${EML_VERSION}" "${EML_VERSION}" >/opt/flux/eml/SOURCE.txt
COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-scheduler.sh scripts/flux-watchdog.sh scripts/flux-modwatch.sh scripts/flux-a2s.py scripts/flux-mods.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-a2s.py /usr/local/bin/flux-a2s
USER steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_BASE_IMAGE=${BASE_IMAGE} \
    FLUX_EML_VERSION=${EML_VERSION}

# FluxOS does not act on health; this is for anyone running the image by hand. A first start
# downloads about 9 GB, so the grace is generous.
# The game's own process, not Proton's launcher, which also has the exe in its command line.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD ["bash", "-c", "source /opt/flux/flux-lib.sh && [ -n \"$(flux_game_pid)\" ]"]

CMD ["/opt/flux/flux-entrypoint.sh"]
