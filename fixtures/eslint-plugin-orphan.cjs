// Synthetic ESLint plugin: spawns one orphan grandchild per Program node.
// Stands in for any plugin code that fires-and-forgets a subprocess without
// .unref(). The grandchild inherits stdout/stderr and sleeps for an hour,
// keeping eslint's pipes alive after eslint would otherwise exit.
//
// Used to reproduce the lint-staged/tinyexec wedge end-to-end.

const { spawn } = require("node:child_process");

module.exports = {
    rules: {
        "spawn-orphan": {
            meta: { type: "problem", schema: [] },
            create() {
                let done = false;
                return {
                    Program() {
                        if (done) return;
                        done = true;
                        spawn(
                            process.execPath,
                            ["-e", "setTimeout(() => {}, 1000 * 60 * 60)"],
                            { stdio: ["ignore", "inherit", "inherit"], detached: false },
                        );
                    },
                };
            },
        },
    },
};
