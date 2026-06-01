# child-stdio-orphan-deadlock

Minimal reproductions of a deadlock pattern that surfaces when a
`child_process.spawn`'d Node process leaves behind a descendant that
holds inherited stdio open. The parent's stream wrappers (tinyexec,
execa, anything iterating `stdout`/`stderr` to EOF) never see EOF and
hang indefinitely.

Most-visible consumer impact: lint-staged commits hang at
`[STARTED] eslint --fix` with no error. Prior discussion:
[lint-staged#1800](https://github.com/lint-staged/lint-staged/issues/1800),
[tinyexec#137](https://github.com/tinylibs/tinyexec/pull/137),
[tinyexec#138](https://github.com/tinylibs/tinyexec/issues/138),
[tinyexec#139](https://github.com/tinylibs/tinyexec/issues/139).

Both upstream maintainers landed on "the plugin should fix itself and
the consumer can guard if it wants; not a library bug". This repo
doesn't argue with that. It reproduces the mechanism cleanly across the
relevant versions, demonstrates why the partial fix that shipped as
tinyexec 1.2.3 doesn't help the real lint-staged case, and shows the
consumer-side guard pattern that does work.

## Layers

| Layer | What it shows | Script |
|-------|---------------|--------|
| 1 | `spawn` without `.unref()` keeps the parent's event loop alive, regardless of stdio mode | `verify-spawn.sh` |
| 2 | tinyexec's async iterator wedges on the orphan-pipe pattern across every version except 1.2.3 | `verify-iterator.sh` |
| 3 | A per-task idle-timeout guard at the consumer layer breaks the deadlock | `verify-fix.sh` |
| 4 | The lint-staged → tinyexec chain wedges on every released pair, including 1.2.3 | `verify-lint-staged.sh` |

Reproduce all four:

```sh
pnpm install
pnpm verify
```

## Layer 1: bare Node

`src/parent-exit-cases.mjs` spawns a sleeping grandchild for every
combination of `{stdio: inherit | ignore | pipe} × {unref | no unref}`
and observes whether the parent script exits cleanly.

```
case               stdio   unref  verdict
A_inherit_no_unref inherit false  HUNG
B_inherit_unref    inherit true   exited
C_ignore_no_unref  ignore  false  HUNG
D_ignore_unref     ignore  true   exited
E_pipe_no_unref    pipe    false  HUNG
F_pipe_unref       pipe    true   HUNG
```

Two observations matter:

- Without `.unref()`, the parent always hangs. The child handle keeps
  the event loop alive until the child exits, which never happens
  while the grandchild is sleeping.
- With `pipe` stdio, even `.unref()` doesn't release the loop. Node
  holds it for the open pipe handles too.

Translated to the lint-staged stack: if an eslint plugin calls
`child_process.spawn(...)` and doesn't `.unref()` the result, eslint
never exits. tinyexec waits for eslint's stdio to EOF, which it can't
without eslint exiting. lint-staged waits for tinyexec.

## Layer 2: tinyexec iterator

`src/tinyexec-iterator.mjs` calls tinyexec against a child that
spawns one un-unref'd grandchild and exits via `process.exit(0)`. The
iterator yields the child's printed line, then either wedges or
completes depending on tinyexec version.

Verdicts (CI-confirmed across the version matrix):

| tinyexec | verdict   | notes |
|----------|-----------|-------|
| 1.0.4    | WEDGED    | pre-pipeline combiner; same EOF requirement |
| 1.1.2    | WEDGED    | original report version |
| 1.2.2    | WEDGED    | pre-fix |
| 1.2.3    | COMPLETED | destroy-on-exit fix landed, then reverted |
| 1.2.4    | WEDGED    | reverted to 1.2.2 semantics |
| latest   | WEDGED    | as of writing |

The 1.2.3 fix works here because the child explicitly calls
`process.exit(0)`. The child's `exit` event fires, tinyexec destroys
the streams, the iterator returns.

## Layer 3: consumer-side idle-timeout guard

The 1.2.3 destroy-on-exit fix has two problems. It caused a
buffer-drain race on Linux under concurrent calls (tinyexec#139), and
it only fires when the immediate child actually exits. The second is
the more important one. See Layer 4.

`src/proposed-fix.mjs` shows the pattern that does work: a per-task
idle-output watchdog. After the first line arrives, the watchdog
resets on every chunk. If no new chunk arrives within
`IDLE_TIMEOUT_MS`, kill the process group with `SIGKILL` and destroy
the streams. The captured output up to that point is preserved.

Typical elapsed: ~1100ms (one line received at ~50ms, then idle for
the rest of the timeout). No tinyexec changes needed.

This is the shape lint-staged could land in `getSpawnedTask.js`.

## Layer 4: full lint-staged chain

`scripts/verify-lint-staged.sh` sets up a throwaway git repo with one
staged `.js` file, installs the requested `(lint-staged, tinyexec)`
pair, configures eslint to load a synthetic plugin that spawns an
un-unref'd grandchild, and runs lint-staged.

| lint-staged | tinyexec | verdict |
|-------------|----------|---------|
| 16.4.0      | 1.1.2    | WEDGED  |
| 16.4.0      | 1.2.3    | WEDGED  |
| 16.4.0      | 1.2.4    | WEDGED  |
| 17.0.7      | 1.2.4    | WEDGED  |
| latest      | latest   | WEDGED  |

Note that 1.2.3 wedges here even though Layer 2 didn't. The reason:
eslint never calls `process.exit()`. It runs its event loop to
completion. With the orphan's child handle pinning the loop alive,
eslint's `exit` event never fires, and tinyexec's 1.2.3 destroy-on-exit
guard never triggers.

This is the key reason the upstream destroy-on-exit fix was a dead
end for this scenario. The guard has to fire on lack-of-progress, not
on exit.

## The synthetic plugin

`fixtures/eslint-plugin-orphan.cjs` is one rule that spawns a sleeping
node grandchild from inside `Program()` and doesn't `.unref()` it.
It's a stand-in for any plugin that fires-and-forgets a subprocess:
worker-thread bridges, language-server probes, transitive helpers,
arbitrary `exec(cmd, callback)` calls with no callback.

This MRE doesn't claim a specific production plugin has been
identified. The shape is what matters: any unref-less spawn from
inside the linter process reproduces the same wedge.

## What the maintainers said

- **iiroj** (lint-staged): consumer/plugin issue, not lint-staged's to
  fix. Closed #1800 with "if you find the real plugin, open a new
  issue".
- **43081j** (tinyexec): reverted #137 because the destroy-on-exit
  approach broke things. *"It does sound like lint-staged should just
  kill dangling children on exit if it can."*

Both reasonable. Neither addresses the user-facing symptom (indefinite
hang, no error) for consumers whose plugins they don't control.

## Versions

| | |
|-|-|
| Node | 22, 24, 26 (CI matrix) |
| pnpm | 10.33.1 |
| tinyexec | 1.0.4, 1.1.2, 1.2.2, 1.2.3, 1.2.4, latest (CI matrix) |
| lint-staged | 16.4.0, 17.0.7, latest (CI matrix) |
| eslint | latest |
| OS | ubuntu-latest, macos-latest (CI matrix) |

## Prior MREs

- [lint-staged-1800-mre](https://github.com/Mearman/lint-staged-1800-mre):
  earlier attempt, focused on the husky/lint-staged chain only.
- [tinyexec-grandchild-mre](https://github.com/Mearman/tinyexec-grandchild-mre):
  investigation of the buffer-drain race that took down tinyexec
  1.2.3.

This repo supersedes both. It separates the mechanism from any
specific consumer, runs across the version matrix that actually
matters for the discussion, and presents the proposed guard as a
consumer-side pattern rather than asking the library to absorb it.
