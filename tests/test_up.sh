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

test_stop_calls_compose_stop_with_all_profiles() {
  cmd_stop >/dev/null
  assert_contains "$(cat "$TMP/docker.log")" "compose --profile vpn --profile recommendarr stop"
}

test_stop_down_flag_and_unknown_option() {
  cmd_stop --down >/dev/null
  assert_contains "$(cat "$TMP/docker.log")" "compose --profile vpn --profile recommendarr down"
  if out=$( (cmd_stop --bogus) 2>&1 ); then fail "unknown flag"; fi
  assert_contains "$out" "unknown option: --bogus"
}
