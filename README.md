# cs2-docker

CS2 dedicated-server runtime image for the GaaS platform, used with GaaS and Kubernetes.

This image ships **no game files and no SteamCMD**. The ~30GB CS2 install is mounted **read-only** from the node's master hostPath (`$CSGO_MASTER_HOST_VOLUME`, kept fresh by the updater DaemonSet), and `entrypoint.sh`  builds a per-server working tree where:

- large static engine/game content is **symlinked** from the read-only master
- writable state (`cfg`, `addons`, `logs`, `demos`, `replays`, `console.log`)   lives in the per-server **scratch** volume (`$CSGO_SCRATCH_HOST_VOLUME/$SERVER_ID`)

One shared copy of the game serves every Kubernetes Worker Node, and no server can mutate the master. The master build is selected via  `$CSGO_MASTER_HOST_VOLUME/current` symlink written by the updater.

## Environment

| Var | Purpose |
|-----|---------|
| `CSGO_MASTER_HOST_VOLUME` | mount of the read-only master (has `current` -> `<build>/`) |
| `CSGO_SCRATCH_HOST_VOLUME` | mount of the writable per-server scratch root |
| `POD_NAME` | per-server id for the scratch subdir (downward API) |
| `CSGO_PORT` | **allocated** external port; the game binds this (injected by the operator via `${port:game}`) |
| `CSGO_RCON_PASSWORD` | RCON password (from a Secret) — required |
| `CSGO_GSLT` | Steam game-server login token; omitted → LAN-only (`+sv_lan 1`) |
| `CSGO_MAP`, `CSGO_GAME_TYPE`, `CSGO_GAME_MODE`, `CSGO_HOSTNAME`, `CSGO_MAX_PLAYERS` | match settings |
| `CSGO_TV_ENABLE`, `CSGO_TV_PORT` | GOTV |
| `CSGO_PARAMS` | free-form passthrough |

## Build

```sh
docker build -t registry.esb.club/gaas-cs2:latest .
```
