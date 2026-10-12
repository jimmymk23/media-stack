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

test_dashboard_once_shows_sections_and_vpn_warning() {
  out=$(cmd_dashboard --once)
  assert_contains "$out" "Storage"
  assert_contains "$out" "Containers"
  assert_contains "$out" "qBittorrent IP: unreachable"
}

test_dashboard_rejects_bad_options() {
  if out=$( (cmd_dashboard --interval abc) 2>&1 ); then fail "bad interval"; fi
  assert_contains "$out" "--interval needs a positive number"
  if out=$( (cmd_dashboard --bogus) 2>&1 ); then fail "unknown flag"; fi
  assert_contains "$out" "unknown option: --bogus"
}
