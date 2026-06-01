#!/bin/bash
# Layer 6 — REAL production cause #1: signing stall mistaken for a lint-staged wedge.
#
# In Joe's corpus, the cases that most looked like an orphan-stdio wedge
# (lint-staged prints its full "[COMPLETED] Cleaning up temporary files..."
# sequence, then the command never returns and the commit doesn't land)
# were NOT lint-staged hanging. lint-staged finished; the *subsequent* git
# commit-signing step stalled on a flaky 1Password SSH agent until the
# harness timeout fired.
#
# This reproduces that exact fingerprint deterministically with a fake
# signing program that sleeps. No 1Password required.
#
# PASS = lint-staged completes cleanly, then the command times out, and the
# commit does NOT land — proving the stall is in signing, after lint-staged.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="$ROOT/scripts/timeout.mjs"

cleanup() { pkill -f 'repro-signer.sh' 2>/dev/null || true; [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT

WORK=$(mktemp -d)
cd "$WORK"

cat > .npmrc <<'NPMRC'
minimum-release-age-exclude[]=lint-staged
minimum-release-age-exclude[]=husky
NPMRC
cat > package.json <<'JSON'
{ "name":"repro-signing","version":"0.0.0","type":"module","private":true }
JSON
cat > lint-staged.config.mjs <<'CFG'
export default { "*.js": ["node -e \"process.exit(0)\""] };
CFG
cat > repro-signer.sh <<'SIGNER'
#!/bin/bash
# Stand-in for a stalled 1Password SSH signing agent.
sleep "${FAKE_SIGN_DELAY:-120}"
exit 1
SIGNER
chmod +x repro-signer.sh
echo "ssh-ed25519 AAAAFAKEKEY repro" > k.pub
printf 'node_modules/\n' > .gitignore

if ! pnpm add -D lint-staged husky >/dev/null 2>&1; then
  echo "FAIL: pnpm install failed"; exit 2
fi

git init -q -b main
git config user.email r@e.com; git config user.name r
git config core.hooksPath .husky
mkdir -p .husky
printf 'node node_modules/lint-staged/bin/lint-staged.js\n' > .husky/pre-commit
chmod +x .husky/pre-commit

# Initial commit (no signing) so lint-staged has a base.
git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false commit -q -m scaffold

# Enable the stalled signer.
git config gpg.format ssh
git config gpg.ssh.program "$WORK/repro-signer.sh"
git config commit.gpgsign true
git config user.signingkey "$WORK/k.pub"

echo "console.log(1)" > a.js
git add a.js

HEAD_BEFORE=$(git rev-parse HEAD)
OUT=$(mktemp)
node "$TIMEOUT" 10 git commit -m "feat: add a.js" >"$OUT" 2>&1
EC=$?
HEAD_AFTER=$(git rev-parse HEAD)

echo "exit_code=$EC"
echo "--- output ---"; cat "$OUT"; echo "---"

ls_completed=$(grep -c "COMPLETED] Cleaning up temporary files" "$OUT" || true)
landed=$([ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && echo yes || echo no)

echo "lint_staged_completed=$([ "$ls_completed" -ge 1 ] && echo yes || echo no) timed_out=$([ "$EC" -eq 124 ] && echo yes || echo no) commit_landed=$landed"

if [ "$ls_completed" -ge 1 ] && [ "$EC" -eq 124 ] && [ "$landed" = "no" ]; then
  echo "PASS: lint-staged completed, then signing stalled, command timed out, commit did not land"
  echo "      (this is the 'fake wedge' fingerprint — the stall is in signing, not lint-staged)"
  exit 0
fi
echo "FAIL: did not reproduce the signing-stall fingerprint (ls_completed=$ls_completed ec=$EC landed=$landed)"
exit 1
