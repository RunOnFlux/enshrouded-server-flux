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

USER root
COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-scheduler.sh scripts/flux-watchdog.sh scripts/flux-a2s.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-a2s.py /usr/local/bin/flux-a2s
USER steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_BASE_IMAGE=${BASE_IMAGE}

# FluxOS does not act on health; this is for anyone running the image by hand. A first start
# downloads about 9 GB, so the grace is generous.
# The game's own process, not Proton's launcher, which also has the exe in its command line.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD ["bash", "-c", "source /opt/flux/flux-lib.sh && [ -n \"$(flux_game_pid)\" ]"]

CMD ["/opt/flux/flux-entrypoint.sh"]
