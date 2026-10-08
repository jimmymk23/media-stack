#!/usr/bin/env bash
# Minimal test runner. Sources tests/test_*.sh and runs every function named test_*
# in its own subshell with a fresh temp dir and stubbed docker/curl.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT

fail() { echo "    FAIL: $*" >&2; exit 1; }
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
