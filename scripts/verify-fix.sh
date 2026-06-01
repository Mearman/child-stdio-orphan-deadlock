#!/bin/bash
# Layer 3: proposed consumer-side defensive fix (idle-output timeout).
#
# Runs the fix demo and asserts the iterator unwedges within the
# idle-timeout window. Output captured before the watchdog fires is
# preserved.
set -uo pipefail

cd "$(dirname "$0")/.."

cleanup() {
  pkill -KILL -f 'setTimeout.*1000.*60.*60' 2>/dev/null || true
}
trap cleanup EXIT

OUT=$(mktemp)
node src/proposed-fix.mjs >"$OUT" 2>&1
EC=$?

VERDICT=$(grep '^VERDICT=' "$OUT" | head -1 | cut -d= -f2)
echo "exit_code=${EC} verdict=${VERDICT}"
echo "---output---"
cat "$OUT"
echo "---"

if [ "$EC" -eq 0 ] && [ "$VERDICT" = "UNWEDGED" ]; then
  echo "PASS: idle-timeout fix unwedged the iterator"
  exit 0
fi
echo "FAIL: fix did not unwedge (exit=${EC} verdict=${VERDICT})"
exit 1
