#!/bin/sh
# single-run CLI behavior contracts: exit-code semantics, input paths,
# isolated: XDG_STATE_HOME points into the build cache dir.
#
# exit codes: 0 success / 1 runtime (io, install) / 2 usage / 3 config & data
# / 4 any subscription source failed (cron must not see success).
set -eu

echo "=== integration-cli ==="

EXE=$1
WORK=$2
mkdir -p "$WORK"
TMP=$(mktemp -d "$WORK/cli.XXXXXX")
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

# -V/--version: prints "subfetch <ver>" and exits 0
OUT=$("$EXE" --version) || { echo "FAIL: --version exit"; exit 1; }
echo "$OUT" | grep -q "^subfetch 0\." || { echo "FAIL: --version output: $OUT"; exit 1; }
echo "ok: --version -> $OUT"

# --url accepts local file paths directly (no file:// needed): a plain
# URI list file is sniffed as a uri-list subscription, like node files used to
expect_exit 0 "url local file input" "$EXE" --url fixtures/plain_uris.txt --dry-run -o raw

# 2: CLI usage errors
expect_exit 2 "unknown option" "$EXE" -x
expect_exit 2 "empty --url" "$EXE" --url "" --dry-run
expect_exit 2 "dry-run + reset-state" "$EXE" --dry-run --reset-state
expect_exit 2 "-o without path" "$EXE" -c fixtures/config.zon --node "trojan://pass@cli1.example.com:443#n" -o clash
expect_exit 2 "no output target" "$EXE" -c fixtures/config.zon --url fixtures/plain_uris.txt

# 3: config & data errors
expect_exit 3 "missing config" "$EXE" -c /nonexistent/config.zon
printf 'not { zon' > "$TMP/bad.zon"
expect_exit 3 "unparseable config" "$EXE" -c "$TMP/bad.zon"
printf '.{ .outputs = .{ .{ .fmt = .clash } } }' > "$TMP/pathless.zon"
expect_exit 3 "zon output without path" "$EXE" -c "$TMP/pathless.zon" --dry-run
expect_exit 3 "no input at all" "$EXE" --dry-run
printf 'subscriptions = .{ .{ .name = "x", .url = "fixtures/plain_uris.txt" }, .{ .name = "x", .url = "fixtures/plain_uris.txt" } }' > "$TMP/dup.zon"
expect_exit 3 "duplicate name" "$EXE" -c "$TMP/dup.zon" --dry-run

# 4: source failures (install still runs from the healthy sources)
expect_exit 4 "all sources failed" "$EXE" --url fixtures/html_error.html --url fixtures/html_error.html --dry-run
OUT=$("$EXE" -c fixtures/config.zon --url fixtures/html_error.html --dry-run -o raw 2>&1) || {
    got=$?
    [ "$got" -eq 4 ] || { echo "FAIL: partial failure: want 4, got $got"; echo "$OUT"; exit 1; }
}
echo "$OUT" | grep -q "11/12 ok, 1 failed" || { echo "FAIL: partial failure summary missing"; echo "$OUT"; exit 1; }
echo "ok: partial failure -> 4 (11/12 summary)"

# 1: runtime failure - Stage A temp write fails on an unwritable output
# path (nothing installed, .new debris cleaned by abort)
expect_exit 1 "unwritable output path" "$EXE" -c fixtures/config.zon -o "raw=$TMP/nodir/out.json" --no-reload

# 3: --no-verify still enforces the mandatory syntax layer (bad yaml from a
# user template must be rejected, not silently installed)
printf 'proxies: []\nbad: [unclosed\n' > "$TMP/badtpl.yaml"
expect_exit 3 "no-verify syntax check" "$EXE" -c fixtures/config.zon -o "clash:$TMP/badtpl.yaml=$TMP/out.yaml" --no-verify --no-reload

# --dry-run honors --no-verify too (same per-output/--no-verify switch as the
# install path: syntax layer still enforced, client command skipped, zero
# side effects)
expect_exit 3 "dry-run no-verify syntax" "$EXE" -c fixtures/config.zon --dry-run -o "clash:$TMP/badtpl.yaml=$TMP/drnv.yaml" --no-verify
[ ! -f "$TMP/drnv.yaml" ] || { echo "FAIL: dry-run must not write"; exit 1; }
expect_exit 0 "dry-run no-verify ok" "$EXE" -c fixtures/config.zon --dry-run -o "clash=$TMP/drnv2.yaml" --no-verify
[ ! -f "$TMP/drnv2.yaml" ] || { echo "FAIL: dry-run must not write"; exit 1; }
echo "ok: dry-run honors --no-verify"

# 3: template read failure (missing template file)
expect_exit 3 "template read failure" "$EXE" -c fixtures/config.zon -o "clash:$TMP/no.tmpl=$TMP/out.yaml" --no-reload

# 4: real-mode source failure: healthy sources verify, nothing is installed,
# exit 4 tells cron to retry (configs stay unchanged)
OUT=$("$EXE" -c fixtures/config.zon --url fixtures/html_error.html -o "raw=$TMP/out.json" --no-reload 2>&1) || {
    got=$?
    [ "$got" -eq 4 ] || { echo "FAIL: real-mode partial failure: want 4, got $got"; echo "$OUT"; exit 1; }
}
echo "$OUT" | grep -q "skip install (configs unchanged)" || { echo "FAIL: real-mode skip-install message missing"; echo "$OUT"; exit 1; }
[ ! -f "$TMP/out.json" ] || { echo "FAIL: real-mode partial failure must not install"; exit 1; }
echo "ok: real-mode source failure -> 4 (nothing installed)"

# reload_cmd success path: first install triggers the custom reload command
# (the per-output .reload=false suppression is covered in integration-install)
"$EXE" -c fixtures/config.zon -o "raw=$TMP/rc.json" --reload-cmd "touch $TMP/rc-ran" --no-verify >/dev/null 2>&1 || { echo "FAIL: reload_cmd install exit"; exit 1; }
[ -f "$TMP/rc-ran" ] || { echo "FAIL: reload_cmd did not execute"; exit 1; }
echo "ok: reload_cmd executed after install"

# --reset-state: secret removed, lock file kept, idempotent
expect_exit 0 "reset without state" "$EXE" --reset-state
expect_exit 0 "install run (writes secret)" "$EXE" -c fixtures/config.zon -o raw="$TMP/out.json" --no-reload --no-verify
[ -f "$XDG_STATE_HOME/subfetch/secret" ] || { echo "FAIL: secret missing after install"; exit 1; }
[ -f "$XDG_STATE_HOME/subfetch/lock" ] || { echo "FAIL: lock missing after install"; exit 1; }
expect_exit 0 "reset with state" "$EXE" --reset-state
[ ! -f "$XDG_STATE_HOME/subfetch/secret" ] || { echo "FAIL: secret not removed"; exit 1; }
[ -f "$XDG_STATE_HOME/subfetch/lock" ] || { echo "FAIL: lock file must be kept"; exit 1; }
expect_exit 0 "reset again" "$EXE" --reset-state

echo "integration-cli OK"
