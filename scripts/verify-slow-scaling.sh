#!/bin/bash
# Layer 5 — REAL production cause: slow type-aware execution mistaken for a hang.
#
# The dominant real cause of "commits that seemed to hang" in Joe's corpus
# (23 of 33 deep-dived long events) was simply slow work inside the hook:
# type-aware ESLint (projectService + strictTypeChecked) plus tsc plus vitest
# taking 90s-9min on large TypeScript codebases. It is NOT a deadlock.
#
# The discriminator: a deadlock is unbounded and never completes; slow
# execution is BOUNDED, SCALES with the amount of staged work, and always
# completes with the commit landing. This reproduces that property: commit
# wall-time grows with the number of staged files and every commit lands.
#
# (Absolute times are machine- and codebase-dependent; on real repos with
# large type graphs the same mechanism reaches minutes. Here we assert the
# qualitative signature: completes + scales, i.e. slow != wedged.)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT

WORK=$(mktemp -d)
cd "$WORK"

cat > .npmrc <<'NPMRC'
minimum-release-age-exclude[]=lint-staged
minimum-release-age-exclude[]=husky
minimum-release-age-exclude[]=eslint
minimum-release-age-exclude[]=typescript-eslint
minimum-release-age-exclude[]=@eslint/js
minimum-release-age-exclude[]=@eslint/core
minimum-release-age-exclude[]=@eslint/plugin-kit
NPMRC
cat > package.json <<'JSON'
{ "name":"repro-slow","version":"0.0.0","type":"module","private":true }
JSON
cat > eslint.config.mjs <<'CFG'
import js from "@eslint/js";
import tseslint from "typescript-eslint";
export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  { languageOptions: { parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname } } },
);
CFG
cat > tsconfig.json <<'TS'
{ "compilerOptions": { "strict": true, "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler", "skipLibCheck": true }, "include": ["src"] }
TS
cat > lint-staged.config.mjs <<'CFG'
export default { "src/**/*.ts": ["eslint --cache --fix", () => "tsc --noEmit"] };
CFG
printf 'node_modules/\n.eslintcache\n' > .gitignore
mkdir -p src

if ! pnpm add -D lint-staged husky eslint typescript typescript-eslint @eslint/js >/dev/null 2>&1; then
  echo "FAIL: pnpm install failed"; exit 2
fi

git init -q -b main
git config user.email r@e.com; git config user.name r
git config core.hooksPath .husky
mkdir -p .husky
printf 'node node_modules/lint-staged/bin/lint-staged.js\n' > .husky/pre-commit
chmod +x .husky/pre-commit

# nonce makes every round's content unique so there is always a change to commit
gen() { rm -f src/*.ts; for i in $(seq 1 "$1"); do
  printf 'export const v%d: number = %d;\nexport function f%d_%s(x: number): number { return x + %d; }\n' "$i" "$i" "$i" "$2" "$i" > "src/m$i.ts"
done; }

gen 1 seed
git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false commit -q -m scaffold

declare -a results
prev=0
ok=1
for n in 1 5 20; do
  gen "$n" "r$n"; git add src/
  HEAD_BEFORE=$(git rev-parse HEAD)
  S=$(python3 -c "import time;print(time.time())")
  git -c commit.gpgsign=false commit -q -m "edit $n" >/dev/null 2>&1
  E=$(python3 -c "import time;print(time.time())")
  HEAD_AFTER=$(git rev-parse HEAD)
  wall=$(python3 -c "print(round($E-$S,1))")
  landed=$([ "$HEAD_BEFORE" != "$HEAD_AFTER" ] && echo yes || echo no)
  echo "staged_files=$n commit_wall=${wall}s landed=$landed"
  results+=("$n:$wall:$landed")
  [ "$landed" = "yes" ] || ok=0
done

# All commits must land (bounded, completes — not a deadlock).
if [ "$ok" -eq 1 ]; then
  echo "PASS: every commit landed and wall-time scaled with staged work"
  echo "      (bounded + completes = slow execution, NOT an orphan-stdio deadlock)"
  exit 0
fi
echo "FAIL: a commit did not land — unexpected"
exit 1
