# Multi-drive storage modes and `mediactl` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mediactl` bash script and a compose override so the stack starts in `main`, `internal`, or `archive` storage mode, and media can be moved between the internal drive, external SSD, and archive drive.

**Architecture:** `mediactl` detects which drives are mounted, picks a mode, and runs `docker compose` with `DATA_ROOT` (and optionally `ARCHIVE_ROOT` plus `docker-compose.archive.yml`) set per invocation. `sync` is a host-side `rsync -aH` from the internal root to the SSD; `archive`/`restore` go through the Radarr/Sonarr editor API so app databases stay correct. The script is sourceable so functions can be unit-tested with stubbed `docker`, `curl`, and `mount`.

**Tech Stack:** bash (must run on macOS system bash 3.2 and bash 5), `jq`, `curl`, `rsync`, Docker Compose. No test framework is installed, so tests use a small plain-bash runner (`tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-10-08-multi-drive-storage-design.md`

## Global Constraints

- macOS + Docker Desktop; VPN stays enabled in every mode (`--profile vpn`).
- Container-side paths are identical in every mode: `/data/torrents`, `/data/media/movies`, `/data/media/tv`; archive is mounted at `/data/archive` (Radarr/Sonarr read-write, Jellyfin read-only) with `movies/` and `tv/` inside.
- `torrents/` and `media/` must always live on the same drive within a mode (hardlinks).
- `docker-compose.yml` is not modified; new behaviour lives in `docker-compose.archive.yml` and `mediactl`.
- A missing `/Volumes/...` path must never be silently created: refuse to start when a required drive is not mounted.
- Never delete a source until the copy is verified; data-moving commands dry-run first; lock file prevents overlapping runs.
- `.env` is gitignored; secrets are never printed. New variables: `ARCHIVE_ROOT`, `INTERNAL_DATA_ROOT`, `RADARR_API_KEY`, `SONARR_API_KEY` (optional: `JELLYFIN_API_KEY`, `JELLYFIN_MOVIES_LIBRARY`, `JELLYFIN_TV_LIBRARY`, `QBIT_USER`, `QBIT_PASSWORD`).
- Scripts avoid bash-4-only features (no associative arrays, no `mapfile`), and avoid `[ a ] && b` as the last statement of a function (breaks under `set -e`); use `if`.
- Host ports used by the tool: Radarr 7878, Sonarr 8989, Jellyfin 8096, qBittorrent 5080 (published on the `vpn` service).

## Review Focus

Failure modes the spec implies but does not spell out. Each has a pinning test in the task that owns the code.

1. Titles with spaces, apostrophes, and parentheses (`Don't Look Up (2021)`) in `sync` and in listings: must be copied and deleted intact (Task 4).
2. Volume names with spaces (`/Volumes/My Passport`) and name prefixes (`/Volumes/MediaServer` vs `/Volumes/MediaServer 2`): detection must be exact and `DATA_ROOT` must reach compose unmangled (Tasks 1, 2).
3. A second `sync` while one is running, or after a crash left a stale lock: refuse for a live PID, reclaim for a dead PID (Task 4).
4. Not enough free space on the SSD, or `rsync` that cannot preserve hardlinks (macOS ships openrsync): refuse before moving anything, and never delete internal data (Task 4).
5. `archive`/`restore` with zero matches, several matches, or no `--yes` on a non-interactive shell: nothing moves without an explicit confirmed list (Task 6).

---

## File Structure

- Create `mediactl`: the CLI (config, mount detection, mode resolution, `up`, `status`, `sync`, `init-archive`, `archive`, `restore`). One file; about 450 lines, organised in labelled sections. Sourceable for tests.
- Create `docker-compose.archive.yml`: override adding the archive mount.
- Create `tests/run.sh`: test runner and shared stubs.
- Create `tests/test_config.sh`, `tests/test_up.sh`, `tests/test_status.sh`, `tests/test_sync.sh`, `tests/test_archive.sh`: one file per task area.
- Create `.env.example`: documented variables, no secrets.
- Modify `CLAUDE.md`, `README.md`: document modes and commands.

---

### Task 1: Test runner, `mediactl` skeleton, config and mount detection

**Files:**
- Create: `tests/run.sh`
- Create: `tests/test_config.sh`
- Create: `mediactl`

**Interfaces:**
- Produces (in `mediactl`): `die MSG` (stderr + exit 1), `env_get KEY [DEFAULT]` (environment wins, then `.env`, then default), `load_config` (sets `SSD_ROOT`, `INTERNAL_ROOT`, `ARCHIVE_ROOT`), `volume_of PATH`, `is_mounted PATH` (return 0/1), `main "$@"` dispatcher.
- Produces (in `tests/run.sh`): `setup_env`, `assert_eq EXPECTED ACTUAL`, `assert_contains HAYSTACK NEEDLE`, `assert_not_contains HAYSTACK NEEDLE`, `fail MSG`, `resp "METHOD /path" BODY` (canned curl response), stubs `$TMP/bin/docker` (logs to `$TMP/docker.log`, prints `$TMP/docker_inspect` for `inspect`) and `$TMP/bin/curl` (logs to `$TMP/curl.log`, replies from `$TMP/resp/`, default `[]`).
- Env overrides honoured by `mediactl`: `MEDIACTL_ENV_FILE`, `MEDIACTL_DOCKER`, `MEDIACTL_CURL`, `MEDIACTL_RSYNC`, `MEDIACTL_LOCK`, `MEDIACTL_FAKE_MOUNTED` (colon-separated volume list; when set, replaces real mount checks), `MEDIACTL_MOUNT_CMD`.

- [ ] **Step 1: Write the test runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Minimal test runner. Sources tests/test_*.sh and runs every function named test_*
# in its own subshell with a fresh temp dir and stubbed docker/curl.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT

fail() { echo "    FAIL: $*" >&2; return 1; }
assert_eq() { if [ "$1" != "$2" ]; then fail "expected [$1] got [$2]"; fi; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2], got [$1]";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output NOT to contain [$2], got [$1]";; *) ;; esac; }

# resp "GET /api/v3/movie" '[...]' : canned reply for the stub curl
resp() { printf '%s' "$2" > "$TMP/resp/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

setup_env() {
  unset DATA_ROOT INTERNAL_DATA_ROOT ARCHIVE_ROOT RADARR_API_KEY SONARR_API_KEY \
        JELLYFIN_API_KEY JELLYFIN_MOVIES_LIBRARY JELLYFIN_TV_LIBRARY QBIT_USER QBIT_PASSWORD \
        MEDIACTL_MOUNT_CMD MEDIACTL_RSYNC
  export HOME="$TMP"
  export MEDIACTL_ENV_FILE="$TMP/.env"
  export MEDIACTL_LOCK="$TMP/lock"
  mkdir -p "$TMP/ssd" "$TMP/internal" "$TMP/archive" "$TMP/bin" "$TMP/resp"
  printf 'DATA_ROOT=%s\nINTERNAL_DATA_ROOT=%s\nARCHIVE_ROOT=%s\nRADARR_API_KEY=rk\nSONARR_API_KEY=sk\n' \
    "$TMP/ssd" "$TMP/internal" "$TMP/archive" > "$TMP/.env"
  export MEDIACTL_FAKE_MOUNTED="$TMP/ssd:$TMP/archive"
  export MEDIACTL_DOCKER="$TMP/bin/docker" MEDIACTL_CURL="$TMP/bin/curl"
  cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMP/docker.log"
if [ "$1" = inspect ]; then cat "$TMP/docker_inspect" 2>/dev/null || true; fi
exit 0
EOF
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
args=("$@"); method=GET; url="${args[$((${#args[@]}-1))]}"
i=0
while [ $i -lt ${#args[@]} ]; do
  if [ "${args[$i]}" = "-X" ]; then method="${args[$((i+1))]}"; fi
  i=$((i+1))
done
echo "$*" >> "$TMP/curl.log"
p=$(printf '%s' "$url" | sed 's#^http://[^/]*##')
f="$TMP/resp/$(printf '%s' "$method $p" | tr -c 'A-Za-z0-9' '_')"
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
EOF
  chmod +x "$TMP/bin/docker" "$TMP/bin/curl"
  export TMP
}

for f in "$ROOT"/tests/test_*.sh; do . "$f"; done

PASS=0; FAILED=0
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  TMP="$(mktemp -d)"; export TMP
  if ( set -e; cd "$TMP"; setup_env; . "$ROOT/mediactl"; "$t" ); then
    PASS=$((PASS+1)); echo "ok   $t"
  else
    FAILED=$((FAILED+1)); echo "FAIL $t"
  fi
  rm -rf "$TMP"
done
echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
```

- [ ] **Step 2: Write the failing config tests**

Create `tests/test_config.sh`:

```bash
test_env_get_prefers_environment_over_file() {
  DATA_ROOT=/from/env
  assert_eq "/from/env" "$(env_get DATA_ROOT /default)"
}

test_env_get_reads_file_strips_quotes_and_defaults() {
  printf 'FOO="quoted value"\nBAR=plain\n' >> "$TMP/.env"
  assert_eq "quoted value" "$(env_get FOO)"
  assert_eq "plain" "$(env_get BAR)"
  assert_eq "dflt" "$(env_get MISSING dflt)"
}

test_load_config_reads_roots() {
  load_config
  assert_eq "$TMP/ssd" "$SSD_ROOT"
  assert_eq "$TMP/internal" "$INTERNAL_ROOT"
  assert_eq "$TMP/archive" "$ARCHIVE_ROOT"
}

test_volume_of() {
  assert_eq "/Volumes/My Passport" "$(volume_of "/Volumes/My Passport/data/media")"
  assert_eq "/Users/x/data" "$(volume_of /Users/x/data)"
}

test_is_mounted_with_fake_list() {
  is_mounted "$TMP/ssd/data"  || fail "ssd should count as mounted"
  MEDIACTL_FAKE_MOUNTED=""
  if is_mounted "$TMP/ssd"; then fail "empty fake list means nothing mounted"; fi
}

test_is_mounted_parses_mount_table_exactly() {
  unset MEDIACTL_FAKE_MOUNTED
  printf '/dev/disk4s1 on /Volumes/My Passport (apfs, local)\n/dev/disk5s1 on /Volumes/MediaServer 2 (apfs, local)\n/dev/disk1s1 on / (apfs)\n' > "$TMP/mount.txt"
  printf '#!/usr/bin/env bash\ncat "%s/mount.txt"\n' "$TMP" > "$TMP/bin/mount"
  chmod +x "$TMP/bin/mount"
  export MEDIACTL_MOUNT_CMD="$TMP/bin/mount"
  is_mounted "/Volumes/My Passport/data" || fail "volume with a space should be mounted"
  if is_mounted "/Volumes/MediaServer/data"; then fail "MediaServer must not match 'MediaServer 2'"; fi
  is_mounted "/Volumes/MediaServer 2/data" || fail "MediaServer 2 should be mounted"
}

test_die_exits_nonzero_with_message() {
  if out=$( (die "boom") 2>&1 ); then fail "die should exit nonzero"; fi
  assert_contains "$out" "mediactl: boom"
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: errors because `mediactl` does not exist (`No such file or directory`), 0 passed.

- [ ] **Step 4: Write the skeleton**

Create `mediactl` (then `chmod +x mediactl`):

```bash
#!/usr/bin/env bash
# mediactl: start the media stack in the right storage mode and move media
# between the internal drive, the external SSD and the archive drive.
# Run `mediactl help` for usage. Sourceable for tests (main only runs when executed).
set -euo pipefail

MEDIACTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${MEDIACTL_ENV_FILE:-$MEDIACTL_DIR/.env}"
DOCKER="${MEDIACTL_DOCKER:-docker}"
CURL="${MEDIACTL_CURL:-curl}"
RSYNC="${MEDIACTL_RSYNC:-rsync}"
LOCK_DIR="${MEDIACTL_LOCK:-${TMPDIR:-/tmp}/mediactl.lock}"

# ---------------------------------------------------------------- helpers
die() { echo "mediactl: $*" >&2; exit 1; }

# env_get KEY [DEFAULT]: environment wins, then .env, then DEFAULT. Never echoes secrets itself.
env_get() {
  local key=$1 def=${2:-} val=""
  if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
  if [ -f "$ENV_FILE" ]; then
    val=$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- \
      | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//") || true
  fi
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

load_config() {
  SSD_ROOT=$(env_get DATA_ROOT /Volumes/MediaServer/data)
  INTERNAL_ROOT=$(env_get INTERNAL_DATA_ROOT "$HOME/media-stack-data")
  ARCHIVE_ROOT=$(env_get ARCHIVE_ROOT "")
}

# ------------------------------------------------------- drive detection
# volume_of PATH: the removable-volume root (/Volumes/<name>) or PATH itself.
volume_of() {
  case "$1" in
    /Volumes/*) local rest=${1#/Volumes/}; printf '/Volumes/%s' "${rest%%/*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

mount_table() { "${MEDIACTL_MOUNT_CMD:-mount}"; }

# is_mounted PATH: true when the volume holding PATH is mounted. A leftover empty
# /Volumes/<name> folder does not count; only the mount table does.
is_mounted() {
  local vol; vol=$(volume_of "$1")
  if [ -n "${MEDIACTL_FAKE_MOUNTED+x}" ]; then
    case ":$MEDIACTL_FAKE_MOUNTED:" in *":$vol:"*) return 0 ;; *) return 1 ;; esac
  fi
  case "$vol" in
    /Volumes/*) mount_table | grep -qF " on $vol (" ;;
    *) [ -d "$vol" ] ;;
  esac
}

# ------------------------------------------------------------- dispatcher
usage() {
  cat <<'EOF'
Usage: mediactl <command> [options]
  up [--main|--internal|--archive] [--dry-run]   start the stack in the right mode
  status                                         drives, free space, running mode
  sync [--yes]                                   move internal-drive media to the SSD
  init-archive                                   register archive folders in the apps
  archive [--yes] [--remove-torrents] TITLE...   move titles to the archive drive
  restore [--yes] TITLE...                       move titles back from the archive drive
EOF
}

main() {
  local cmd=${1:-help}
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    help|-h|--help) usage ;;
    *) usage >&2; die "unknown command: $cmd" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x mediactl tests/run.sh && bash tests/run.sh`
Expected: `7 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add mediactl tests/run.sh tests/test_config.sh
git commit -m "feat: add mediactl skeleton, config loading and drive detection"
```

---

### Task 2: Archive override file, mode resolution, and `up`

**Files:**
- Create: `docker-compose.archive.yml`
- Create: `tests/test_up.sh`
- Modify: `mediactl` (add `resolve_plan`, `cmd_up`, dispatcher entry)

**Interfaces:**
- Consumes: `load_config`, `is_mounted`, `volume_of`, `die`, `DOCKER`, `MEDIACTL_DIR` from Task 1.
- Produces: `resolve_plan [--main|--internal|--archive]...` sets globals `MODE` (`main`|`internal`), `WITH_ARCHIVE` (`0`|`1`), `ACTIVE_ROOT`; `cmd_up [flags] [--dry-run]`; `compose_cmd ARGS...` (runs `docker compose --profile vpn ARGS` from the repo dir).

- [ ] **Step 1: Write the failing tests**

Create `tests/test_up.sh`:

```bash
test_up_main_when_ssd_mounted_without_archive() {
  MEDIACTL_FAKE_MOUNTED="$TMP/ssd"
  out=$(cmd_up --dry-run)
  assert_contains "$out" "Mode: main"
  assert_contains "$out" "DATA_ROOT=$TMP/ssd"
  assert_not_contains "$out" "docker-compose.archive.yml"
}

test_up_falls_back_to_internal_when_ssd_missing() {
  MEDIACTL_FAKE_MOUNTED=""
  out=$(cmd_up --dry-run)
  assert_contains "$out" "Mode: internal"
  assert_contains "$out" "DATA_ROOT=$TMP/internal"
}

test_up_adds_archive_override_when_archive_mounted() {
  out=$(cmd_up --dry-run)
  assert_contains "$out" "docker-compose.archive.yml"
  assert_contains "$out" "ARCHIVE_ROOT=$TMP/archive"
}

test_up_internal_flag_forces_internal_even_if_ssd_present() {
  out=$(cmd_up --internal --dry-run)
  assert_contains "$out" "DATA_ROOT=$TMP/internal"
}

test_up_main_flag_refuses_when_ssd_missing() {
  MEDIACTL_FAKE_MOUNTED=""
  if out=$( (cmd_up --main --dry-run) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "SSD is not mounted"
}

test_up_archive_flag_refuses_when_archive_missing() {
  MEDIACTL_FAKE_MOUNTED="$TMP/ssd"
  if out=$( (cmd_up --archive --dry-run) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "archive drive is not mounted"
}

test_up_rejects_conflicting_and_unknown_flags() {
  if out=$( (cmd_up --main --internal --dry-run) 2>&1 ); then fail "conflict"; fi
  if out=$( (cmd_up --bogus --dry-run) 2>&1 ); then fail "unknown flag"; fi
  assert_contains "$out" "unknown option: --bogus"
}

test_up_passes_data_root_with_spaces_intact() {
  mkdir -p "$TMP/My SSD"
  printf 'DATA_ROOT=%s/My SSD\nINTERNAL_DATA_ROOT=%s\n' "$TMP" "$TMP/internal" > "$TMP/.env"
  MEDIACTL_FAKE_MOUNTED="$TMP/My SSD"
  out=$(cmd_up --dry-run)
  assert_contains "$out" 'My\ SSD'
}

test_up_real_run_creates_layout_and_calls_compose() {
  MEDIACTL_FAKE_MOUNTED=""
  cmd_up >/dev/null
  [ -d "$TMP/internal/torrents/movies" ] || fail "torrents/movies missing"
  [ -d "$TMP/internal/media/tv" ] || fail "media/tv missing"
  assert_contains "$(cat "$TMP/docker.log")" "compose --profile vpn -f docker-compose.yml up -d"
}

test_up_dry_run_creates_nothing() {
  MEDIACTL_FAKE_MOUNTED=""
  cmd_up --dry-run >/dev/null
  [ ! -d "$TMP/internal/torrents" ] || fail "dry run must not create directories"
}

test_archive_override_is_valid_yaml_with_expected_mounts() {
  f="$ROOT/docker-compose.archive.yml"
  grep -q 'radarr:' "$f" || fail "radarr"
  grep -q 'sonarr:' "$f" || fail "sonarr"
  grep -q 'jellyfin:' "$f" || fail "jellyfin"
  grep -q '/data/archive:ro' "$f" || fail "jellyfin must mount read-only"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: the new `test_up_*` tests FAIL (`cmd_up: command not found`).

- [ ] **Step 3: Create the override file**

Create `docker-compose.archive.yml`:

```yaml
# Added by `mediactl up` only when the archive drive is mounted.
# ARCHIVE_ROOT must contain movies/ and tv/ (mediactl creates them).
services:
  radarr:
    volumes:
      - ${ARCHIVE_ROOT:?ARCHIVE_ROOT is not set}:/data/archive
  sonarr:
    volumes:
      - ${ARCHIVE_ROOT:?ARCHIVE_ROOT is not set}:/data/archive
  jellyfin:
    volumes:
      - ${ARCHIVE_ROOT:?ARCHIVE_ROOT is not set}:/data/archive:ro
```

- [ ] **Step 4: Add `resolve_plan`, `compose_cmd`, `cmd_up`**

In `mediactl`, insert before the `# ---- dispatcher` section:

```bash
# ------------------------------------------------------------ mode logic
# resolve_plan [--main|--internal|--archive]: sets MODE, WITH_ARCHIVE, ACTIVE_ROOT.
resolve_plan() {
  local force_main=0 force_internal=0 force_archive=0 arg
  for arg in "$@"; do
    case "$arg" in
      --main) force_main=1 ;;
      --internal) force_internal=1 ;;
      --archive) force_archive=1 ;;
      *) die "unknown option: $arg" ;;
    esac
  done
  if [ "$force_main" -eq 1 ] && [ "$force_internal" -eq 1 ]; then
    die "--main and --internal conflict"
  fi
  load_config
  if [ "$force_internal" -eq 1 ]; then
    MODE=internal
  elif is_mounted "$SSD_ROOT"; then
    MODE=main
  elif [ "$force_main" -eq 1 ]; then
    die "external SSD is not mounted ($(volume_of "$SSD_ROOT"))"
  else
    MODE=internal
  fi
  WITH_ARCHIVE=0
  if [ -n "$ARCHIVE_ROOT" ] && is_mounted "$ARCHIVE_ROOT"; then
    WITH_ARCHIVE=1
  elif [ "$force_archive" -eq 1 ]; then
    die "archive drive is not mounted (ARCHIVE_ROOT=${ARCHIVE_ROOT:-unset})"
  fi
  if [ "$MODE" = main ]; then ACTIVE_ROOT=$SSD_ROOT; else ACTIVE_ROOT=$INTERNAL_ROOT; fi
}

# compose_cmd ARGS...: run docker compose (vpn profile) from the repo directory.
compose_cmd() { (cd "$MEDIACTL_DIR" && "$DOCKER" compose --profile vpn "$@"); }

make_layout() { # make_layout ROOT
  mkdir -p "$1/torrents/movies" "$1/torrents/tv" "$1/media/movies" "$1/media/tv"
}

cmd_up() {
  local dry=0 arg flags=()
  for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then dry=1; else flags+=("$arg"); fi
  done
  resolve_plan ${flags[@]+"${flags[@]}"}
  local files=(-f docker-compose.yml) cmd=(env "DATA_ROOT=$ACTIVE_ROOT") note=""
  if [ "$WITH_ARCHIVE" -eq 1 ]; then
    files+=(-f docker-compose.archive.yml)
    cmd+=("ARCHIVE_ROOT=$ARCHIVE_ROOT")
    note=", archive: $ARCHIVE_ROOT"
  fi
  cmd+=("$DOCKER" compose --profile vpn "${files[@]}" up -d)
  echo "Mode: $MODE (data root: $ACTIVE_ROOT$note)"
  if [ "$dry" -eq 1 ]; then
    printf '%q ' "${cmd[@]}"; echo
    return 0
  fi
  make_layout "$ACTIVE_ROOT"
  if [ "$WITH_ARCHIVE" -eq 1 ]; then mkdir -p "$ARCHIVE_ROOT/movies" "$ARCHIVE_ROOT/tv"; fi
  (cd "$MEDIACTL_DIR" && "${cmd[@]}")
}
```

In `main`, add before the `*)` case: `up) cmd_up "$@" ;;`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all pass (18 total so far).

- [ ] **Step 6: Validate the override against the real compose file**

Run: `DATA_ROOT=/tmp/x ARCHIVE_ROOT=/tmp/y docker compose --profile vpn -f docker-compose.yml -f docker-compose.archive.yml config | grep -n "/data/archive"`
Expected: three lines (radarr, sonarr, jellyfin; jellyfin's with `read_only: true`). If `docker compose config` errors on missing `.env` values, run it from the repo (which has `.env`).

- [ ] **Step 7: Commit**

```bash
git add docker-compose.archive.yml mediactl tests/test_up.sh
git commit -m "feat: add archive compose override and mediactl up with mode detection"
```

---

### Task 3: `status`

**Files:**
- Create: `tests/test_status.sh`
- Modify: `mediactl` (add `list_titles`, `count_kind`, `running_data_root`, `cmd_status`, and API helpers `arr_url`, `arr_api` needed for the offline-archive count; dispatcher entry)

**Interfaces:**
- Consumes: `load_config`, `is_mounted`, `volume_of`, `env_get`, `DOCKER`, `CURL` (Task 1).
- Produces: `list_titles ROOT` (prints `kind<TAB>name` lines for `media/movies/*` and `media/tv/*`), `count_kind ROOT movies|tv` (prints integer), `arr_url APP`, `arr_api APP METHOD PATH [JSON]` (used again in Tasks 4-6), `cmd_status`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_status.sh`:

```bash
test_list_titles_handles_odd_names() {
  mkdir -p "$TMP/internal/media/movies/Don't Look Up (2021)" "$TMP/internal/media/tv/Show Name"
  out=$(list_titles "$TMP/internal")
  assert_contains "$out" "movies	Don't Look Up (2021)"
  assert_contains "$out" "tv	Show Name"
}

test_count_kind() {
  mkdir -p "$TMP/internal/media/movies/A" "$TMP/internal/media/movies/B"
  assert_eq "2" "$(count_kind "$TMP/internal" movies)"
  assert_eq "0" "$(count_kind "$TMP/internal" tv)"
  assert_eq "0" "$(count_kind "$TMP/nonexistent" movies)"
}

test_status_reports_drives_and_pending_sync() {
  mkdir -p "$TMP/internal/media/movies/Pending Movie"
  out=$(cmd_status)
  assert_contains "$out" "SSD"
  assert_contains "$out" "mounted"
  assert_contains "$out" "Pending sync: 1 movie(s), 0 show(s)"
}

test_status_flags_unmounted_drives() {
  MEDIACTL_FAKE_MOUNTED=""
  out=$(cmd_status)
  assert_contains "$out" "NOT MOUNTED"
  assert_not_contains "$out" "Pending sync"
}

test_status_shows_running_data_root_without_host_mnt_prefix() {
  printf '/host_mnt%s' "$TMP/ssd" > "$TMP/docker_inspect"
  out=$(cmd_status)
  assert_contains "$out" "Running data root: $TMP/ssd"
}

test_status_counts_archived_titles_when_archive_offline() {
  MEDIACTL_FAKE_MOUNTED="$TMP/ssd"
  resp "GET /api/v3/movie" '[{"id":1,"title":"Old","path":"/data/archive/movies/Old (1999)"},{"id":2,"title":"New","path":"/data/media/movies/New"}]'
  out=$(cmd_status)
  assert_contains "$out" "Archived titles offline: 1"
}

test_arr_api_requires_key() {
  printf 'DATA_ROOT=%s\n' "$TMP/ssd" > "$TMP/.env"
  if out=$( (arr_api radarr GET /movie) 2>&1 ); then fail "should fail without key"; fi
  assert_contains "$out" "RADARR_API_KEY is not set"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: new status tests FAIL (`list_titles: command not found`).

- [ ] **Step 3: Implement**

In `mediactl`, insert before the `# ---- dispatcher` section:

```bash
# ------------------------------------------------------------ app APIs
arr_url() {
  case "$1" in
    radarr) echo "http://localhost:7878/api/v3" ;;
    sonarr) echo "http://localhost:8989/api/v3" ;;
    *) die "unknown app: $1" ;;
  esac
}

# arr_api APP METHOD PATH [JSON_BODY]
arr_api() {
  local app=$1 method=$2 path=$3 body=${4:-} keyvar key
  keyvar="$(printf '%s' "$app" | tr 'a-z' 'A-Z')_API_KEY"
  key=$(env_get "$keyvar")
  if [ -z "$key" ]; then die "$keyvar is not set in .env"; fi
  local args=(-fsS -X "$method" -H "X-Api-Key: $key" -H "Content-Type: application/json")
  if [ -n "$body" ]; then args+=(-d "$body"); fi
  "$CURL" "${args[@]}" "$(arr_url "$app")$path"
}

# --------------------------------------------------------------- status
# list_titles ROOT: "kind<TAB>name" per top-level folder in media/movies and media/tv.
list_titles() {
  local kind dir
  for kind in movies tv; do
    dir="$1/media/$kind"
    if [ -d "$dir" ]; then
      find "$dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort \
        | while IFS= read -r name; do printf '%s\t%s\n' "$kind" "$name"; done
    fi
  done
}

count_kind() { list_titles "$1" | awk -F'\t' -v k="$2" '$1==k{n++} END{print n+0}'; }

free_space() { df -h "$(volume_of "$1")" | awk 'NR==2{print $4}'; }

running_data_root() {
  "$DOCKER" inspect radarr \
    --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null \
    | sed 's#^/host_mnt##' || true
}

drive_line() { # drive_line LABEL PATH
  local label=$1 path=$2 state free="-" movies="-" shows="-"
  if is_mounted "$path"; then
    state="mounted"; free=$(free_space "$path")
    movies=$(count_kind "$path" movies); shows=$(count_kind "$path" tv)
  else
    state="NOT MOUNTED"
  fi
  printf '%-9s %-40s %-12s free %-6s movies %-4s tv %s\n' "$label" "$path" "$state" "$free" "$movies" "$shows"
}

cmd_status() {
  load_config
  local running; running=$(running_data_root)
  if [ -n "$running" ]; then echo "Running data root: $running"; else echo "Running data root: (stack not running)"; fi
  drive_line "SSD" "$SSD_ROOT"
  drive_line "Internal" "$INTERNAL_ROOT"
  if [ -n "$ARCHIVE_ROOT" ]; then drive_line "Archive" "$ARCHIVE_ROOT"; fi
  if is_mounted "$SSD_ROOT" && [ -d "$INTERNAL_ROOT/media" ]; then
    local m s; m=$(count_kind "$INTERNAL_ROOT" movies); s=$(count_kind "$INTERNAL_ROOT" tv)
    if [ $((m + s)) -gt 0 ]; then
      echo "Pending sync: $m movie(s), $s show(s) on internal -> run: mediactl sync"
    fi
  fi
  if [ -n "$ARCHIVE_ROOT" ] && ! is_mounted "$ARCHIVE_ROOT"; then
    local n=0 c
    c=$(arr_api radarr GET /movie 2>/dev/null | jq '[.[] | select(.path | startswith("/data/archive/"))] | length' 2>/dev/null) || c=0
    n=$((n + ${c:-0}))
    c=$(arr_api sonarr GET /series 2>/dev/null | jq '[.[] | select(.path | startswith("/data/archive/"))] | length' 2>/dev/null) || c=0
    n=$((n + ${c:-0}))
    if [ "$n" -gt 0 ]; then echo "Archived titles offline: $n (plug in the archive drive and run: mediactl up)"; fi
  fi
}
```

In `main`, add: `status) cmd_status ;;`

Note: in the stub, Sonarr's `GET /series` defaults to `[]`, so only Radarr contributes to the count in the test.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add mediactl tests/test_status.sh
git commit -m "feat: add mediactl status and Radarr/Sonarr API helper"
```

---

### Task 4: `sync` (internal drive to SSD)

**Files:**
- Create: `tests/test_sync.sh`
- Modify: `mediactl` (add lock, hardlink probe, manifest/verify, `refresh_apps`, `cmd_sync`, dispatcher entry)

**Interfaces:**
- Consumes: `resolve_plan`, `cmd_up`, `compose_cmd`, `make_layout`, `list_titles`, `free_space`, `arr_api`, `is_mounted`, `volume_of`, `RSYNC`, `LOCK_DIR`, `CURL`, `env_get`.
- Produces: `acquire_lock` / `release_lock`, `rsync_preserves_hardlinks` (return 0/1), `manifest ROOT` (sorted `size path` lines for `torrents` + `media`), `verify_copy SRC DST` (die on mismatch), `refresh_apps` (best effort Radarr/Sonarr rescan + Jellyfin refresh), `cmd_sync [--yes]`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_sync.sh`:

```bash
seed_internal() {
  make_layout "$TMP/internal"
  mkdir -p "$TMP/internal/media/movies/Don't Look Up (2021)"
  printf 'movie-bytes' > "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv"
  ln "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" \
     "$TMP/internal/media/movies/Don't Look Up (2021)/Don't Look Up (2021).mkv"
}

inode() { stat -f %i "$1"; }

test_lock_refuses_live_pid_and_reclaims_stale() {
  sleep 30 & live=$!
  mkdir "$LOCK_DIR"; echo "$live" > "$LOCK_DIR/pid"
  if out=$( (acquire_lock) 2>&1 ); then kill "$live"; fail "live lock should refuse"; fi
  assert_contains "$out" "another mediactl is running"
  kill "$live"
  echo 999999 > "$LOCK_DIR/pid"
  ( acquire_lock ) || fail "stale lock should be reclaimed"
}

test_rsync_probe_detects_hardlink_support() {
  rsync_preserves_hardlinks || fail "system rsync cannot preserve hardlinks: brew install rsync and set MEDIACTL_RSYNC=\$(brew --prefix)/bin/rsync"
}

test_rsync_probe_fails_for_non_hardlink_rsync() {
  printf '#!/usr/bin/env bash\nexec rsync -a "$@"\n' > "$TMP/bin/rsync"; chmod +x "$TMP/bin/rsync"
  # strips -H by forcing -a only: last-wins is not guaranteed, so emulate with cp -R
  printf '#!/usr/bin/env bash\nargs=("$@"); n=${#args[@]}; cp -R "${args[$((n-2))]}." "${args[$((n-1))]}"\n' > "$TMP/bin/rsync"
  RSYNC="$TMP/bin/rsync"
  if rsync_preserves_hardlinks; then fail "cp-based copy must be reported as not preserving hardlinks"; fi
}

test_sync_refuses_when_ssd_missing() {
  MEDIACTL_FAKE_MOUNTED=""
  seed_internal
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "external SSD is not mounted"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "internal data must be untouched"
}

test_sync_dry_run_lists_titles_and_moves_nothing() {
  seed_internal
  out=$(cmd_sync)
  assert_contains "$out" "Don't Look Up (2021)"
  assert_contains "$out" "Dry run"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "dry run moved data"
  [ ! -e "$TMP/ssd/media/movies" ] || fail "dry run wrote to the SSD"
}

test_sync_nothing_to_do() {
  make_layout "$TMP/internal"
  assert_contains "$(cmd_sync --yes)" "Nothing to sync"
}

test_sync_yes_moves_preserves_hardlinks_and_cleans_internal() {
  seed_internal
  cmd_sync --yes >/dev/null
  a="$TMP/ssd/torrents/movies/Don't Look Up (2021).mkv"
  b="$TMP/ssd/media/movies/Don't Look Up (2021)/Don't Look Up (2021).mkv"
  [ -f "$a" ] && [ -f "$b" ] || fail "files missing on SSD"
  assert_eq "$(inode "$a")" "$(inode "$b")"
  assert_eq "movie-bytes" "$(cat "$b")"
  [ -z "$(find "$TMP/internal/torrents" "$TMP/internal/media" -type f)" ] || fail "internal files should be gone"
  [ -d "$TMP/internal/media/movies" ] || fail "internal layout skeleton should remain"
  log=$(cat "$TMP/docker.log")
  assert_contains "$log" "compose --profile vpn stop qbittorrent radarr sonarr"
  assert_contains "$log" "up -d"
}

test_sync_keeps_internal_when_verification_fails() {
  seed_internal
  # an rsync that "succeeds" but copies nothing
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/rsync"; chmod +x "$TMP/bin/rsync"
  RSYNC="$TMP/bin/rsync"
  rsync_preserves_hardlinks() { return 0; }
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "verification should fail"; fi
  assert_contains "$out" "verification failed"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "internal copy must be kept"
}

test_sync_refuses_when_ssd_lacks_space() {
  seed_internal
  free_kb() { echo 1; }
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "not enough free space"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "internal data must be untouched"
}

test_sync_refuses_when_rsync_cannot_preserve_hardlinks() {
  seed_internal
  rsync_preserves_hardlinks() { return 1; }
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "brew install rsync"
}

test_sync_triggers_rescans_when_keys_present() {
  seed_internal
  cmd_sync --yes >/dev/null
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" "RescanMovie"
  assert_contains "$log" "RescanSeries"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: new sync tests FAIL (`acquire_lock: command not found`, etc.).

- [ ] **Step 3: Implement**

In `mediactl`, insert before the `# ---- dispatcher` section:

```bash
# ------------------------------------------------------------------ sync
release_lock() { rm -rf "$LOCK_DIR"; }

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"; trap release_lock EXIT; return 0
  fi
  local pid; pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    die "another mediactl is running (pid $pid)"
  fi
  rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"; echo $$ > "$LOCK_DIR/pid"; trap release_lock EXIT
}

# macOS ships openrsync, which may not preserve hardlinks; prove it before moving data.
rsync_preserves_hardlinks() {
  local d; d=$(mktemp -d)
  mkdir "$d/src" "$d/dst"
  echo x > "$d/src/a"; ln "$d/src/a" "$d/src/b"
  "$RSYNC" -aH "$d/src/" "$d/dst/" >/dev/null 2>&1 || true
  local ia ib
  ia=$(stat -f %i "$d/dst/a" 2>/dev/null || echo 1); ib=$(stat -f %i "$d/dst/b" 2>/dev/null || echo 2)
  rm -rf "$d"
  [ "$ia" = "$ib" ]
}

free_kb() { df -k "$(volume_of "$1")" | awk 'NR==2{print $4}'; }

manifest() { # manifest ROOT: sorted "size path" for every file under torrents/ and media/
  (cd "$1" && { find torrents media -type f -exec stat -f '%z %N' {} + 2>/dev/null || true; } | sort)
}

verify_copy() { # verify_copy SRC DST: every source file exists at the destination with the same size
  local missing
  missing=$(comm -23 <(manifest "$1") <(manifest "$2"))
  if [ -n "$missing" ]; then
    die "verification failed, internal copies kept. Differences:
$missing"
  fi
}

wait_for_http() { # wait_for_http URL: up to ~60s
  local i
  for i in $(seq 1 30); do
    if "$CURL" -fsS -o /dev/null "$1" 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

# refresh_apps: best-effort rescan so Radarr/Sonarr/Jellyfin notice files that appeared.
refresh_apps() {
  local jf; jf=$(env_get JELLYFIN_API_KEY)
  if [ -n "$(env_get RADARR_API_KEY)" ]; then
    wait_for_http "http://localhost:7878/ping" || echo "Radarr not reachable yet; rescan it from the UI"
    arr_api radarr POST /command '{"name":"RescanMovie"}' >/dev/null || echo "Radarr rescan failed; run it from the UI"
  fi
  if [ -n "$(env_get SONARR_API_KEY)" ]; then
    wait_for_http "http://localhost:8989/ping" || echo "Sonarr not reachable yet; rescan it from the UI"
    arr_api sonarr POST /command '{"name":"RescanSeries"}' >/dev/null || echo "Sonarr rescan failed; run it from the UI"
  fi
  if [ -n "$jf" ]; then
    "$CURL" -fsS -X POST -H "X-Emby-Token: $jf" "http://localhost:8096/Library/Refresh" >/dev/null \
      || echo "Jellyfin refresh failed; scan libraries from the UI"
  else
    echo "JELLYFIN_API_KEY not set: scan Jellyfin libraries from the UI"
  fi
}

cmd_sync() {
  local yes=0 arg
  for arg in "$@"; do
    case "$arg" in --yes) yes=1 ;; *) die "unknown option: $arg" ;; esac
  done
  load_config
  if ! is_mounted "$SSD_ROOT"; then
    die "external SSD is not mounted ($(volume_of "$SSD_ROOT")); nothing to sync to"
  fi
  local count
  count=$( { find "$INTERNAL_ROOT/torrents" "$INTERNAL_ROOT/media" -type f 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then echo "Nothing to sync: no files under $INTERNAL_ROOT"; return 0; fi

  echo "Will move from $INTERNAL_ROOT to $SSD_ROOT:"
  list_titles "$INTERNAL_ROOT" | while IFS="$(printf '\t')" read -r kind name; do echo "  [$kind] $name"; done
  echo "  ($count file(s), including torrent data in torrents/)"

  local need free
  need=$(du -sk "$INTERNAL_ROOT/torrents" "$INTERNAL_ROOT/media" 2>/dev/null | awk '{s+=$1} END{print s+0}')
  free=$(free_kb "$SSD_ROOT")
  if [ "$need" -gt "$free" ]; then
    die "not enough free space on the SSD: need ${need}K, have ${free}K"
  fi
  if ! rsync_preserves_hardlinks; then
    die "$RSYNC cannot preserve hardlinks. Run: brew install rsync, then set MEDIACTL_RSYNC=\$(brew --prefix)/bin/rsync"
  fi
  if [ "$yes" -ne 1 ]; then echo "Dry run only. Re-run with --yes to move."; return 0; fi

  acquire_lock
  echo "Stopping qbittorrent, radarr, sonarr..."
  compose_cmd stop qbittorrent radarr sonarr
  mkdir -p "$SSD_ROOT"
  echo "Copying (hardlinks preserved)..."
  "$RSYNC" -aH "$INTERNAL_ROOT/" "$SSD_ROOT/" \
    || die "rsync failed; internal files are untouched. Run: mediactl up, then retry sync"
  verify_copy "$INTERNAL_ROOT" "$SSD_ROOT"
  echo "Verified. Removing internal copies..."
  find "$INTERNAL_ROOT/torrents" "$INTERNAL_ROOT/media" -mindepth 1 -delete
  make_layout "$INTERNAL_ROOT"
  echo "Restarting stack on the SSD..."
  cmd_up
  refresh_apps
  echo "Sync complete."
}
```

In `main`, add: `sync) cmd_sync "$@" ;;`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all pass. If `test_rsync_probe_detects_hardlink_support` fails, the system openrsync does not preserve hardlinks: run `brew install rsync`, and set `MEDIACTL_RSYNC="$(brew --prefix)/bin/rsync"` in your shell/`.env` for real use. For the test, set it before running: `MEDIACTL_RSYNC="$(brew --prefix)/bin/rsync" bash tests/run.sh` (`setup_env` unsets it, so change `setup_env` to preserve an externally supplied value by capturing `${MEDIACTL_RSYNC:-}` before the `unset` and re-exporting it after). Make that change in `tests/run.sh` only if the probe fails.

- [ ] **Step 5: Commit**

```bash
git add mediactl tests/test_sync.sh tests/run.sh
git commit -m "feat: add mediactl sync to move internal media to the SSD safely"
```

---

### Task 5: `init-archive`

**Files:**
- Create: `tests/test_archive.sh` (this task adds the first tests; Task 6 appends)
- Modify: `mediactl` (add `jellyfin_api`, `cmd_init_archive`, dispatcher entry)

**Interfaces:**
- Consumes: `arr_api`, `env_get`, `CURL`, `require_archive_ready` (defined here, reused in Task 6).
- Produces: `jellyfin_api METHOD PATH [JSON]`, `require_archive_ready` (die unless the archive drive is mounted and Radarr has `/data/archive` mounted), `cmd_init_archive`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_archive.sh`:

```bash
archive_ready() { printf '/data /data/archive ' > "$TMP/docker_inspect"; }

test_require_archive_ready_checks_drive_and_container_mount() {
  printf '/data ' > "$TMP/docker_inspect"
  if out=$( (load_config; require_archive_ready) 2>&1 ); then fail "needs archive mounted in Radarr"; fi
  assert_contains "$out" "mediactl up --archive"
  MEDIACTL_FAKE_MOUNTED="$TMP/ssd"
  if out=$( (load_config; require_archive_ready) 2>&1 ); then fail "needs drive"; fi
  assert_contains "$out" "archive drive is not mounted"
  MEDIACTL_FAKE_MOUNTED="$TMP/ssd:$TMP/archive"; archive_ready
  (load_config; require_archive_ready) || fail "should pass when ready"
}

test_init_archive_adds_missing_root_folders() {
  archive_ready
  resp "GET /api/v3/rootfolder" '[{"path":"/data/media/movies/"}]'
  out=$(cmd_init_archive)
  assert_contains "$out" "radarr: added root folder /data/archive/movies"
  assert_contains "$out" "sonarr: added root folder /data/archive/tv"
  assert_contains "$(cat "$TMP/curl.log")" '"path":"/data/archive/movies"'
}

test_init_archive_is_idempotent() {
  archive_ready
  resp "GET /api/v3/rootfolder" '[{"path":"/data/archive/movies"},{"path":"/data/archive/tv/"}]'
  out=$(cmd_init_archive)
  assert_contains "$out" "radarr: root folder /data/archive/movies already present"
  assert_contains "$out" "sonarr: root folder /data/archive/tv already present"
  assert_not_contains "$(cat "$TMP/curl.log")" "-X POST"
}

test_init_archive_without_jellyfin_key_prints_manual_steps() {
  archive_ready
  out=$(cmd_init_archive)
  assert_contains "$out" "JELLYFIN_API_KEY not set"
}

test_init_archive_adds_jellyfin_paths_when_key_set() {
  archive_ready
  printf 'JELLYFIN_API_KEY=jk\n' >> "$TMP/.env"
  resp "GET /Library/VirtualFolders" '[{"Name":"Movies","Locations":["/data/media/movies"]},{"Name":"Shows","Locations":["/data/media/tv","/data/archive/tv"]}]'
  out=$(cmd_init_archive)
  assert_contains "$out" "jellyfin: added /data/archive/movies to library Movies"
  assert_contains "$out" "jellyfin: /data/archive/tv already in library Shows"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: new tests FAIL (`require_archive_ready: command not found`).

- [ ] **Step 3: Implement**

In `mediactl`, insert before the `# ---- dispatcher` section:

```bash
# ------------------------------------------------------- archive support
jellyfin_api() { # jellyfin_api METHOD PATH [JSON]
  local method=$1 path=$2 body=${3:-} key
  key=$(env_get JELLYFIN_API_KEY)
  if [ -z "$key" ]; then die "JELLYFIN_API_KEY is not set in .env"; fi
  local args=(-fsS -X "$method" -H "X-Emby-Token: $key" -H "Content-Type: application/json")
  if [ -n "$body" ]; then args+=(-d "$body"); fi
  "$CURL" "${args[@]}" "http://localhost:8096$path"
}

# require_archive_ready: needs load_config first.
require_archive_ready() {
  if [ -z "$ARCHIVE_ROOT" ]; then die "ARCHIVE_ROOT is not set in .env"; fi
  if ! is_mounted "$ARCHIVE_ROOT"; then die "archive drive is not mounted ($(volume_of "$ARCHIVE_ROOT"))"; fi
  local dest
  dest=$("$DOCKER" inspect radarr --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null) || dest=""
  case " $dest " in
    *" /data/archive "*) ;;
    *) die "Radarr does not have the archive mounted; run: mediactl up --archive" ;;
  esac
}

cmd_init_archive() {
  load_config
  require_archive_ready
  mkdir -p "$ARCHIVE_ROOT/movies" "$ARCHIVE_ROOT/tv"
  local pair app path n
  for pair in radarr:/data/archive/movies sonarr:/data/archive/tv; do
    app=${pair%%:*}; path=${pair#*:}
    n=$(arr_api "$app" GET /rootfolder | jq --arg p "$path" '[.[] | select(.path == $p or .path == ($p + "/"))] | length')
    if [ "$n" -gt 0 ]; then
      echo "$app: root folder $path already present"
    else
      arr_api "$app" POST /rootfolder "$(jq -nc --arg p "$path" '{path:$p}')" >/dev/null
      echo "$app: added root folder $path"
    fi
  done
  if [ -z "$(env_get JELLYFIN_API_KEY)" ]; then
    echo "JELLYFIN_API_KEY not set: in Jellyfin add /data/archive/movies and /data/archive/tv to your libraries by hand (Dashboard > Libraries)."
    return 0
  fi
  local movies_lib tv_lib folders
  movies_lib=$(env_get JELLYFIN_MOVIES_LIBRARY Movies); tv_lib=$(env_get JELLYFIN_TV_LIBRARY Shows)
  folders=$(jellyfin_api GET /Library/VirtualFolders)
  for pair in "$movies_lib:/data/archive/movies" "$tv_lib:/data/archive/tv"; do
    local lib=${pair%%:/*} p="/${pair#*:/}"
    n=$(printf '%s' "$folders" | jq --arg l "$lib" --arg p "$p" '[.[] | select(.Name == $l and (.Locations | index($p)))] | length')
    if [ "$n" -gt 0 ]; then
      echo "jellyfin: $p already in library $lib"
    else
      jellyfin_api POST "/Library/VirtualFolders/Paths?refreshLibrary=true" \
        "$(jq -nc --arg l "$lib" --arg p "$p" '{Name:$l, PathInfo:{Path:$p}}')" >/dev/null
      echo "jellyfin: added $p to library $lib"
    fi
  done
}
```

In `main`, add: `init-archive) cmd_init_archive ;;`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add mediactl tests/test_archive.sh
git commit -m "feat: add mediactl init-archive for Radarr, Sonarr and Jellyfin"
```

---

### Task 6: `archive` and `restore`

**Files:**
- Modify: `tests/test_archive.sh` (append)
- Modify: `mediactl` (add `find_titles`, `torrent_hashes`, `qbit_delete`, `cmd_move`, dispatcher entries)

**Interfaces:**
- Consumes: `arr_api`, `require_archive_ready`, `load_config`, `env_get`, `CURL`, `refresh_apps`.
- Produces: `find_titles APP QUERY PATH_PREFIX` (JSON lines `{id,title,year,path}`), `torrent_hashes APP ID` (lowercase hashes, one per line), `qbit_delete HASH_PIPE_LIST`, `cmd_move archive|restore [flags] TITLE...`.

- [ ] **Step 1: Write the failing tests (append to `tests/test_archive.sh`)**

```bash
MOVIES='[{"id":1,"title":"Heat","year":1995,"path":"/data/media/movies/Heat (1995)"},{"id":2,"title":"Heat Wave","year":2020,"path":"/data/media/movies/Heat Wave (2020)"},{"id":3,"title":"Alien","year":1979,"path":"/data/archive/movies/Alien (1979)"}]'
SERIES='[{"id":7,"title":"The Wire","year":2002,"path":"/data/media/tv/The Wire"}]'

test_find_titles_matches_case_insensitively_within_prefix() {
  resp "GET /api/v3/movie" "$MOVIES"
  out=$(find_titles radarr "heat" /data/media/)
  assert_contains "$out" '"id":1'
  assert_contains "$out" '"id":2'
  assert_not_contains "$out" '"id":3'
}

test_archive_without_yes_in_noninteractive_shell_moves_nothing() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  if out=$( (cmd_move archive Heat </dev/null) 2>&1 ); then fail "should require --yes"; fi
  assert_contains "$out" "pass --yes"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null)" "/movie/editor"
}

test_archive_with_no_matches_fails_cleanly() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  if out=$( (cmd_move archive Nonexistent --yes) 2>&1 ); then fail "should fail"; fi
  assert_contains "$out" "no titles matching"
}

test_archive_lists_all_matches_then_moves_via_editor_api() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"; resp "GET /api/v3/series" "$SERIES"
  out=$(cmd_move archive Heat Wire --yes)
  assert_contains "$out" "Heat (1995)"
  assert_contains "$out" "Heat Wave (2020)"
  assert_contains "$out" "The Wire"
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" '"movieIds":[1,2]'
  assert_contains "$log" '"rootFolderPath":"/data/archive/movies"'
  assert_contains "$log" '"moveFiles":true'
  assert_contains "$log" '"seriesIds":[7]'
  assert_contains "$log" '"rootFolderPath":"/data/archive/tv"'
}

test_restore_moves_archived_titles_back() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  out=$(cmd_move restore Alien --yes)
  assert_contains "$out" "Alien (1979)"
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" '"movieIds":[3]'
  assert_contains "$log" '"rootFolderPath":"/data/media/movies"'
}

test_archive_does_not_touch_torrents_without_flag() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABCDEF"}]'
  out=$(cmd_move archive "Heat (1995)" --yes </dev/null 2>&1) || true
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
  assert_contains "$out" "--remove-torrents"
}

test_archive_remove_torrents_deletes_by_history_hash() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABCDEF"},{"downloadId":"ABCDEF"}]'
  cmd_move archive "Heat (1995)" --yes --remove-torrents >/dev/null
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" "hashes=abcdef"
  assert_contains "$log" "deleteFiles=true"
}

test_archive_remove_torrents_without_qbit_credentials_explains() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABCDEF"}]'
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "QBIT_USER/QBIT_PASSWORD not set"
  assert_contains "$out" "abcdef"
}

test_archive_requires_archive_ready() {
  printf '/data ' > "$TMP/docker_inspect"
  if out=$( (cmd_move archive Heat --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "mediactl up --archive"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh`
Expected: the new tests FAIL (`find_titles: command not found`).

- [ ] **Step 3: Implement**

In `mediactl`, insert before the `# ---- dispatcher` section:

```bash
# ------------------------------------------------------- archive/restore
# find_titles APP QUERY PATH_PREFIX: JSON lines for titles whose name contains QUERY
# (case-insensitive) and whose path starts with PATH_PREFIX.
find_titles() {
  local endpoint=movie
  if [ "$1" = sonarr ]; then endpoint=series; fi
  arr_api "$1" GET "/$endpoint" | jq -c \
    --arg q "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" --arg prefix "$3" \
    '.[] | select((.title | ascii_downcase | contains($q)) and (.path | startswith($prefix))) | {id, title, year, path}'
}

# torrent_hashes APP ID: lowercase info-hashes of releases grabbed for that title.
torrent_hashes() {
  local url="/history/movie?movieId=$2&eventType=1"
  if [ "$1" = sonarr ]; then url="/history/series?seriesId=$2&eventType=1"; fi
  arr_api "$1" GET "$url" | jq -r '.[].downloadId // empty' | tr 'A-Z' 'a-z' | sort -u
}

qbit_delete() { # qbit_delete "hash1|hash2"
  local user pass jar
  user=$(env_get QBIT_USER); pass=$(env_get QBIT_PASSWORD)
  if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "QBIT_USER/QBIT_PASSWORD not set: remove these torrents (with data) in qBittorrent by hand: $1"
    return 0
  fi
  jar=$(mktemp)
  "$CURL" -fsS -c "$jar" --data-urlencode "username=$user" --data-urlencode "password=$pass" \
    "http://localhost:5080/api/v2/auth/login" >/dev/null
  "$CURL" -fsS -b "$jar" -X POST --data-urlencode "hashes=$1" -d "deleteFiles=true" \
    "http://localhost:5080/api/v2/torrents/delete" >/dev/null
  rm -f "$jar"
  echo "Removed torrent(s) and data from qBittorrent."
}

ask_yes() { # ask_yes PROMPT: true only on an interactive "y"
  local reply=""
  if [ ! -t 0 ]; then return 1; fi
  read -r -p "$1 [y/N] " reply
  [ "$reply" = y ] || [ "$reply" = Y ]
}

cmd_move() {
  local dir=$1; shift
  local yes=0 rm_torrents=0 terms=() arg
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1 ;;
      --remove-torrents) rm_torrents=1 ;;
      -*) die "unknown option: $arg" ;;
      *) terms+=("$arg") ;;
    esac
  done
  if [ "${#terms[@]}" -eq 0 ]; then die "usage: mediactl $dir [--yes] TITLE..."; fi
  load_config
  require_archive_ready
  local from to_movies to_tv
  if [ "$dir" = archive ]; then
    from=/data/media/; to_movies=/data/archive/movies; to_tv=/data/archive/tv
  else
    from=/data/archive/; to_movies=/data/media/movies; to_tv=/data/media/tv
  fi
  local work; work=$(mktemp -d)
  local term
  for term in "${terms[@]}"; do
    find_titles radarr "$term" "$from" >> "$work/radarr.jsonl" || true
    find_titles sonarr "$term" "$from" >> "$work/sonarr.jsonl" || true
  done
  touch "$work/radarr.jsonl" "$work/sonarr.jsonl"
  sort -u "$work/radarr.jsonl" -o "$work/radarr.jsonl"; sort -u "$work/sonarr.jsonl" -o "$work/sonarr.jsonl"
  if [ ! -s "$work/radarr.jsonl" ] && [ ! -s "$work/sonarr.jsonl" ]; then
    rm -rf "$work"; die "no titles matching: ${terms[*]} (under $from)"
  fi
  echo "Will $dir:"
  jq -r '"  movie  [\(.id)] \(.title) (\(.year))  \(.path)"' "$work/radarr.jsonl"
  jq -r '"  show   [\(.id)] \(.title) (\(.year))  \(.path)"' "$work/sonarr.jsonl"
  if [ "$yes" -ne 1 ]; then
    if [ ! -t 0 ]; then rm -rf "$work"; die "not an interactive shell: pass --yes to confirm the list above"; fi
    if ! ask_yes "Proceed?"; then rm -rf "$work"; echo "Cancelled."; return 0; fi
  fi
  acquire_lock
  local rids sids hashes="" id
  rids=$(jq -s -c '[.[].id]' "$work/radarr.jsonl"); sids=$(jq -s -c '[.[].id]' "$work/sonarr.jsonl")
  if [ "$dir" = archive ]; then
    for id in $(jq -r '.id' "$work/radarr.jsonl"); do hashes="$hashes
$(torrent_hashes radarr "$id")"; done
    for id in $(jq -r '.id' "$work/sonarr.jsonl"); do hashes="$hashes
$(torrent_hashes sonarr "$id")"; done
    hashes=$(printf '%s\n' "$hashes" | sed '/^$/d' | sort -u | paste -sd'|' -)
  fi
  if [ "$rids" != "[]" ]; then
    arr_api radarr PUT /movie/editor "{\"movieIds\":$rids,\"rootFolderPath\":\"$to_movies\",\"moveFiles\":true}" >/dev/null
  fi
  if [ "$sids" != "[]" ]; then
    arr_api sonarr PUT /series/editor "{\"seriesIds\":$sids,\"rootFolderPath\":\"$to_tv\",\"moveFiles\":true}" >/dev/null
  fi
  echo "Move requested; Radarr/Sonarr are moving the files (watch Activity in their UI)."
  if [ "$dir" = archive ] && [ -n "$hashes" ]; then
    if [ "$rm_torrents" -eq 1 ] || ask_yes "Remove the matching torrent(s) and data from qBittorrent so SSD space is actually freed?"; then
      qbit_delete "$hashes"
    else
      echo "Torrent data left in place, so the SSD copy keeps using space. Re-run with --remove-torrents to free it."
    fi
  fi
  rm -rf "$work"
  refresh_apps
}
```

In `main`, add: `archive) cmd_move archive "$@" ;;` and `restore) cmd_move restore "$@" ;;`

Notes for the implementer: `cmd_move` calls `refresh_apps`, which in tests only hits the stub. `test_archive_does_not_touch_torrents_without_flag` pipes `</dev/null`, so `ask_yes` returns false and the "--remove-torrents" hint prints.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add mediactl tests/test_archive.sh
git commit -m "feat: add mediactl archive and restore via Radarr/Sonarr editor API"
```

---

### Task 7: `.env.example`, documentation, and end-to-end smoke check

**Files:**
- Create: `.env.example`
- Modify: `CLAUDE.md` (Commands and Configuration sections)
- Modify: `README.md` (add a "Storage modes and mediactl" section)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Create `.env.example`**

```bash
# Copy to .env (gitignored) and fill in. Never commit real values.

# --- Storage (see mediactl) ---
DATA_ROOT=/Volumes/MediaServer/data          # external SSD (main storage)
INTERNAL_DATA_ROOT=/Users/you/media-stack-data  # temporary storage when the SSD is unplugged
ARCHIVE_ROOT=/Volumes/Archive/media-archive  # archive drive; leave empty to disable

# --- mediactl API access (Radarr/Sonarr: Settings > General > API Key) ---
RADARR_API_KEY=
SONARR_API_KEY=
# Optional: Jellyfin (Dashboard > API Keys) for library refresh / init-archive
JELLYFIN_API_KEY=
JELLYFIN_MOVIES_LIBRARY=Movies
JELLYFIN_TV_LIBRARY=Shows
# Optional: qBittorrent WebUI login, only for `mediactl archive --remove-torrents`
QBIT_USER=
QBIT_PASSWORD=
# Optional: path to a hardlink-capable rsync (macOS's built-in openrsync may not be)
# MEDIACTL_RSYNC=/opt/homebrew/bin/rsync

# --- VPN and network (existing) ---
VPN_SERVICE_PROVIDER=
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=
WIREGUARD_ADDRESSES=
VPN_PORT_FORWARDING=
SERVER_COUNTRIES=
RADARR_STATIC_CONTAINER_IP=172.20.0.100
SONARR_STATIC_CONTAINER_IP=172.20.0.101
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the `## Commands` code block, after the `docker compose --profile vpn up -d` lines, add:

```bash
# Preferred: start in the right storage mode for whichever drives are mounted
./mediactl up                 # main (SSD) / internal fallback, + archive if mounted
./mediactl status             # drives, free space, running mode, pending sync
./mediactl sync [--yes]       # move internal-drive media to the SSD (dry run by default)
./mediactl init-archive       # one-time: archive root folders in Radarr/Sonarr/Jellyfin
./mediactl archive [--yes] [--remove-torrents] TITLE...
./mediactl restore [--yes] TITLE...
bash tests/run.sh             # mediactl unit tests (stubbed docker/curl)
```

Under `## Architecture`, add a `**Storage modes (mediactl).**` paragraph: modes `main`/`internal`/`archive`; container paths identical in all modes (only the host folder behind `/data` changes); `docker-compose.archive.yml` adds `/data/archive` (rw for Radarr/Sonarr, ro for Jellyfin); `sync` is host-side `rsync -aH` of the whole internal root (needs a hardlink-capable rsync, the macOS built-in one may not be); `archive`/`restore` move through the Radarr/Sonarr editor API; archiving frees no space until the seeding torrent is removed. Under `## Configuration`, list the new variables from `.env.example`.

- [ ] **Step 3: Update `README.md`**

Add a "Storage modes and mediactl" section (before the VPN or reverse-proxy sections) with: the three modes in a table, the command list above with a one-line description each, the one-time `brew install rsync` note, the first-time archive flow (`./mediactl up --archive`, `./mediactl init-archive`, `./mediactl archive "Some Movie" --remove-torrents`), and a note that it is macOS/Docker Desktop only.

- [ ] **Step 4: Smoke check against the real compose file (no data moved)**

Run each and confirm the expected result:

```bash
bash tests/run.sh                     # Expected: all pass, 0 failed
./mediactl help                       # Expected: usage text
./mediactl up --dry-run               # Expected: "Mode: ..." line and an env DATA_ROOT=... docker compose ... command
./mediactl status                     # Expected: drive lines; no secrets printed
DATA_ROOT=/tmp/x ARCHIVE_ROOT=/tmp/y docker compose --profile vpn -f docker-compose.yml -f docker-compose.archive.yml config >/dev/null && echo OK
git status --short                    # Expected: .env NOT listed (gitignored)
```

- [ ] **Step 5: Commit**

```bash
git add .env.example CLAUDE.md README.md
git commit -m "docs: document storage modes and mediactl, add .env.example"
```

---

## Self-Review

- **Spec coverage:** modes and auto-detect (Tasks 1-2); refuse when a drive is missing (Tasks 2, 4, 5, 6); archive override with rw/ro mounts (Task 2); `status` including pending sync and offline archived titles (Task 3); `sync` with dry run, stop/rsync -aH/verify/delete/restart/rescan (Task 4); `init-archive` for Radarr, Sonarr, Jellyfin (Task 5); `archive`/`restore` through the editor API with torrent-removal consent (Task 6); safety rules (dry-run, verify-before-delete, lock, no secrets printed) (Tasks 4, 6); new `.env` variables, `.env.example`, CLAUDE.md and README updates (Task 7). Out-of-scope items are not implemented.
- **Placeholders:** none; every code step contains the code to write.
- **Type and name consistency:** `resolve_plan`/`MODE`/`WITH_ARCHIVE`/`ACTIVE_ROOT`, `list_titles`, `count_kind`, `arr_api`, `jellyfin_api`, `require_archive_ready`, `acquire_lock`, `refresh_apps`, `make_layout`, `compose_cmd` are defined once and used with matching signatures. `make_layout` and `compose_cmd` (Task 2) are used by `cmd_sync` (Task 4); `arr_api` (Task 3) is used by Tasks 4-6.
- **Known risks to watch during execution:** (1) macOS's built-in openrsync may not preserve hardlinks, so the probe in Task 4 may require `brew install rsync`; (2) `docker inspect` mount sources on Docker Desktop may carry a `/host_mnt` prefix, handled in `running_data_root`; (3) the Radarr/Sonarr editor and history endpoints and Jellyfin's `/Library/VirtualFolders/Paths` shape should be checked against the installed versions on the first real run, using a single throwaway title before archiving anything you care about.
