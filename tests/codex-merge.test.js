// Tests for merge-codex-hooks.js — wrapper-schema merge into ~/.codex/hooks.json
// + the pure config.toml trust-upsert + own-hook matching. Isolated TEMP, env
// overrides; the app-server spawn is skipped (PRESS1_CODEX_SKIP_TRUST=1).
// Run: node tests/codex-merge.test.js
const fs = require("fs"), path = require("path"), os = require("os");
const { spawnSync } = require("child_process");

const MERGE = path.join(__dirname, "..", "merge-codex-hooks.js");
const { upsertTrust, isOurHook } = require(MERGE);
const ROOT = path.join(os.tmpdir(), "press-1-tests", "codex-merge");
const HOOKS_DIR = "C:/Users/test/.codex/hooks";
const CMD_PERM = `node "${HOOKS_DIR}/codex-permission-request.js"`;
const CMD_TD = `node "${HOOKS_DIR}/session-teardown.js"`;

fs.rmSync(ROOT, { recursive: true, force: true });
fs.mkdirSync(ROOT, { recursive: true });

let pass = 0, fail = 0;
const check = (name, cond, extra) => { cond ? pass++ : fail++; console.log((cond ? "PASS" : "FAIL") + "  " + name + (!cond && extra ? " — " + extra : "")); };

function caseDir(name, content) {
  const dir = path.join(ROOT, name);
  fs.mkdirSync(dir, { recursive: true });
  if (content !== undefined) fs.writeFileSync(path.join(dir, "hooks.json"), content);
  return dir;
}
const run = (dir) => spawnSync("node", [MERGE], {
  env: {
    ...process.env,
    CODEX_HOOKS_PATH: path.join(dir, "hooks.json"),
    CODEX_HOOKS_DIR: HOOKS_DIR,
    CODEX_CONFIG_PATH: path.join(dir, "config.toml"),
    PRESS1_CODEX_SKIP_TRUST: "1",
  },
  encoding: "utf8",
});
const readRaw = (dir) => fs.readFileSync(path.join(dir, "hooks.json"), "utf8");
const readJ = (dir) => JSON.parse(readRaw(dir));

// T1: clean machine (no hooks.json) → wrapper schema with our three entries.
{
  const d = caseDir("t1");
  const r = run(d);
  const s = readJ(d);
  check("T1 exit 0", r.status === 0);
  check("T1 wrapper: hooks.PermissionRequest present", s.hooks?.PermissionRequest?.[0]?.hooks?.[0]?.command === CMD_PERM);
  check("T1 PermissionRequest timeout 70 (small, not 3660; > 60s window + sound)", s.hooks.PermissionRequest[0].hooks[0].timeout === 70);
  check("T1 hooks.Stop present", s.hooks?.Stop?.[0]?.hooks?.[0]?.command === CMD_TD);
  check("T1 hooks.PostToolUse present", s.hooks?.PostToolUse?.[0]?.hooks?.[0]?.command === CMD_TD);
  check("T1 NOT at top level", s.PermissionRequest === undefined);
}

// T1b: a machine that already carries the OLD timeout:30 (Stage 2a install) →
// the existing wrapper entry is bumped 30 → 70. The clean-install test (T1) can't
// catch this regression: only a pre-existing entry exercises the "overwrite a
// differing value" path (the set-exact merge-condition fix). Without it the 60 s
// window silently breaks — Codex would kill the hook at 30 s, mid-wait.
{
  const d = caseDir("t1b", JSON.stringify({
    hooks: {
      PermissionRequest: [{ hooks: [{ type: "command", command: CMD_PERM, timeout: 30 }] }],
      Stop: [{ hooks: [{ type: "command", command: CMD_TD, timeout: 5 }] }],
      PostToolUse: [{ hooks: [{ type: "command", command: CMD_TD, timeout: 5 }] }],
    },
  }, null, 2));
  const r = run(d);
  const s = readJ(d);
  check("T1b exit 0", r.status === 0);
  check("T1b existing PermissionRequest timeout bumped 30 → 70", s.hooks.PermissionRequest[0].hooks[0].timeout === 70);
  check("T1b matched our entry (command unchanged)", s.hooks.PermissionRequest[0].hooks[0].command === CMD_PERM);
  check("T1b no duplicate PermissionRequest entry", s.hooks.PermissionRequest.length === 1);
  check("T1b unchanged teardown timeout (5 === 5, no spurious write)", s.hooks.Stop[0].hooks[0].timeout === 5);
}

// T2: existing dead top-level (Claude-style) GSD schema. Codex's HooksFile uses
// serde deny_unknown_fields — a top-level key other than "hooks" breaks the WHOLE
// file (found on the live smoke). So foreign top-level keys are REMOVED (not
// migrated), saved write-once to a sidecar, and the file becomes {hooks} only.
{
  const d = caseDir("t2", JSON.stringify({
    PostToolUse: [{ matcher: "Edit|Write", hooks: [{ type: "command", command: "node \"C:/foo/gsd-hook.js\"" }] }],
    Stop: [{ hooks: [{ type: "command", command: "node \"C:/foo/gsd-stop.js\"" }] }],
    SubagentStart: [{ hooks: [{ type: "command", command: "node \"C:/foo/gsd-sub.js\"" }] }],
  }, null, 2));
  const r = run(d);
  const s = readJ(d);
  check("T2 exit 0", r.status === 0);
  check("T2 ONLY hooks at top level (valid wrapper)", Object.keys(s).length === 1 && !!s.hooks);
  check("T2 foreign top-level PostToolUse removed", s.PostToolUse === undefined);
  check("T2 foreign top-level Stop removed", s.Stop === undefined);
  check("T2 foreign SubagentStart removed", s.SubagentStart === undefined);
  check("T2 NOT migrated into wrapper (no gsd anywhere under hooks)", !JSON.stringify(s.hooks).includes("gsd-"));
  check("T2 our PermissionRequest under wrapper", s.hooks.PermissionRequest[0].hooks[0].command === CMD_PERM);
  check("T2 our Stop under wrapper", s.hooks.Stop[0].hooks[0].command === CMD_TD);
  check("T2 removal warning printed", /removed inactive top-level keys/.test(r.stderr), r.stderr.slice(0, 180));
  const sidecar = path.join(d, "hooks.json.disabled-by-press-1");
  check("T2 foreign keys saved to sidecar", fs.existsSync(sidecar)
    && JSON.parse(fs.readFileSync(sidecar, "utf8")).PostToolUse[0].hooks[0].command.includes("gsd-hook.js"));
  check("T2 backup created", fs.existsSync(path.join(d, "hooks.json.bak-codex-press-1")));

  // T3: idempotency — second run is a no-op (foreign keys gone, sidecar untouched).
  const before = readRaw(d);
  const sidecarBefore = fs.readFileSync(sidecar, "utf8");
  const r2 = run(d);
  check("T3 second run exit 0", r2.status === 0);
  check("T3 no changes", r2.stdout.includes("изменений нет"));
  check("T3 file byte-identical", readRaw(d) === before);
  check("T3 sidecar not overwritten (write-once)", fs.readFileSync(sidecar, "utf8") === sidecarBefore);
}

// T4: foreign hook already UNDER the wrapper (root.hooks.PostToolUse) → preserved,
// ours added alongside.
{
  const d = caseDir("t4", JSON.stringify({
    hooks: { PostToolUse: [{ hooks: [{ type: "command", command: "node \"C:/foo/other.js\"" }] }] },
  }));
  const r = run(d);
  const s = readJ(d);
  check("T4 exit 0", r.status === 0);
  check("T4 foreign wrapper hook preserved", s.hooks.PostToolUse[0].hooks[0].command.includes("other.js"));
  check("T4 our teardown added alongside", s.hooks.PostToolUse[1]?.hooks?.[0]?.command === CMD_TD);
}

// T5: invalid JSON → exit 1, file untouched.
{
  const d = caseDir("t5", "{ broken");
  const r = run(d);
  check("T5 exit 1", r.status === 1);
  check("T5 file untouched", readRaw(d) === "{ broken");
}

// T6: hooks.<event> not an array → fail loud, file untouched.
{
  const raw = JSON.stringify({ hooks: { PermissionRequest: { bad: true } } });
  const d = caseDir("t6", raw);
  const r = run(d);
  check("T6 exit 1", r.status === 1);
  check("T6 file untouched", readRaw(d) === raw);
}

// T13: statusMessage (hybrid Stage 2d) — written on a clean install for
// PermissionRequest ONLY (it legalizes the phase-1 hold in the TUI); the
// teardown entries stay message-less.
{
  const d = caseDir("t13");
  run(d);
  const s = readJ(d);
  const pr = s.hooks.PermissionRequest[0].hooks[0];
  check("T13 PermissionRequest statusMessage written",
    typeof pr.statusMessage === "string" && /press-1/.test(pr.statusMessage) && /Ctrl\+Win\+1\/2\/3/.test(pr.statusMessage),
    JSON.stringify(pr.statusMessage));
  check("T13 timeout still 70 alongside statusMessage", pr.timeout === 70);
  check("T13 no statusMessage on teardown entries",
    !("statusMessage" in s.hooks.Stop[0].hooks[0]) && !("statusMessage" in s.hooks.PostToolUse[0].hooks[0]));
}

// T14: set-exact — a pre-existing PermissionRequest entry WITHOUT statusMessage
// (Stage 2a/2c installs) is updated in place, and the second run is a no-op.
{
  const d = caseDir("t14", JSON.stringify({
    hooks: {
      PermissionRequest: [{ hooks: [{ type: "command", command: CMD_PERM, timeout: 70 }] }],
      Stop: [{ hooks: [{ type: "command", command: CMD_TD, timeout: 5 }] }],
      PostToolUse: [{ hooks: [{ type: "command", command: CMD_TD, timeout: 5 }] }],
    },
  }, null, 2));
  const r = run(d);
  const s = readJ(d);
  check("T14 exit 0", r.status === 0);
  check("T14 existing entry gains statusMessage (set-exact)",
    typeof s.hooks.PermissionRequest[0].hooks[0].statusMessage === "string");
  check("T14 no duplicate entry", s.hooks.PermissionRequest.length === 1);
  const r2 = run(d);
  check("T14 second run is a no-op", r2.stdout.includes("изменений нет"), r2.stdout);
}

// --- upsertTrust unit tests (pure function, no app-server) ---
const KEY = "C:\\Users\\Egor\\.codex\\hooks.json:permission_request:0:0";
const HASH = "sha256:abc123";

// T7: append at EOF when absent — later sections must survive untouched.
{
  const cfg = "[hooks.state]\n\n[hooks.state.'OTHER:session_start:0:0']\ntrusted_hash = \"sha256:zzz\"\n\n[windows]\nfoo = 1\n\n[projects.'C:\\p']\nbar = 2\n";
  const r = upsertTrust(cfg, KEY, HASH);
  check("T7 append: changed", r.changed && !r.skipped);
  check("T7 append: our table added", r.cfg.includes(`[hooks.state.'${KEY}']`) && r.cfg.includes(`trusted_hash = "${HASH}"`));
  check("T7 append: existing session_start table preserved", r.cfg.includes("OTHER:session_start:0:0"));
  check("T7 append: later [windows] preserved", r.cfg.includes("[windows]\nfoo = 1"));
  check("T7 append: later [projects] preserved", r.cfg.includes("[projects.'C:\\p']\nbar = 2"));
}

// T8: idempotent — same hash already present → no change.
{
  const cfg = `[hooks.state.'${KEY}']\ntrusted_hash = "${HASH}"\n`;
  const r = upsertTrust(cfg, KEY, HASH);
  check("T8 idempotent: no change", !r.changed && r.cfg === cfg);
}

// T9: changed hash → replace the value in place (no duplicate table).
{
  const cfg = `[hooks.state.'${KEY}']\ntrusted_hash = "sha256:OLD"\n\n[windows]\nx=1\n`;
  const r = upsertTrust(cfg, KEY, "sha256:NEW");
  check("T9 replace: changed", r.changed);
  check("T9 replace: new hash present", r.cfg.includes('trusted_hash = "sha256:NEW"'));
  check("T9 replace: old hash gone", !r.cfg.includes("sha256:OLD"));
  check("T9 replace: no duplicate table", (r.cfg.match(new RegExp(`\\[hooks\\.state\\.'${KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}'\\]`, "g")) || []).length === 1);
  check("T9 replace: [windows] preserved", r.cfg.includes("[windows]\nx=1"));
}

// T10: key with a single quote → skipped (TOML literal-key limitation), cfg untouched.
{
  const badKey = "C:\\Users\\O'Brien\\.codex\\hooks.json:permission_request:0:0";
  const cfg = "[hooks.state]\n";
  const r = upsertTrust(cfg, badKey, HASH);
  check("T10 single-quote key: skipped", r.skipped && !r.changed);
  check("T10 single-quote key: cfg untouched", r.cfg === cfg);
}

// T11: header present without a trusted_hash line → inserts one.
{
  const cfg = `[hooks.state.'${KEY}']\n`;
  const r = upsertTrust(cfg, KEY, HASH);
  check("T11 insert into header-only table: changed", r.changed);
  check("T11 insert: trusted_hash added", r.cfg.includes(`trusted_hash = "${HASH}"`));
}

// --- isOurHook unit tests ---
{
  const ours = { source: "user", handlerType: "command", command: "node \"C:/U/.codex/hooks/codex-permission-request.js\"", key: "k", currentHash: "h" };
  const teardown = { source: "user", handlerType: "command", command: "node \"C:/U/.codex/hooks/session-teardown.js\"" };
  const foreign = { source: "user", handlerType: "command", command: "node \"C:/foo/gsd-hook.js\"" };
  const managed = { source: "managed", handlerType: "command", command: "node \"C:/U/.codex/hooks/codex-permission-request.js\"" };
  check("T12 isOurHook: our permission hook matched", isOurHook(ours) === true);
  check("T12 isOurHook: our teardown matched", isOurHook(teardown) === true);
  check("T12 isOurHook: foreign rejected", isOurHook(foreign) === false);
  check("T12 isOurHook: non-user source rejected", isOurHook(managed) === false);
}

console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
process.exit(fail ? 1 : 0);
