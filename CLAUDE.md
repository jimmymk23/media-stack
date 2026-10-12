# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker Compose definition of a self-hosted media stack (gluetun VPN, qBittorrent, Prowlarr, Radarr, Sonarr, Seerr, Jellyfin, plus add-ons FlareSolverr, Recyclarr, Bazarr, Unpackerr, Maintainerr, and optional Recommendarr). There is no application code, build, or test suite — the deliverable is `docker-compose.yml` plus optional reverse-proxy files (`docker-compose-nginx.yml` + `nginx.conf`, or `docker-compose-traefik.yml`).

This is a personal fork of `navilg/media-stack`, running on macOS (Docker Desktop) with the VPN **enabled** and media stored on an external SSD. The fork's local changes (VPN on, `DATA_ROOT` bind mounts, `UMASK`, gluetun WireGuard/port-forwarding options) diverge from upstream, so the README's setup steps are partly stale — see "README drift" below.

## Commands

```bash
# One-time: external network the stack attaches to (must exist before `up`)
docker network create --subnet 172.20.0.0/16 mynetwork

# Validate config / see resolved values from .env (the closest thing to a "test")
docker compose --profile vpn config

# Start / apply compose or .env changes (recreates only changed containers)
docker compose --profile vpn up -d
COMPOSE_PROFILES=vpn,recommendarr docker compose up -d   # with Recommendarr
# In internal/archive mode use ./mediactl up instead: plain `docker compose up -d` recreates
# containers on the .env DATA_ROOT and drops the archive mount.

# Preferred: start in the right storage mode for whichever drives are mounted
./mediactl up                 # main (SSD) / internal fallback, + archive if mounted
./mediactl stop [--down]      # stop the stack (all profiles); --down removes containers
./mediactl dashboard          # live view (drives, containers, VPN IP); --once for a single frame
./mediactl status             # drives, free space, running mode, pending sync
./mediactl sync [--yes]       # move internal-drive media to the SSD (dry run by default)
./mediactl init-archive       # one-time: archive root folders in Radarr/Sonarr/Jellyfin
./mediactl archive [--yes] [--all] [--remove-torrents] TITLE...
./mediactl restore [--yes] [--all] TITLE...
bash tests/run.sh             # mediactl unit tests (stubbed docker/curl)

# Check status, VPN health, and that torrent traffic exits via the VPN
docker compose --profile vpn ps
docker logs vpn
docker exec qbittorrent curl -s https://ipinfo.io/ip    # must NOT be the host's public IP
```

Running `docker compose` **without a profile deploys nothing** — every service is gated by `vpn`, `no-vpn`, or `recommendarr`. This is deliberate upstream, to prevent accidentally running without a VPN.

## Architecture

**VPN toggle is done by commenting/uncommenting lines, not by profile alone.** For VPN mode, `qbittorrent` and `prowlarr` use `network_mode: service:vpn` + `depends_on: vpn (service_healthy)`, and their published ports move onto the `vpn` service. Inline comments in `docker-compose.yml` mark which lines to flip for each mode; keep both variants intact when editing.

**Networking consequences of VPN mode** (the non-obvious part):
- qBittorrent and Prowlarr share gluetun's network namespace; gluetun's firewall is the kill switch, so they have no internet if the tunnel drops.
- Other containers reach them via the `vpn` hostname: qBittorrent at `vpn:5080`, Prowlarr at `vpn:9696`.
- Prowlarr *cannot* resolve other container names, so Radarr and Sonarr get static IPs on `mynetwork` (`RADARR_STATIC_CONTAINER_IP`, `SONARR_STATIC_CONTAINER_IP`) and Prowlarr's app config points at those IPs. Pick IPs high in the subnet (e.g. `.100`, `.101`): Docker hands out low addresses dynamically to other containers first, and a clash leaves the container stuck in "Created" with `Address already in use`.
- Containers not behind the VPN (Radarr, Sonarr, Seerr, Jellyfin) talk to each other by service name on `mynetwork`.

**Add-on services.** Recyclarr, Bazarr, Unpackerr and Maintainerr are in the `vpn`/`no-vpn` profiles (so `mediactl up` starts them) and sit on `mynetwork`, reaching Radarr/Sonarr by service name. Recyclarr and Unpackerr read `RADARR_API_KEY`/`SONARR_API_KEY` from `.env` (the same keys `mediactl` uses). FlareSolverr is `vpn`-profile only and uses `network_mode: service:vpn` like Prowlarr, so Prowlarr reaches it at `http://localhost:8191/`. Bazarr mounts only `media` (plus `/data/archive` via `docker-compose.archive.yml`); Unpackerr mounts only `torrents`. Paths must stay identical to Radarr/Sonarr's (`/data/media/...`, `/data/torrents/...`) or imports and subtitle lookups break. Maintainerr replaces the old commented-out cleanmyarr block. App-side setup is in the README ("Configure the add-ons").

**Storage layout (hardlink-friendly, TRaSH-style).** One host directory, `DATA_ROOT` (default `/Volumes/MediaServer/data`, the external SSD), holds `torrents/{movies,tv,...}` and `media/{movies,tv,...}`:
- Radarr and Sonarr mount all of `DATA_ROOT` at `/data`, so imports from `/data/torrents/*` into `/data/media/*` are hardlinks on the same filesystem, not copies. Keep it that way; splitting these into separate mounts breaks hardlinking.
- qBittorrent mounts only `torrents` at `/data/torrents`, and Jellyfin only `media` at `/data/media`.
- In-app paths are: qBittorrent default save path `/data/torrents` with categories `movies` and `tv`; Radarr root `/data/media/movies`; Sonarr root `/data/media/tv`.
- App config lives in named Docker volumes (`*-config`), not on the SSD.

**Storage modes (`mediactl`).** Modes are `main` (`DATA_ROOT` on the SSD), `internal` (fallback to `INTERNAL_DATA_ROOT` when the SSD is absent) and `archive` (adds the archive drive on top of either). Container paths are identical in every mode; only the host folder behind `/data` changes. `docker-compose.archive.yml` adds `/data/archive` (rw for Radarr/Sonarr, ro for Jellyfin). `sync` is host-side `rsync -aH` of the whole internal root, so it needs a hardlink-capable rsync (the macOS built-in passes the probe here; if it ever fails, `brew install rsync` and prefix the command with `MEDIACTL_RSYNC=/opt/homebrew/bin/rsync`, or `/usr/local/bin/rsync` on Intel). It refuses overlapping roots (equal, nested, symlinked, differing only in letter case, or containing `..`; checked by device/inode, again after the SSD folder is created), needs free space, stops Jellyfin along with qBittorrent/Radarr/Sonarr while it runs, takes the same lock as `up`, is a dry run unless `--yes`, and verifies the copy before deleting internal files; if it stops midway the stack stays stopped until `./mediactl up`. `archive`/`restore` move titles through the Radarr/Sonarr editor API, refuse (changing nothing) unless the stack is running and every matched title's folder exists on a mounted drive and the destination drive has room, require the archive mounted in both Radarr and Sonarr, refuse empty search terms, print "Matched: N movie(s), M show(s)" before confirming, need `--all` when more than 25 titles match, and need `--yes` in non-interactive shells. Archiving frees no space until the seeding torrent is removed: `--remove-torrents` lists them (name, size, save path) from qBittorrent, waits for the arr move to finish (shell-env `MEDIACTL_MOVE_TIMEOUT` default 900s, `MEDIACTL_POLL_SECS` default 5), skips torrents also used by a title not being archived, and fails closed (leaves the torrent) if anything cannot be confirmed.

**macOS / external drive caveats:**
- If the SSD isn't mounted, Docker can't create `/Volumes/...` (`permission denied`), so containers with `DATA_ROOT` mounts fail to start.
- Bind-mount sources are fixed when a container is created. After changing `DATA_ROOT`, re-run `up -d` and confirm with `docker inspect <c> --format '{{range .Mounts}}{{.Source}} {{end}}'`. A stale `DATA_ROOT` once silently sent downloads to the internal disk.

## Configuration

All site-specific values come from `.env`. It is gitignored and holds VPN credentials, so never commit it or echo its secrets. The variables referenced by compose are `DATA_ROOT`, `VPN_SERVICE_PROVIDER`, `VPN_TYPE` (`openvpn` | `wireguard`), `OPENVPN_USER`/`OPENVPN_PASSWORD`, `WIREGUARD_PRIVATE_KEY`/`WIREGUARD_ADDRESSES`, `VPN_PORT_FORWARDING`, `SERVER_COUNTRIES`/`SERVER_CITIES`, and the two static IPs. `mediactl` additionally reads `INTERNAL_DATA_ROOT`, `ARCHIVE_ROOT` (empty disables archive), `RADARR_API_KEY`, `SONARR_API_KEY`, optional `JELLYFIN_API_KEY`/`JELLYFIN_MOVIES_LIBRARY`/`JELLYFIN_TV_LIBRARY`, optional `QBIT_USER`/`QBIT_PASSWORD` (only for `--remove-torrents`); `.env.example` lists them with placeholders. `MEDIACTL_RSYNC`, `MEDIACTL_MOVE_TIMEOUT` and `MEDIACTL_POLL_SECS` are shell-environment overrides read from the process environment only, not `.env` settings; set them by prefixing the command. The traefik file additionally uses `DOMAIN`, `LE_EMAIL`, `HASHED_ADMIN_USER_PASS`.

Image tags are pinned to specific versions; upstream bumps them in dedicated `chore: bump <image> to vX` commits.

## README drift

The README describes upstream defaults that no longer match this fork:
- It refers to a `torrent-downloads` volume, `/downloads/movies` and `/downloads/tvshows`, plus a manual `mkdir`/`chown` step. In this fork the paths are `/data/...`, the TV folder is `tv`, and no `chown` is needed on Docker Desktop.
- It says the VPN is disabled by default; here it is enabled.
- It shows credentials passed inline on the command line; here they come from `.env`.

Prefer the compose file and this document when they conflict with the README.
