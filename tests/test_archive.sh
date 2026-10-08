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

MOVIES='[{"id":1,"title":"Heat","year":1995,"path":"/data/media/movies/Heat (1995)"},{"id":2,"title":"Heat Wave","year":2020,"path":"/data/media/movies/Heat Wave (2020)"},{"id":3,"title":"Alien","year":1979,"path":"/data/archive/movies/Alien (1979)"}]'
SERIES='[{"id":7,"title":"The Wire","year":2002,"path":"/data/media/tv/The Wire"}]'

test_find_titles_matches_case_insensitively_within_prefix() {
  resp "GET /api/v3/movie" "$MOVIES"
  out=$(find_titles radarr "heat" /data/media/)
  assert_contains "$out" '"id":1'
  assert_contains "$out" '"id":2'
  assert_not_contains "$out" '"id":3'
}

test_find_titles_matches_title_with_year() {
  resp "GET /api/v3/movie" "$MOVIES"
  out=$(find_titles radarr "Heat (1995)" /data/media/)
  assert_contains "$out" '"id":1'
  assert_not_contains "$out" '"id":2'
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
