# Enshrouded dedicated server image for Flux.
#
# Built ON the image the Flux marketplace already deploys, sknnr/enshrouded-dedicated-server,
# pinned by digest: the same Debian, GE-Proton, SteamCMD, steam user (10000:10000) and paths.
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

USER root
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
