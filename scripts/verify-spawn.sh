#!/bin/bash
# Layer 1: bare Node spawn behaviour. No dependencies.
#
# Runs all six (stdio × unref) cases and asserts each matches its
# expected verdict.
set -uo pipefail

cd "$(dirname "$0")/.."

cleanup() {
  pkill -KILL -f 'setTimeout.*1000.*60.*60' 2>/dev/null || true
}
trap cleanup EXIT

OUT=$(mktemp)
node src/parent-exit-cases.mjs >"$OUT" 2>&1
EC=$?

echo "exit_code=$EC"
echo "---output---"
cat "$OUT"
echo "---"

if [ "$EC" -eq 0 ] && tail -1 "$OUT" | grep -q "^PASS:"; then
  echo "PASS: layer 1 (bare Node spawn)"
  exit 0
fi
echo "FAIL: layer 1 (bare Node spawn) (exit=$EC)"
exit 1
