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
  is_mounted "$TMP/ssd" || fail "ssd should count as mounted"
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
