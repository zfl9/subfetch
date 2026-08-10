#!/bin/sh
# install-path smoke test: first install -> unchanged skip -> partial rewrite.
# fully isolated: outputs go to the build cache dir, --no-reload, and
# XDG_STATE_HOME points into the isolated dir - never touches real configs,
# services, or state.
set -eu

echo "=== smoke-install ==="

EXE=$1
DIR=$2
CFG=fixtures/config.zon

rm -rf "$DIR"
mkdir -p "$DIR"
export XDG_STATE_HOME="$DIR/state"

run() {
    "$EXE" -c "$CFG" -o "clash=$DIR/clash.yaml" -o "ss=$DIR/ss" -o "raw=$DIR/raw.json" --no-reload 2>&1
}

# 1. first install: files appear
OUT=$(run)
echo "$OUT" | grep -q "installed" || { echo "FAIL: first install did not report installed"; exit 1; }
[ -f "$DIR/clash.yaml" ] && [ -f "$DIR/raw.json" ] && [ -d "$DIR/ss" ] || { echo "FAIL: output files missing"; exit 1; }

# 2. second run: everything unchanged -> all three targets skip
OUT=$(run)
CNT=$(echo "$OUT" | grep -c "config unchanged, skip install" || true)
[ "$CNT" -eq 3 ] || { echo "FAIL: expected 3 unchanged skips, got $CNT"; exit 1; }

# 3. modify one multi-file node -> only that file is rewritten
NODE=$(ls "$DIR/ss" | head -1)
echo '{"touched":true}' > "$DIR/ss/$NODE"
OUT=$(run)
echo "$OUT" | grep -q "wrote 1 files" || { echo "FAIL: expected 1 file rewrite"; exit 1; }

# 4. no .new / .new.json debris anywhere
DEBRIS=$(find "$DIR" \( -name '*.new' -o -name '*.new.json' \) || true)
[ -z "$DEBRIS" ] || { echo "FAIL: .new debris left behind: $DEBRIS"; exit 1; }

echo "smoke-install OK"
