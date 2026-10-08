# archive_ready: archive mounted in the containers, stack running on $TMP/ssd, and the
# fixture titles present on disk (media titles on the SSD, Alien on the archive drive).
archive_ready() {
  printf '/data /data/archive ' > "$TMP/docker_inspect"
  printf '%s' "$TMP/ssd" > "$TMP/docker_inspect_src"
  mkdir -p "$TMP/ssd/media/movies/Heat (1995)" "$TMP/ssd/media/movies/Heat Wave (2020)" \
           "$TMP/ssd/media/tv/The Wire" "$TMP/archive/movies/Alien (1979)"
}

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
  hist_for ABCDEF 1
  cmd_move archive "Heat (1995)" --yes --remove-torrents >/dev/null
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" "hashes=abcdef"
  assert_contains "$log" "deleteFiles=true"
}

test_archive_remove_torrents_without_qbit_credentials_explains() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABCDEF"}]'
  hist_for ABCDEF 1
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "QBIT_USER/QBIT_PASSWORD not set"
  assert_contains "$out" "abcdef"
}

test_archive_requires_archive_ready() {
  printf '/data ' > "$TMP/docker_inspect"
  if out=$( (cmd_move archive Heat --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "mediactl up --archive"
}

# hist_for HASH_UPPER ID...: canned /history?downloadId reply like Radarr (uppercase downloadId)
hist_for() {
  local h=$1 recs="" id; shift
  for id in "$@"; do recs="$recs${recs:+,}{\"movieId\":$id,\"downloadId\":\"$h\"}"; done
  resp "GET /api/v3/history?downloadId=$h&pageSize=1000" "{\"totalRecords\":$#,\"records\":[$recs]}"
}

big_movies() { # 26 archivable titles
  seq 1 26 | jq -R -s -c 'split("\n") | map(select(length>0) | tonumber | {id:., title:("Film "+tostring), year:2000, path:("/data/media/movies/Film "+tostring)})'
}

big_folders() { local i; for i in $(seq 1 26); do mkdir -p "$TMP/ssd/media/movies/Film $i"; done; }

test_empty_term_refused_before_any_call() {
  archive_ready
  if out=$( (cmd_move archive "" --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "empty title term"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null)" "/api/v3"
}

test_whitespace_term_refused() {
  archive_ready
  if out=$( (cmd_move archive "   " --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "empty title term"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null)" "/movie/editor"
}

test_match_count_line_is_printed() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  out=$(cmd_move archive Heat --yes)
  assert_contains "$out" "Matched: 2 movie(s), 0 show(s)"
}

test_more_than_25_matches_refused_without_all() {
  archive_ready; big_folders; resp "GET /api/v3/movie" "$(big_movies)"
  if out=$( (cmd_move archive Film --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "--all"
  assert_not_contains "$(cat "$TMP/curl.log")" "/movie/editor"
}

test_more_than_25_matches_allowed_with_all() {
  archive_ready; big_folders; resp "GET /api/v3/movie" "$(big_movies)"
  out=$(cmd_move archive Film --yes --all)
  assert_contains "$out" "Matched: 26 movie(s)"
  assert_contains "$(cat "$TMP/curl.log")" "/movie/editor"
}

test_shared_hash_is_skipped_not_deleted() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"AAA"},{"downloadId":"BBB"}]'
  hist_for AAA 1 99
  hist_for BBB 1
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "skipping aaa: also used by title id 99 that is not being archived"
  log=$(cat "$TMP/curl.log")
  assert_contains "$log" "hashes=bbb"
  assert_not_contains "$(grep torrents/delete "$TMP/curl.log"; grep 'hashes=' "$TMP/curl.log")" "aaa"
}

test_torrent_info_listed_before_delete_and_after_moves() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"; resp "GET /api/v3/series" "$SERIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  hist_for ABC 1
  resp "GET /api/v2/torrents/info?hashes=abc" '[{"name":"Heat.1995.1080p","size":123456,"save_path":"/data/torrents/movies"}]'
  out=$(cmd_move archive "Heat (1995)" The\ Wire --yes --remove-torrents)
  assert_contains "$out" "Heat.1995.1080p  123456 bytes  /data/torrents/movies"
  n_info=$(grep -n 'torrents/info' "$TMP/curl.log" | head -1 | cut -d: -f1)
  n_del=$(grep -n 'torrents/delete' "$TMP/curl.log" | head -1 | cut -d: -f1)
  n_put1=$(grep -n 'movie/editor' "$TMP/curl.log" | head -1 | cut -d: -f1)
  n_put2=$(grep -n 'series/editor' "$TMP/curl.log" | head -1 | cut -d: -f1)
  [ "$n_info" -lt "$n_del" ] || fail "info must precede delete"
  [ "$n_put1" -lt "$n_del" ] && [ "$n_put2" -lt "$n_del" ] || fail "delete must follow both editor PUTs"
}

test_stuck_move_leaves_torrents_in_place() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0 MEDIACTL_MOVE_TIMEOUT=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  resp "GET /api/v3/command" '[{"name":"MoveMovie","status":"started"}]'
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "Moves still running; torrents left in place. Re-run with --remove-torrents later."
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_idle_command_queue_allows_delete() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0 MEDIACTL_MOVE_TIMEOUT=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  hist_for ABC 1
  resp "GET /api/v3/command" '[{"name":"RefreshMovie","status":"started"},{"name":"MoveMovie","status":"completed"}]'
  cmd_move archive "Heat (1995)" --yes --remove-torrents >/dev/null
  assert_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_empty_history_records_means_skipped_not_deleted() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  resp "GET /api/v3/history?downloadId=ABC&pageSize=1000" '{"totalRecords":0,"records":[]}'
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "skipping abc: could not confirm it belongs only to archived titles"
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_unrelated_only_history_is_skipped() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  hist_for ABC 55
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "skipping abc: also used by title id 55"
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_truncated_history_page_is_skipped() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  resp "GET /api/v3/history?downloadId=ABC&pageSize=1000" '{"totalRecords":5,"records":[{"movieId":1,"downloadId":"ABC"}]}'
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "could not confirm"
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_failed_history_lookup_is_skipped() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  : > "$TMP/resp/FAIL_GET__api_v3_history_downloadId_ABC_pageSize_1000"
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "could not confirm"
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_command_endpoint_failing_never_counts_as_idle() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  hist_for ABC 1
  : > "$TMP/resp/FAIL_GET__api_v3_command"
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "could not read command status from radarr; torrents left in place"
  assert_not_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_transient_command_failure_then_idle_deletes() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  printf 'QBIT_USER=u\nQBIT_PASSWORD=p\n' >> "$TMP/.env"
  export MEDIACTL_POLL_SECS=0
  resp "GET /api/v3/history/movie?movieId=1&eventType=1" '[{"downloadId":"ABC"}]'
  hist_for ABC 1
  printf 2 > "$TMP/resp/FAILN_GET__api_v3_command"
  out=$(cmd_move archive "Heat (1995)" --yes --remove-torrents)
  assert_contains "$out" "Waiting for Radarr/Sonarr to finish moving files..."
  assert_contains "$(cat "$TMP/curl.log")" "torrents/delete"
}

test_require_archive_ready_checks_sonarr_mount_too() {
  archive_ready
  printf '/data ' > "$TMP/docker_inspect_sonarr"
  if out=$( (load_config; require_archive_ready) 2>&1 ); then fail "sonarr without the mount must refuse"; fi
  assert_contains "$out" "sonarr"
  assert_contains "$out" "mediactl up --archive"
  printf '/data /data/archive ' > "$TMP/docker_inspect_sonarr"
  (load_config; require_archive_ready) || fail "should pass when both have the mount"
}

test_archive_refuses_when_title_folder_missing_and_changes_nothing() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"; resp "GET /api/v3/series" "$SERIES"
  rmdir "$TMP/ssd/media/movies/Heat Wave (2020)"
  if out=$( (cmd_move archive Heat Wire --yes --remove-torrents) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "Heat Wave (2020)"
  assert_contains "$out" "$TMP/ssd/media/movies/Heat Wave (2020)"
  assert_contains "$out" "mediactl up"
  log=$(cat "$TMP/curl.log" 2>/dev/null || true)
  assert_not_contains "$log" "/editor"
  assert_not_contains "$log" "torrents/delete"
}

test_restore_refuses_when_archive_folder_missing() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  rmdir "$TMP/archive/movies/Alien (1979)"
  if out=$( (cmd_move restore Alien --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "$TMP/archive/movies/Alien (1979)"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null || true)" "/editor"
}

test_archive_refuses_when_stack_not_running() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  : > "$TMP/docker_inspect_src"
  if out=$( (cmd_move archive Heat --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "not running"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null || true)" "/editor"
}

test_archive_refuses_when_archive_drive_lacks_space() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  head -c 204800 /dev/zero > "$TMP/ssd/media/movies/Heat (1995)/a.mkv"
  free_kb() { echo 10; }
  if out=$( (cmd_move archive "Heat (1995)" --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "not enough free space on the archive drive"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null || true)" "/editor"
}

test_archive_proceeds_when_archive_drive_has_space() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  head -c 204800 /dev/zero > "$TMP/ssd/media/movies/Heat (1995)/a.mkv"
  free_kb() { echo 99999999; }
  cmd_move archive "Heat (1995)" --yes >/dev/null
  assert_contains "$(cat "$TMP/curl.log")" '"movieIds":[1]'
}

test_restore_refuses_when_data_root_lacks_space() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  head -c 204800 /dev/zero > "$TMP/archive/movies/Alien (1979)/a.mkv"
  free_kb() { echo 10; }
  if out=$( (cmd_move restore Alien --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "not enough free space"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null || true)" "/editor"
}

test_archive_refuses_when_free_space_unreadable() {
  archive_ready; resp "GET /api/v3/movie" "$MOVIES"
  free_kb() { echo ""; }
  if out=$( (cmd_move archive "Heat (1995)" --yes) 2>&1 ); then fail "should refuse"; fi
  assert_contains "$out" "free space"
  assert_not_contains "$(cat "$TMP/curl.log" 2>/dev/null || true)" "/editor"
}
