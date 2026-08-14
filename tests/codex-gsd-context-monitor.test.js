// Offline contract test for the Codex Stop compatibility wrapper around GSD's
// context monitor. Everything runs in an isolated %TEMP% directory.
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

const ROOT = path.join(os.tmpdir(), "press-1-tests", "codex-gsd-context-monitor");
const WRAPPER = path.join(ROOT, "codex-gsd-context-monitor.js");
const TARGET = path.join(ROOT, "gsd-context-monitor.js");
const SIDE_EFFECT = path.join(ROOT, "side-effect.json");
fs.rmSync(ROOT, { recursive: true, force: true });
fs.mkdirSync(ROOT, { recursive: true });
fs.copyFileSync(path.join(__dirname, "..", "codex-gsd-context-monitor.js"), WRAPPER);
fs.writeFileSync(TARGET, `
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", c => input += c);
process.stdin.on("end", () => {
  require("fs").writeFileSync(process.env.PRESS1_GSD_SIDE_EFFECT, input);
  process.stdout.write("this would be invalid for Stop");
});
`);

let pass = 0, fail = 0;
function check(name, condition, extra = "") {
  condition ? pass++ : fail++;
  console.log(`${condition ? "PASS" : "FAIL"}  ${name}${!condition && extra ? ` — ${extra}` : ""}`);
}

const payload = JSON.stringify({ hook_event_name: "Stop", session_id: "wrapper-test" });
let r = spawnSync(process.execPath, [WRAPPER], {
  input: payload, encoding: "utf8", timeout: 5000,
  env: { ...process.env, PRESS1_GSD_SIDE_EFFECT: SIDE_EFFECT },
});
check("T1 wrapper exits 0", r.status === 0, r.stderr);
check("T1 Stop output normalized to JSON no-op", r.stdout === "{}", r.stdout);
check("T1 original GSD side effect preserved", fs.readFileSync(SIDE_EFFECT, "utf8") === payload);

fs.rmSync(TARGET, { force: true });
r = spawnSync(process.execPath, [WRAPPER], { input: payload, encoding: "utf8", timeout: 5000 });
check("T2 missing GSD target still fails open with valid JSON", r.status === 0 && r.stdout === "{}", `${r.status} ${r.stdout} ${r.stderr}`);

console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
process.exit(fail ? 1 : 0);
