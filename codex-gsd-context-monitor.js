#!/usr/bin/env node
// Codex Stop compatibility wrapper for GSD's context monitor.
//
// GSD intentionally uses its Stop registration only for side effects and emits
// no model context there. Codex Stop is stricter than most hook events: exit 0
// requires JSON stdout. Run the original monitor unchanged, preserve all of its
// side effects, then normalize the advisory result to a valid no-op object.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  try {
    const target = path.join(__dirname, "gsd-context-monitor.js");
    if (fs.existsSync(target)) {
      spawnSync(process.execPath, [target], {
        input,
        encoding: "utf8",
        timeout: 8500,
        windowsHide: true,
        stdio: ["pipe", "ignore", "ignore"],
      });
    }
  } catch {}
  process.stdout.write("{}");
});
