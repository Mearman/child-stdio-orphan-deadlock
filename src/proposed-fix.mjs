// Layer 3: proposed defensive fix at the consumer (lint-staged) layer.
//
// The destroy-on-exit fix in tinyexec 1.2.3 only helps when the immediate
// child process actually exits. In the real lint-staged → eslint chain,
// eslint never exits when a plugin holds its event loop alive (which is
// exactly the production case). So the fix has to be timeout-based, not
// exit-based.
//
// Pattern below: race the iterator against an idle-output watchdog.
// If no new chunk arrives within IDLE_TIMEOUT_MS, assume the chain is
// wedged and tear down the whole process group with SIGKILL. The output
// captured before the watchdog fires is preserved.
//
// This is the shape lint-staged could land in getSpawnedTask.js. It
// makes no changes to tinyexec.

import { exec } from "tinyexec";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const IDLE_TIMEOUT_MS = 1_000;
const HARD_TIMEOUT_MS = 8_000;

const here = dirname(fileURLToPath(import.meta.url));
const childScript = resolve(here, "child-with-orphan.mjs");

const result = exec(process.execPath, [childScript], {
    nodeOptions: { stdio: ["ignore"] },
});

const startedAt = Date.now();
let lastActivityAt = Date.now();
let killed = false;

// Wait for the spawn to register so .process is defined.
await new Promise((r) => {
    const id = setInterval(() => {
        if (result.process) {
            clearInterval(id);
            r();
        }
    }, 1);
});

const idleWatchdog = setInterval(() => {
    if (Date.now() - lastActivityAt > IDLE_TIMEOUT_MS) {
        clearInterval(idleWatchdog);
        killed = true;
        // Negative pid kills the whole process group: catches orphan
        // descendants that inherited stdio.
        const pid = result.process?.pid;
        if (pid) {
            try { process.kill(-pid, "SIGKILL"); } catch {}
            try { process.kill(pid, "SIGKILL"); } catch {}
        }
        // Force-end the streams so the iterator returns.
        result.process?.stdout?.destroy();
        result.process?.stderr?.destroy();
    }
}, 100);

const hardTimer = setTimeout(() => {
    console.error(`HARD TIMEOUT ${HARD_TIMEOUT_MS}ms — fix did not unwedge`);
    process.exit(124);
}, HARD_TIMEOUT_MS);

const lines = [];
try {
    for await (const line of result) {
        lastActivityAt = Date.now();
        lines.push(line);
        console.error(`[+${Date.now() - startedAt}ms] line: ${line}`);
    }
} catch {
    // Iterator may throw on stream destroy.
}

clearInterval(idleWatchdog);
clearTimeout(hardTimer);

const elapsed = Date.now() - startedAt;
console.error(`elapsed=${elapsed}ms killed=${killed} lines=${lines.length}`);

if (killed && elapsed < HARD_TIMEOUT_MS && lines.length >= 1) {
    console.log("VERDICT=UNWEDGED");
    process.exit(0);
}
console.log("VERDICT=FAILED");
process.exit(1);
