seed_internal() {
  make_layout "$TMP/internal"
  mkdir -p "$TMP/internal/media/movies/Don't Look Up (2021)"
  printf 'movie-bytes' > "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv"
  ln "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" \
     "$TMP/internal/media/movies/Don't Look Up (2021)/Don't Look Up (2021).mkv"
}

need_hardlink_rsync() {
  if ! rsync_preserves_hardlinks; then
    echo "SKIP: rsync cannot preserve hardlinks" >&2
    return 1
  fi
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
  need_hardlink_rsync || return 0
  rsync_preserves_hardlinks || fail "probe should pass"
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
  need_hardlink_rsync || return 0
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
