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
  assert_contains "$log" "compose --profile vpn stop qbittorrent radarr sonarr jellyfin"
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
  assert_contains "$out" "Run: mediactl up"
  assert_contains "$(cat "$TMP/docker.log")" "stop qbittorrent radarr sonarr jellyfin"
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

set_roots() { # set_roots INTERNAL SSD
  printf 'DATA_ROOT=%s\nINTERNAL_DATA_ROOT=%s\nARCHIVE_ROOT=%s\nRADARR_API_KEY=rk\nSONARR_API_KEY=sk\n' \
    "$2" "$1" "$TMP/archive" > "$TMP/.env"
  MEDIACTL_FAKE_MOUNTED="$2"
}

assert_overlap_refused() {
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "overlapping roots should refuse"; fi
  assert_contains "$out" "overlap"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "internal data must be untouched"
  if grep -q stop "$TMP/docker.log" 2>/dev/null; then fail "must not stop the stack"; fi
}

test_sync_refuses_equal_roots() {
  seed_internal; set_roots "$TMP/internal" "$TMP/internal"
  assert_overlap_refused
}

test_sync_refuses_internal_nested_in_ssd() {
  seed_internal; set_roots "$TMP/internal" "$TMP"
  assert_overlap_refused
}

test_sync_refuses_ssd_nested_in_internal() {
  seed_internal; set_roots "$TMP/internal" "$TMP/internal/sub/ssd"
  assert_overlap_refused
}

test_sync_refuses_ssd_symlink_to_internal() {
  seed_internal; rmdir "$TMP/ssd"; ln -s "$TMP/internal" "$TMP/ssd"
  set_roots "$TMP/internal" "$TMP/ssd"
  assert_overlap_refused
}

test_sync_allows_sibling_prefix_roots() {
  need_hardlink_rsync || return 0
  mkdir -p "$TMP/ssd2"; seed_internal; set_roots "$TMP/ssd" "$TMP/ssd2"
  rmdir "$TMP/ssd"; mv "$TMP/internal" "$TMP/ssd"
  out=$(cmd_sync --yes 2>&1) || fail "sibling roots should be allowed: $out"
  [ -f "$TMP/ssd2/torrents/movies/Don't Look Up (2021).mkv" ] || fail "file not copied"
}

test_sync_failure_after_stop_prints_recovery_notice() {
  seed_internal
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/rsync"; chmod +x "$TMP/bin/rsync"
  RSYNC="$TMP/bin/rsync"
  rsync_preserves_hardlinks() { return 0; }
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "should fail"; fi
  assert_contains "$out" "sync did not finish. The stack is stopped. Run: mediactl up"
  [ -f "$TMP/internal/torrents/movies/Don't Look Up (2021).mkv" ] || fail "internal copy must be kept"
  [ ! -e "$LOCK_DIR" ] || fail "lock should be released"
}

test_sync_success_prints_no_notice_and_releases_lock() {
  need_hardlink_rsync || return 0
  seed_internal
  out=$( (cmd_sync --yes) 2>&1 )
  assert_not_contains "$out" "did not finish"
  [ ! -e "$LOCK_DIR" ] || fail "lock should be released"
}

# refused_untouched OUT_SUBSTRING [FILE]: sync must refuse, keep internal data, never stop the stack
refused_untouched() {
  local want=$1 file=${2:-"$TMP/internal/torrents/movies/Don't Look Up (2021).mkv"}
  if out=$( (cmd_sync --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "$want"
  [ -f "$file" ] || fail "internal data must be untouched"
  if grep -q stop "$TMP/docker.log" 2>/dev/null; then fail "must not stop the stack"; fi
}

test_sync_refuses_case_variant_roots() {
  mkdir "$TMP/CaseProbe"
  if [ ! -d "$TMP/caseprobe" ]; then echo "SKIP: case-sensitive filesystem" >&2; return 0; fi
  mkdir -p "$TMP/box/data"; make_layout "$TMP/box/data"
  printf 'only-copy' > "$TMP/box/data/torrents/movies/x.mkv"
  set_roots "$TMP/box/data" "$TMP/Box/data"
  refused_untouched "overlap" "$TMP/box/data/torrents/movies/x.mkv"
  assert_eq "only-copy" "$(cat "$TMP/box/data/torrents/movies/x.mkv")"
}

test_sync_refuses_dotdot_in_existing_path() {
  seed_internal; set_roots "$TMP/internal" "$TMP/ssd/../internal"
  refused_untouched "'..'"
}

test_sync_refuses_dotdot_in_missing_tail() {
  seed_internal; set_roots "$TMP/internal" "$TMP/new/../internal"
  refused_untouched "'..'"
}

test_sync_refuses_dotdot_in_internal_root() {
  seed_internal; set_roots "$TMP/ssd/../internal" "$TMP/ssd"
  refused_untouched "'..'"
}

test_sync_refuses_missing_ssd_tail_aliasing_internal_via_symlink() {
  seed_internal; ln -s "$TMP/internal" "$TMP/link"
  set_roots "$TMP/internal" "$TMP/link/data"
  refused_untouched "overlap"
}

test_sync_dry_run_also_refuses_overlap() {
  seed_internal; ln -s "$TMP/internal" "$TMP/link"
  set_roots "$TMP/internal" "$TMP/link/data"
  if out=$( (cmd_sync) 2>&1 ); then fail "dry run should refuse too"; fi
  assert_contains "$out" "overlap"
}

test_sync_refuses_when_free_space_is_empty() {
  seed_internal
  free_kb() { echo ""; }
  refused_untouched "free space"
}

test_sync_refuses_when_free_space_is_not_numeric() {
  seed_internal
  free_kb() { echo "abc"; }
  refused_untouched "free space"
}

test_up_refuses_while_another_mediactl_holds_the_lock() {
  sleep 30 & live=$!
  mkdir "$LOCK_DIR"; echo "$live" > "$LOCK_DIR/pid"
  if out=$( (cmd_up) 2>&1 ); then kill "$live"; fail "up should refuse under a live lock"; fi
  kill "$live"
  assert_contains "$out" "another mediactl is running"
  if grep -q "up -d" "$TMP/docker.log" 2>/dev/null; then fail "must not start containers"; fi
}

test_up_dry_run_ignores_the_lock() {
  sleep 30 & live=$!
  mkdir "$LOCK_DIR"; echo "$live" > "$LOCK_DIR/pid"
  out=$( (cmd_up --dry-run) 2>&1 ) || { kill "$live"; fail "dry run should not need the lock"; }
  kill "$live"
}

test_up_releases_its_lock_and_is_reentrant_under_sync() {
  need_hardlink_rsync || return 0
  seed_internal
  out=$( (cmd_sync --yes) 2>&1 ) || fail "sync must not deadlock on its own lock: $out"
  assert_contains "$(cat "$TMP/docker.log")" "up -d"
  ( cmd_up >/dev/null ) || fail "up should run"
  [ ! -e "$LOCK_DIR" ] || fail "lock should be released"
}
