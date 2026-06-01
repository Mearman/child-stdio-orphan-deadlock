// Bare-Node demonstration. No tinyexec, no lint-staged.
//
// For each combination of {stdio: inherit, ignore, pipe} × {unref, no unref},
// spawn a grandchild that sleeps for an hour. Report whether the parent
// script exits cleanly or hangs.
//
// The point: the parent's event loop is held alive by the child handle.
// Calling .unref() releases it for inherit and ignore stdio, but not for
// pipe stdio (Node holds the loop for the open pipe handles too).
//
// Output is pipe-delimited so the verifying shell script can assert
// each case matches the expected verdict.

import { spawn } from "node:child_process";

const TIMEOUT_MS = 1500;

function runCase(label, stdio, callUnref) {
    return new Promise((resolve) => {
        const child = spawn(
            process.execPath,
            [
                "-e",
                `
                const { spawn } = require('node:child_process');
                const c = spawn(
                    process.execPath,
                    ['-e', 'setTimeout(() => {}, 1000 * 60 * 60)'],
                    { stdio: ${JSON.stringify(stdio)}, detached: false }
                );
                ${callUnref ? "c.unref();" : ""}
                `,
            ],
            { stdio: ["ignore", "ignore", "ignore"] },
        );

        const startedAt = Date.now();
        const timer = setTimeout(() => {
            child.kill("SIGKILL");
            resolve({ label, verdict: "HUNG", ms: Date.now() - startedAt });
        }, TIMEOUT_MS);

        child.once("exit", () => {
            clearTimeout(timer);
            resolve({ label, verdict: "exited", ms: Date.now() - startedAt });
        });
    });
}

const cases = [
    { label: "A_inherit_no_unref", stdio: ["ignore", "inherit", "inherit"], unref: false, expect: "HUNG" },
    { label: "B_inherit_unref",    stdio: ["ignore", "inherit", "inherit"], unref: true,  expect: "exited" },
    { label: "C_ignore_no_unref",  stdio: ["ignore", "ignore",  "ignore"],  unref: false, expect: "HUNG" },
    { label: "D_ignore_unref",     stdio: ["ignore", "ignore",  "ignore"],  unref: true,  expect: "exited" },
    { label: "E_pipe_no_unref",    stdio: ["ignore", "pipe",    "pipe"],    unref: false, expect: "HUNG" },
    { label: "F_pipe_unref",       stdio: ["ignore", "pipe",    "pipe"],    unref: true,  expect: "HUNG" },
];

console.log("case|stdio|unref|verdict|expect|ms|status");
let fail = 0;
for (const c of cases) {
    const r = await runCase(c.label, c.stdio, c.unref);
    const status = r.verdict === c.expect ? "OK" : "MISMATCH";
    console.log(`${c.label}|${JSON.stringify(c.stdio)}|${c.unref}|${r.verdict}|${c.expect}|${r.ms}|${status}`);
    if (r.verdict !== c.expect) fail++;
}

const { spawnSync } = await import("node:child_process");
spawnSync("pkill", ["-KILL", "-f", "setTimeout..*1000..*60..*60"], { stdio: "ignore" });

if (fail === 0) {
    console.log("PASS: parent-exit matrix matches expectations");
    process.exit(0);
}
console.log(`FAIL: ${fail} case(s) deviated`);
process.exit(1);
