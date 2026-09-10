# CS2 dedicated-server runtime image.
#
# Unlike Pterodactyl (a full game copy per server) this image ships NO game files
# and NO SteamCMD. The ~30GB CS2 install is mounted read-only from the node's
# master hostPath (kept fresh by the updater DaemonSet); the entrypoint symlinks
# it into a writable per-server scratch area at startup.
#
# The ONE Steam file it does need is steamclient.so: CS2 initialises the
# Steamworks gameserver SDK at map load (even in LAN mode) and hard-fails without
# it. It isn't part of the game install, so we grab it from SteamCMD in a
# throwaway build stage and copy just that lib into the final image.
#
# CS2 is 64-bit only (no lib32 / no srcds_run, unlike the CS:GO-era image this
# is derived from).

# --- build stage: produce steamclient.so (discarded; not in the final image) ---
FROM debian:trixie-slim AS steam
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl lib32gcc-s1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /steamcmd \
    && curl -sqL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zxf - -C /steamcmd \
    && /steamcmd/steamcmd.sh +quit \
    && test -f /steamcmd/linux64/steamclient.so   # fail the build loudly if it's missing

# --- final runtime image ---
FROM debian:trixie-slim

# Runtime deps: certs for HTTPS, rsync for custom-file sync, tini as a minimal
# init so signals reach the game process, and curl/jq/unzip so server-type
# setup steps (mod installs) can download + unpack plugins on start.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        rsync \
        tini \
        curl \
        jq \
        unzip \
        libncurses6 \
        libtinfo6 \
        libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user. UID matches the operator/pod securityContext.
RUN useradd --create-home --uid 10000 --shell /usr/sbin/nologin cs2
ENV HOME=/home/cs2

# Baked-in custom files (server.cfg, ESL match configs, ...) live here and are
# rsync'd over the symlinked game tree at startup so they can be layered on top
# of the read-only master without mutating it.
COPY custom-files/ /usr/cs2/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# steamclient.so at the exact path CS2's Steamworks SDK looks for. Copy the whole
# linux64 dir so steamclient.so finds its sibling libs.
COPY --from=steam /steamcmd/linux64/ /home/cs2/.steam/sdk64/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /opt/mounts/csgo /opt/mounts/pod \
    && chown -R cs2:cs2 /home/cs2 /usr/cs2

USER cs2
WORKDIR /home/cs2

# Ports are informational; the operator publishes the allocated port via
# hostPort. CS2 game (udp) + RCON (tcp) share the port; GOTV is separate.
EXPOSE 27015/udp 27015/tcp 27020/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
