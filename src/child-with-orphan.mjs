// Stand-in for an ESLint process or any other tool whose plugin code
// accidentally spawns a fire-and-forget subprocess without unref'ing it.
//
// Prints one line so the consumer can see something arrived, then exits.
// The orphan grandchild stays alive holding inherited stdout/stderr fds.

import { spawn } from "node:child_process";

const orphan = spawn(
    process.execPath,
    ["-e", "setTimeout(() => {}, 1000 * 60 * 60)"],
    { stdio: ["ignore", "inherit", "inherit"], detached: false },
);

console.log(`child pid=${process.pid} orphan pid=${orphan.pid}`);
process.exit(0);
