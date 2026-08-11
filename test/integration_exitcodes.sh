#!/bin/sh
# exit-code semantics + --reset-state file handling.
# isolated: XDG_STATE_HOME points into the build cache dir.
#
# exit codes: 0 success / 1 runtime (io, install) / 2 usage / 3 config & data
# / 4 any subscription/node-file source failed (cron must not see success).
set -eu

echo "=== integration-exitcodes ==="

EXE=$1
WORK=$2
mkdir -p "$WORK"
TMP=$(mktemp -d "$WORK/exitcodes.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"

expect_exit() { # expect_exit <code> <name> cmd...
    want=$1; name=$2; shift 2
    set +e
    "$@" >/dev/null 2>"$TMP/log"
    got=$?
    set -e
    if [ "$got" != "$want" ]; then
        echo "FAIL: $name: want exit $want, got $got"
        cat "$TMP/log"
        exit 1
    fi
    echo "ok: $name -> $got"
}

# --version: prints "subfetch <ver>" and exits 0
OUT=$("$EXE" --version) || { echo "FAIL: --version exit"; exit 1; }
echo "$OUT" | grep -q "^subfetch 0\." || { echo "FAIL: --version output: $OUT"; exit 1; }
echo "ok: --version -> $OUT"

# 2: CLI usage errors
expect_exit 2 "unknown flag" "$EXE" -x
expect_exit 2 "empty --url" "$EXE" --url "" --dry-run
expect_exit 2 "dry-run + reset-state" "$EXE" --dry-run --reset-state
expect_exit 2 "-o without path" "$EXE" -c fixtures/config.zon --node "trojan://pass@cli1.example.com:443#n" -o clash

# 3: config & data errors
expect_exit 3 "missing config" "$EXE" -c /nonexistent/config.zon
printf 'not { zon' > "$TMP/bad.zon"
expect_exit 3 "unparseable config" "$EXE" -c "$TMP/bad.zon"
expect_exit 3 "no input at all" "$EXE" --dry-run
printf 'subscriptions = .{ .{ .name = "x", .url = "fixtures/plain_uris.txt" }, .{ .name = "x", .url = "fixtures/plain_uris.txt" } }' > "$TMP/dup.zon"
expect_exit 3 "duplicate name" "$EXE" -c "$TMP/dup.zon" --dry-run

# 4: source failures (install still runs from the healthy sources)
expect_exit 4 "all sources failed" "$EXE" --url fixtures/html_error.html --url fixtures/html_error.html --dry-run
OUT=$("$EXE" -c fixtures/config.zon --url fixtures/html_error.html --dry-run 2>&1) || {
    got=$?
    [ "$got" -eq 4 ] || { echo "FAIL: partial failure: want 4, got $got"; echo "$OUT"; exit 1; }
}
echo "$OUT" | grep -q "11/12 ok, 1 failed" || { echo "FAIL: partial failure summary missing"; echo "$OUT"; exit 1; }
echo "ok: partial failure -> 4 (11/12 summary)"

# --reset-state: secret removed, lock file kept, idempotent
expect_exit 0 "reset without state" "$EXE" --reset-state
expect_exit 0 "install run (writes secret)" "$EXE" -c fixtures/config.zon -o raw="$TMP/out.json" --no-reload --no-verify
[ -f "$XDG_STATE_HOME/subfetch/secret" ] || { echo "FAIL: secret missing after install"; exit 1; }
[ -f "$XDG_STATE_HOME/subfetch/lock" ] || { echo "FAIL: lock missing after install"; exit 1; }
expect_exit 0 "reset with state" "$EXE" --reset-state
[ ! -f "$XDG_STATE_HOME/subfetch/secret" ] || { echo "FAIL: secret not removed"; exit 1; }
[ -f "$XDG_STATE_HOME/subfetch/lock" ] || { echo "FAIL: lock file must be kept"; exit 1; }
expect_exit 0 "reset again" "$EXE" --reset-state

echo "integration-exitcodes OK"
