#!/bin/bash
# Layer 2: tinyexec iterator wedge across versions.
#
# TINYEXEC_VERSION pins the version under test. EXPECT is the expected
# verdict (WEDGED or COMPLETED). CI runs one job per (version, expect)
# pair from the version matrix.
#
# Known matrix (all confirmed locally):
#   1.0.4 WEDGED
#   1.1.2 WEDGED
#   1.2.2 WEDGED
#   1.2.3 COMPLETED (destroy-on-exit, since reverted)
#   1.2.4 WEDGED
#   latest WEDGED (as of writing)
set -uo pipefail

cd "$(dirname "$0")/.."

VERSION="${TINYEXEC_VERSION:-latest}"
EXPECT="${EXPECT:-WEDGED}"

cleanup() {
  pkill -KILL -f 'setTimeout.*1000.*60.*60' 2>/dev/null || true
}
trap cleanup EXIT

pnpm add -D --silent "tinyexec@${VERSION}" >/dev/null 2>&1
INSTALLED=$(node -p "require('./node_modules/tinyexec/package.json').version")
echo "tinyexec=${INSTALLED} expect=${EXPECT}"

OUT=$(mktemp)
node src/tinyexec-iterator.mjs >"$OUT" 2>&1
EC=$?

VERDICT=$(grep '^VERDICT=' "$OUT" | head -1 | cut -d= -f2)

echo "exit_code=${EC} verdict=${VERDICT}"
echo "---output---"
cat "$OUT"
echo "---"

if [ "$EC" -eq 2 ] || [ -z "$VERDICT" ]; then
  echo "FAIL: probe errored out"
  exit 1
fi

if [ "$VERDICT" = "$EXPECT" ]; then
  echo "PASS: tinyexec ${INSTALLED} verdict ${VERDICT} matches expect ${EXPECT}"
  exit 0
fi

echo "FAIL: tinyexec ${INSTALLED} verdict ${VERDICT} but expected ${EXPECT}"
exit 1
