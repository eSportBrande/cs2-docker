#!/usr/bin/env bash
#
# CS2 dedicated-server entrypoint.
#
# Realises the master + scratch split (ported from the CS:GO-era docker-csgo
# image to CS2's game/ layout):
#
#   MASTER (read-only, shared, ~30GB)  ->  mounted at $CSGO_MASTER_HOST_VOLUME
#       $CSGO_MASTER_HOST_VOLUME/current -> <buildid>/   (atomic symlink from the updater)
#   SCRATCH (writable, per-server)      ->  mounted at $CSGO_SCRATCH_HOST_VOLUME
#
# We build a working tree at $HOME/server where the large, static engine + game
# content is symlinked from the read-only master and the writable bits
# (cfg, addons, logs, demos, console log) are real directories in scratch. This
# means one shared copy of the game serves every server without duplication and
# without any server being able to mutate the master.
#
# Every server binding: the operator injects CSGO_PORT (the allocated external
# port) so the game binds the same port it is reachable on — required for public
# GSLT servers.
set -euo pipefail

log() { echo "[entrypoint] $*"; }
fail() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ---- required inputs -------------------------------------------------------
: "${CSGO_MASTER_HOST_VOLUME:?master volume mount path is required}"
: "${CSGO_SCRATCH_HOST_VOLUME:?scratch volume mount path is required}"

# A stable per-server id for the scratch subdir. The operator sets POD_NAME via
# the downward API; fall back to hostname.
SERVER_ID="${RUSHB_SERVER_ID:-${POD_NAME:-$(hostname)}}"
[ -n "$SERVER_ID" ] || fail "could not determine SERVER_ID"

POD_BASE="$HOME/server"                       # container working tree
POD_GAME="$POD_BASE/game"                      # CS2 'game' dir the server runs from
SCRATCH_DIR="$CSGO_SCRATCH_HOST_VOLUME/$SERVER_ID"
CUSTOM_FILES_DIR="${CSGO_CUSTOM_FILES_DIR:-/usr/cs2}"

# ---- resolve the master build via the atomic 'current' symlink -------------
MASTER_CURRENT="$CSGO_MASTER_HOST_VOLUME/current"
for _ in $(seq 1 30); do
  [ -e "$MASTER_CURRENT" ] && break
  log "waiting for master 'current' symlink at $MASTER_CURRENT ..."
  sleep 2
done
[ -e "$MASTER_CURRENT" ] || fail "master 'current' not present; is the updater running on this node?"
MASTER_DIR="$(readlink -f "$MASTER_CURRENT")"
[ -d "$MASTER_DIR/game" ] || fail "master build at $MASTER_DIR has no game/ dir"
log "using master build: $MASTER_DIR"

# ---- build the working tree (symlink master, keep writable in scratch) -----
mkdir -p "$SCRATCH_DIR" "$POD_BASE"
rm -rf "$POD_GAME"
mkdir -p "$POD_GAME"

# Top-level of 'game' (core, engine ..., plus the 'csgo' content dir): the
# static engine directories are symlinked from master; 'csgo' is handled below
# because it holds both static content (maps/pak) and writable state, and 'bin'
# is handled below because the cs2 binary must be a real file (see there).
for entry in "$MASTER_DIR"/game/*; do
  name="$(basename "$entry")"
  if [ "$name" = "csgo" ] || [ "$name" = "bin" ]; then
    continue
  fi
  ln -snf "$entry" "$POD_GAME/$name"
done

# The 'bin' dir: real directories with per-file symlinks, and the cs2 binary as
# a REAL COPY (151K launcher). The engine derives its root — and thus EVERY
# write path (round backups, boot.vcfg, logs) — from realpath(/proc/self/exe).
# If the binary resolves through a symlink into the read-only master, all
# engine writes target the master and fail ("Failed to write backup_round01.txt").
# Proven with strace: symlinked exe -> writes at master; real exe -> writes in
# this tree (through the csgo symlink into the writable scratch).
mkdir -p "$POD_GAME/bin/linuxsteamrt64"
for entry in "$MASTER_DIR"/game/bin/*; do
  name="$(basename "$entry")"
  if [ "$name" = "linuxsteamrt64" ]; then
    continue
  fi
  ln -snf "$entry" "$POD_GAME/bin/$name"
done
for entry in "$MASTER_DIR"/game/bin/linuxsteamrt64/*; do
  ln -snf "$entry" "$POD_GAME/bin/linuxsteamrt64/$(basename "$entry")"
done
rm -f "$POD_GAME/bin/linuxsteamrt64/cs2"
cp "$MASTER_DIR/game/bin/linuxsteamrt64/cs2" "$POD_GAME/bin/linuxsteamrt64/cs2"
[ -f "$POD_GAME/bin/linuxsteamrt64/cs2" ] && [ ! -L "$POD_GAME/bin/linuxsteamrt64/cs2" ] \
  || fail "cs2 binary was not copied as a real file"

# The 'csgo' content dir: create a real dir in scratch, symlink static content
# from master, and keep writable subdirs (cfg/addons/logs/demos/replays) real.
POD_CSGO="$POD_GAME/csgo"
SCRATCH_CSGO="$SCRATCH_DIR/csgo"
mkdir -p "$SCRATCH_CSGO"
ln -snf "$SCRATCH_CSGO" "$POD_CSGO"

# Writable top-level entries live in scratch; everything else in master/csgo is
# symlinked read-only. (Workshop map downloads land under maps/workshop — if you
# use workshop maps, add "maps" here and symlink its static children instead.)
WRITABLE="cfg addons logs demos replays console.log"
is_writable() {
  for w in $WRITABLE; do [ "$1" = "$w" ] && return 0; done
  return 1
}
for entry in "$MASTER_DIR"/game/csgo/*; do
  name="$(basename "$entry")"
  if is_writable "$name"; then
    continue
  fi
  ln -snf "$entry" "$SCRATCH_CSGO/$name"
done
mkdir -p "$SCRATCH_CSGO/cfg" "$SCRATCH_CSGO/addons" "$SCRATCH_CSGO/logs" "$SCRATCH_CSGO/demos"

# gameinfo.gi must be a REAL file in the writable scratch csgo, not a symlink to
# master: Source 2 derives the mod's writable base from the real path of
# gameinfo.gi, so if it points into the read-only master, per-round backups
# (backup_roundNN.txt) and similar writes fail with "Failed to write ...". Copy
# it (removing the symlink first so we don't write through it into master).
for gi in "$MASTER_DIR"/game/csgo/gameinfo*.gi; do
  [ -e "$gi" ] || continue
  dst="$SCRATCH_CSGO/$(basename "$gi")"
  rm -f "$dst"
  cp "$gi" "$dst"
done

# Seed cfg from master (per-file symlinks so custom cfg can override) then layer
# our baked-in custom files on top without touching the master.
if [ -d "$MASTER_DIR/game/csgo/cfg" ]; then
  for cfg in "$MASTER_DIR"/game/csgo/cfg/*; do
    ln -snf "$cfg" "$SCRATCH_CSGO/cfg/$(basename "$cfg")"
  done
fi
if [ -d "$CUSTOM_FILES_DIR" ]; then
  log "syncing custom files from $CUSTOM_FILES_DIR"
  rsync -a --no-perms --no-owner --no-group "$CUSTOM_FILES_DIR"/ "$POD_CSGO"/ || true
fi

# ---- assemble the launch command -------------------------------------------
# CS2 dedicated server binary (64-bit). The exact runtime wiring (Steam Linux
# Runtime) must be validated on a real node — see README.
CS2_BIN="$POD_GAME/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || fail "cs2 binary not found/executable at $CS2_BIN (verify CS2 install layout)"

PORT="${CSGO_PORT:-27015}"
args=(
  -dedicated -console -usercon
  +ip "${CSGO_IP:-0.0.0.0}"
  -port "$PORT"
  +game_type "${CSGO_GAME_TYPE:-0}"
  +game_mode "${CSGO_GAME_MODE:-1}"
  +map "${CSGO_MAP:-de_dust2}"
)
[ -n "${CSGO_MAX_PLAYERS:-}" ] && args+=( +sv_visiblemaxplayers "$CSGO_MAX_PLAYERS" )
[ -n "${CSGO_HOSTNAME:-}" ]    && args+=( +hostname "$CSGO_HOSTNAME" )

# GSLT: required for public servers; without it, run LAN-only.
if [ -n "${CSGO_GSLT:-}" ]; then
  args+=( +sv_setsteamaccount "$CSGO_GSLT" )
else
  log "no CSGO_GSLT set -> LAN only (+sv_lan 1)"
  args+=( +sv_lan 1 )
fi

# RCON: drive the password ONLY from env (never from a cfg that hardcodes it).
args+=( +rcon_password "${CSGO_RCON_PASSWORD:?RCON password required}" )

# GOTV.
if [ "${CSGO_TV_ENABLE:-false}" = "true" ]; then
  args+=( +tv_enable 1 +tv_port "${CSGO_TV_PORT:-27020}" )
fi

# Free-form passthrough.
# shellcheck disable=SC2206
[ -n "${CSGO_PARAMS:-}" ] && args+=( ${CSGO_PARAMS} )

# CS2's server module (game/csgo/bin/linuxsteamrt64/libserver.so) depends on
# engine libs like libv8.so that live in game/bin/linuxsteamrt64 — a different
# directory not on libserver.so's RUNPATH. Launching the binary directly (rather
# than via CS2's own launcher) means we must put those dirs on the loader path,
# or startup dies with "libserver.so: libv8.so: cannot open shared object file".
export LD_LIBRARY_PATH="$POD_GAME/bin/linuxsteamrt64:$POD_GAME/csgo/bin/linuxsteamrt64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$POD_GAME"
log "launching cs2 on port $PORT (map ${CSGO_MAP:-de_dust2})"
exec "$CS2_BIN" "${args[@]}"
