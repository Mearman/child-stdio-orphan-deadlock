import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const orphan = require("./eslint-plugin-orphan.cjs");

export default [
    {
        files: ["**/*.js"],
        plugins: { orphan },
        rules: {
            "orphan/spawn-orphan": "error",
        },
    },
];
