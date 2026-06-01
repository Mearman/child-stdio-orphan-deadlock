// Layer 2: tinyexec iterator wedge probe.
//
// Calls tinyexec against a child that spawns an orphan grandchild and
// exits. The iterator either wedges (most tinyexec versions) or
// completes (1.2.3, since reverted).
//
// On timeout, reports VERDICT=WEDGED and exits. Caller is responsible
// for killing orphan grandchildren after this returns.

import { exec } from "tinyexec";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const TIMEOUT_MS = 4_000;

const here = dirname(fileURLToPath(import.meta.url));
const childScript = resolve(here, "child-with-orphan.mjs");

const startedAt = Date.now();
let firstLine = "";

const wedgeTimer = setTimeout(() => {
    console.error(`elapsed=${Date.now() - startedAt}ms verdict=WEDGED firstLine=${JSON.stringify(firstLine)}`);
    console.log("VERDICT=WEDGED");
    process.exit(0);
}, TIMEOUT_MS);

const result = exec(process.execPath, [childScript], {
    nodeOptions: { stdio: ["ignore"] },
});

const lines = [];
try {
    for await (const line of result) {
        if (!firstLine) firstLine = line;
        lines.push(line);
    }
} catch {
    // Iterator may throw on stream destroy or child error.
}

clearTimeout(wedgeTimer);
const elapsed = Date.now() - startedAt;

const hasExpectedLine = lines.length >= 1
    && lines[0].includes("child pid=")
    && lines[0].includes("orphan pid=");

const verdict = hasExpectedLine ? "COMPLETED" : "ERROR";
console.error(`elapsed=${elapsed}ms verdict=${verdict} lines=${lines.length} firstLine=${JSON.stringify(firstLine)}`);
console.log(`VERDICT=${verdict}`);
process.exit(verdict === "ERROR" ? 2 : 0);
