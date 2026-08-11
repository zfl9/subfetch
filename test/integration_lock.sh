#!/bin/sh
# flock concurrency integration test: a second instance must block on the run lock
# (with a waiting log line) instead of racing, then complete after the holder
# releases. isolated XDG_STATE_HOME, --no-reload, --no-verify.
set -eu

echo "=== integration-lock ==="

EXE=$1
WORK=$2
mkdir -p "$WORK"
TMP=$(mktemp -d "$WORK/lock.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
mkdir -p "$XDG_STATE_HOME/subfetch"

# holder: takes the run lock for ~2s, then releases
(
    exec 9>"$XDG_STATE_HOME/subfetch/lock"
    flock -x 9
    sleep 2
) &
HOLDER=$!

# let the holder acquire first
sleep 0.5

set +e
"$EXE" -c fixtures/config.zon -o raw="$TMP/out.json" --no-reload --no-verify >"$TMP/log" 2>&1
got=$?
set -e
wait "$HOLDER" || true

[ "$got" -eq 0 ] || { echo "FAIL: concurrent run: want 0, got $got"; cat "$TMP/log"; exit 1; }
grep -q "another subfetch instance is running, waiting" "$TMP/log" || {
    echo "FAIL: no waiting log line"; cat "$TMP/log"; exit 1
}
echo "ok: concurrent run waited and completed"

echo "integration-lock OK"
