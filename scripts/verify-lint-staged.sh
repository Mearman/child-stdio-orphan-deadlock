#!/bin/bash
# Layer 4: lint-staged + tinyexec end-to-end across version pairs.
#
# Sets up a throwaway git repo with a staged file, installs the requested
# (lint-staged, tinyexec) pair, runs lint-staged against the synthetic
# eslint plugin, and reports WEDGED or COMPLETED.
#
# Pairs to test in CI matrix:
#   lint-staged@16.4.0  + tinyexec@1.1.2   WEDGED   (original report)
#   lint-staged@16.4.0  + tinyexec@1.2.2   WEDGED
#   lint-staged@16.4.0  + tinyexec@1.2.3   COMPLETED
#   lint-staged@16.4.0  + tinyexec@1.2.4   WEDGED
#   lint-staged@17.0.7  + tinyexec@1.2.4   WEDGED   (current)
#   lint-staged@latest  + tinyexec@latest  WEDGED
set -uo pipefail

LS_VERSION="${LINT_STAGED_VERSION:-16.4.0}"
TX_VERSION="${TINYEXEC_VERSION:-1.1.2}"
EXPECT="${EXPECT:-WEDGED}"
TIMEOUT_S="${TIMEOUT_S:-15}"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$PROJECT_ROOT/fixtures"
TIMEOUT="$PROJECT_ROOT/scripts/timeout.mjs"

cleanup() {
  pkill -KILL -f 'setTimeout.*1000.*60.*60' 2>/dev/null || true
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}
trap cleanup EXIT

WORK=$(mktemp -d)
cd "$WORK"

cat > package.json <<JSON
{
  "name": "ls-orphan-test",
  "version": "0.0.0",
  "type": "module",
  "private": true
}
JSON

cat > .npmrc <<NPMRC
minimum-release-age-exclude[]=tinyexec
minimum-release-age-exclude[]=lint-staged
minimum-release-age-exclude[]=eslint
minimum-release-age-exclude[]=@eslint/plugin-kit
minimum-release-age-exclude[]=@eslint/core
minimum-release-age-exclude[]=@eslint/js
NPMRC

cat > pnpm-workspace.yaml <<YAML
overrides:
  tinyexec: "${TX_VERSION}"
YAML

cp "$FIXTURES/eslint-plugin-orphan.cjs" .
cp "$FIXTURES/eslint.config.mjs" .
cp "$FIXTURES/lint-staged.config.js" .

if ! pnpm add "lint-staged@${LS_VERSION}" eslint tinyexec >/dev/null 2>&1; then
    echo "FAIL: pnpm install failed"
    exit 2
fi

INSTALLED_LS=$(node -p "require('./node_modules/lint-staged/package.json').version" 2>/dev/null || echo MISSING)
INSTALLED_TX=$(node -p "require('./node_modules/tinyexec/package.json').version" 2>/dev/null || echo MISSING)
if [ "$INSTALLED_LS" = "MISSING" ] || [ "$INSTALLED_TX" = "MISSING" ]; then
    echo "FAIL: dependencies did not install"
    exit 2
fi
echo "lint-staged=${INSTALLED_LS} tinyexec=${INSTALLED_TX} expect=${EXPECT}"

# Throwaway git repo
git init -q -b main
git config user.email orphan-test@example.com
git config user.name orphan-test
echo "var x = 1;" > target.js
git add target.js
git commit -q -m initial
echo "var x = 2;" > target.js
git add target.js

# Run lint-staged with a hard timeout. Uses the portable timeout
# wrapper because macOS runners lack GNU coreutils' `timeout`.
OUT=$(mktemp)
START=$(date +%s)
node "$TIMEOUT" "$TIMEOUT_S" node node_modules/lint-staged/bin/lint-staged.js --debug >"$OUT" 2>&1
EC=$?
END=$(date +%s)
ELAPSED=$((END - START))

LAST=$(tail -3 "$OUT" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' | grep -v '^$' | tail -1)

echo "exit_code=${EC} elapsed=${ELAPSED}s"
echo "---tail of output---"
tail -15 "$OUT"
echo "---"

# Verdict:
#   124    → timeout fired (wedge)
#   0      → lint-staged completed (with eslint error, which is fine — task ran)
#   1      → lint-staged exited non-zero but not via timeout (also completed)
if [ "$EC" -eq 124 ]; then
  VERDICT="WEDGED"
else
  VERDICT="COMPLETED"
fi
echo "verdict=${VERDICT}"

if [ "$VERDICT" = "$EXPECT" ]; then
  echo "PASS: lint-staged@${INSTALLED_LS} + tinyexec@${INSTALLED_TX} → ${VERDICT}"
  exit 0
fi
echo "FAIL: expected ${EXPECT}, got ${VERDICT}"
exit 1
