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
