# Multi-drive storage modes and `mediactl`

Date: 2026-10-08
Status: Draft, awaiting review

## Goal

Let the media stack start in several storage configurations depending on which drives are plugged in, and give the owner one easy tool to move media between drives that may not all be connected.

## Context and constraints

- macOS, Docker Desktop. VPN stays enabled in all modes.
- Today `DATA_ROOT` (default `/Volumes/MediaServer/data`, external SSD) holds `torrents/` and `media/`. Radarr and Sonarr mount all of it at `/data` so imports are hardlinks.
- Bind-mount sources are fixed at container creation, and a missing `/Volumes/...` path must never be silently created on the internal disk.
- Hardlinks only work within one filesystem, so each mode keeps `torrents/` and `media/` on the same drive.
- `docker-compose.yml` should stay close to upstream; new behaviour goes in override files and a script.
- `.env` is gitignored and holds secrets; the tool must never print them.

## Existing tools considered

No existing tool covers this on macOS. Jellyfin (multiple library folders) and Radarr/Sonarr (multiple root folders) cover the app side. mergerfs and Unraid's mover do tiering but need Linux/FUSE. Rejected approaches: putting mode logic in compose profiles (cannot detect mounted drives), and mergerfs in a VM (too fragile for this setup).

## Modes

| Mode | `DATA_ROOT` | Archive |
|---|---|---|
| `main` (current behaviour) | external SSD | none |
| `internal` | `INTERNAL_DATA_ROOT` (default `~/media-stack-data`), same `torrents/` + `media/` layout | none |
| `archive` | SSD, or internal if SSD absent | archive drive mounted at `/data/archive` |

- `mediactl up` with no flags auto-detects: `main` if the SSD is mounted, else `internal`; adds the archive override if the archive drive is mounted. `--internal` and `--archive` force a mode.
- It refuses to start if a required drive is not mounted.
- Container-side paths are identical in every mode (`/data/media/movies`, `/data/media/tv`, `/data/torrents`), so app settings do not change between `main` and `internal`.
- `docker-compose.archive.yml` adds the archive mount only when that drive is present: read-write for Radarr and Sonarr, read-only for Jellyfin.
- New `.env` variables: `ARCHIVE_ROOT`, `INTERNAL_DATA_ROOT`, `RADARR_API_KEY`, `SONARR_API_KEY` (plus Jellyfin API key if needed for library refresh).
- Running plain `docker compose` still works for `main`.

## Commands

### `mediactl status`
Shows mounted drives, free space, running mode, title counts per drive, items on the internal drive awaiting `sync`, and items archived while the archive drive is unplugged.

### `mediactl sync` (internal to SSD)
- Dry run by default: lists titles, sizes, and SSD free space. `--yes` executes.
- Stops qBittorrent, Radarr, Sonarr; `rsync -aH` the whole internal `torrents/` + `media/` tree to the SSD (preserves hardlinks); verifies sizes; deletes internal copies; restarts the stack.
- Triggers Radarr/Sonarr rescan and a Jellyfin library refresh; qBittorrent re-checks torrents.

### `mediactl init-archive`
One-time: adds `/data/archive/movies` and `/data/archive/tv` as root folders in Radarr and Sonarr, and as library folders in Jellyfin.

### `mediactl archive <title…>` / `mediactl restore <title…>`
- Fuzzy-match titles, confirm the match list, then move via the Radarr/Sonarr API (`/movie/editor`, `/series/editor`, `moveFiles=true`) so app databases stay correct.
- Archiving does not free SSD space while a seeding torrent hardlinks the file; the command flags this and, with confirmation, removes the torrent and its data from qBittorrent.
- Archived titles stay visible in Jellyfin and the *arr apps while the archive drive is plugged in, and show as unavailable (not deleted) when it is not.

## Safety rules

- Dry-run first for any data-moving command.
- Never delete a source until the copy is verified.
- Refuse to run when a needed drive is missing.
- Lock file prevents overlapping runs.
- Never print secrets from `.env`.

## Deliverables

- `mediactl` script (bash) at repo root.
- `docker-compose.archive.yml` override.
- `.env` variable documentation (a `.env.example` without secrets).
- CLAUDE.md and README updated for the new modes and commands.

## Out of scope

Automatic moves on drive mount, age/watch-based archive suggestions, mergerfs-style pooling, and Linux/Windows support.

## Testing

No test suite exists in this repo. Verification: `docker compose config` for each mode, and shell-level dry-runs against throwaway directories standing in for the drives, including a missing-drive refusal and a hardlink-preservation check for `sync`.
