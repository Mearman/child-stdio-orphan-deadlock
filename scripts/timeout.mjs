#!/usr/bin/env node
// Portable timeout for macOS runners that lack GNU coreutils' `timeout`.
// Usage: node scripts/timeout.mjs <seconds> <cmd> [args...]

import { spawn } from "node:child_process";

const [secondsStr, cmd, ...args] = process.argv.slice(2);
const seconds = Number(secondsStr);
if (!Number.isFinite(seconds) || !cmd) {
    console.error("usage: timeout.mjs <seconds> <cmd> [args...]");
    process.exit(2);
}

const child = spawn(cmd, args, { stdio: "inherit", detached: true });

const killer = setTimeout(() => {
    try { process.kill(-child.pid, "SIGKILL"); } catch {}
    try { child.kill("SIGKILL"); } catch {}
    process.exit(124);
}, seconds * 1000);

child.on("exit", (code, signal) => {
    clearTimeout(killer);
    if (signal) process.exit(128 + (signal === "SIGTERM" ? 15 : 9));
    process.exit(code ?? 0);
});

child.on("error", (err) => {
    clearTimeout(killer);
    console.error(err.message);
    process.exit(127);
});
