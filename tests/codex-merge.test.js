// Tests for merge-codex-hooks.js — wrapper-schema merge into ~/.codex/hooks.json
// + the pure config.toml trust-upsert + own-hook matching. Isolated TEMP, env
// overrides; the app-server spawn is skipped (PRESS1_CODEX_SKIP_TRUST=1).
// Run: node tests/codex-merge.test.js
const fs = require("fs"), path = require("path"), os = require("os");
const { spawnSync } = require("child_process");

const MERGE = path.join(__dirname, "..", "merge-codex-hooks.js");
const { upsertTrust, isOurHook, resolveCodexCommand, assessTrustVerification } = require(MERGE);
const ROOT = path.join(os.tmpdir(), "press-1-tests", "codex-merge");
const HOOKS_DIR = "C:/Users/test/.codex/hooks";
const CMD_PERM = `node "${HOOKS_DIR}/codex-permission-request.js"`;
const CMD_TD = `node "${HOOKS_DIR}/session-teardown.js"`;
const CMD_ATTN = `node "${HOOKS_DIR}/codex-attention.js"`;
const CMD_GSD_WRAPPER = `node "${HOOKS_DIR}/codex-gsd-context-monitor.js"`;
const TRUST_REQUIRED_EXIT = 2;
const CODEX_NOT_FOUND_EXIT = 3;

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
const run = (dir) => spawnSync(process.execPath, [MERGE], {
  env: {
    ...process.env,
    CODEX_HOOKS_PATH: path.join(dir, "hooks.json"),
    CODEX_HOOKS_DIR: HOOKS_DIR,
    CODEX_CONFIG_PATH: path.join(dir, "config.toml"),
    PRESS1_CODEX_SKIP_TRUST: "1",
  },
  encoding: "utf8",
});
const envWithoutCodexResolution = () =>
  Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !["PATH", "PATHEXT", "LOCALAPPDATA", "PRESS1_CODEX_BIN", "PRESS1_CODEX_SKIP_TRUST"]
      .includes(key.toUpperCase())));
const runWithoutCodex = (dir) => {
  const env = envWithoutCodexResolution();
  return spawnSync(process.execPath, [MERGE], {
    env: {
      ...env,
      PATH: "",
      PATHEXT: ".EXE;.CMD",
      LOCALAPPDATA: path.join(dir, "no-codex-installed"),
      CODEX_HOOKS_PATH: path.join(dir, "hooks.json"),
      CODEX_HOOKS_DIR: HOOKS_DIR,
      CODEX_CONFIG_PATH: path.join(dir, "config.toml"),
    },
    encoding: "utf8",
  });
};
function runWithFakeCodex(dir, mode, useAbsoluteOverride = false) {
  // Mirrors the real npm location shape that exposed Windows shell splitting:
  // C:\Users\Test User\AppData\Roaming\npm\codex.cmd.
  const bin = path.join(dir, "Users", "Test User", "AppData", "Roaming", "npm");
  const server = path.join(dir, "fake-codex-app-server.js");
  fs.mkdirSync(bin, { recursive: true });
  const commands = [CMD_PERM, CMD_TD, CMD_TD, CMD_ATTN, CMD_ATTN, CMD_ATTN];
  fs.writeFileSync(server, `
const fs = require("fs");
const readline = require("readline");
if (process.env.FAKE_CODEX_MODE === "immediate_exit") process.exit(7);
const commands = ${JSON.stringify(commands)};
const hashes = ["sha256:permission", "sha256:stop", "sha256:post", "sha256:userprompt", "sha256:attentionstop", "sha256:sessionend"];
const eventNames = ["permission_request", "stop", "post_tool_use", "user_prompt_submit", "stop", "session_end"];
let cfg = "";
try { cfg = fs.readFileSync(process.env.CODEX_CONFIG_PATH, "utf8"); } catch {}
const configTrusted = hashes.every((hash) => cfg.includes('trusted_hash = "' + hash + '"'));
const entries = commands.map((command, i) => ({
  source: "user", handlerType: "command", command, eventName: eventNames[i],
  key: ["fake:permission:0:0", "fake:stop:0:0", "fake:post:0:0", "fake:userprompt:0:0", "fake:stop:1:0", "fake:sessionend:0:0"][i],
  currentHash: hashes[i],
  trustStatus: configTrusted ? "trusted" : "untrusted",
}));
const listed = process.env.FAKE_CODEX_MODE === "partial"
  ? entries.slice(0, 2).map((entry) => ({ ...entry, trustStatus: "untrusted" }))
  : entries;
const send = (msg, callback) => process.stdout.write(JSON.stringify(msg) + "\\n", callback);
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  } else if (msg.method === "hooks/list") {
    send({ jsonrpc: "2.0", id: msg.id, result: { data: [{ hooks: listed }] } },
      () => process.exit(0));
  }
});
`);
  const cmd = path.join(bin, "codex.cmd");
  fs.writeFileSync(cmd,
    `@echo off\r\n"${process.execPath}" "${server}" %*\r\n`);
  const childEnv = {
    ...envWithoutCodexResolution(),
    PATH: useAbsoluteOverride ? "" : bin,
    PATHEXT: ".CMD;.EXE",
    LOCALAPPDATA: path.join(dir, "no-desktop-fallback"),
    CODEX_HOOKS_PATH: path.join(dir, "hooks.json"),
    CODEX_HOOKS_DIR: HOOKS_DIR,
    CODEX_CONFIG_PATH: path.join(dir, "config.toml"),
    FAKE_CODEX_MODE: mode,
  };
  if (useAbsoluteOverride) childEnv.PRESS1_CODEX_BIN = cmd;
  return spawnSync(process.execPath, [MERGE], {
    env: childEnv,
    encoding: "utf8",
    timeout: 5000,
  });
}
const readRaw = (dir) => fs.readFileSync(path.join(dir, "hooks.json"), "utf8");
const readJ = (dir) => JSON.parse(readRaw(dir));

// T1: clean machine (no hooks.json) → wrapper schema with all press-1 entries.
{
  const d = caseDir("t1");
  const r = run(d);
  const s = readJ(d);
  check("T1 exit 2: hooks installed, trust deliberately unverified", r.status === TRUST_REQUIRED_EXIT, r.stderr);
  check("T1 machine-readable trust-required marker",
    r.stderr.includes("PRESS1_CODEX_RESULT=hooks_installed_trust_required"), r.stderr);
  check("T1 usable manual /hooks fallback", /run `codex`, then `\/hooks`/i.test(r.stderr), r.stderr);
  check("T1 wrapper: hooks.PermissionRequest present", s.hooks?.PermissionRequest?.[0]?.hooks?.[0]?.command === CMD_PERM);
  check("T1 PermissionRequest timeout 70 (small, not 3660; > 60s window + sound)", s.hooks.PermissionRequest[0].hooks[0].timeout === 70);
  check("T1 hooks.Stop present", s.hooks?.Stop?.[0]?.hooks?.[0]?.command === CMD_TD);
  check("T1 hooks.PostToolUse present", s.hooks?.PostToolUse?.[0]?.hooks?.[0]?.command === CMD_TD);
  check("T1 attention UserPromptSubmit present", s.hooks?.UserPromptSubmit?.[0]?.hooks?.[0]?.command === CMD_ATTN);
  check("T1 attention Stop present alongside teardown", s.hooks?.Stop?.[1]?.hooks?.[0]?.command === CMD_ATTN);
  check("T1 attention SessionEnd present", s.hooks?.SessionEnd?.[0]?.hooks?.[0]?.command === CMD_ATTN);
  check("T1 UserPromptSubmit context cap pinned", s.hooks.UserPromptSubmit[0].hooks[0].additionalContextLimit === 300);
  check("T1 NOT at top level", s.PermissionRequest === undefined);
}

// T1c: Claude-only machine — the Codex hooks are staged for a future install,
// but absence of any Codex binary is an optional skipped surface, not a failed
// press-1 installation.
{
  const d = caseDir("t1c-no-codex");
  const r = runWithoutCodex(d);
  const s = readJ(d);
  check("T1c exit 3: Codex surface absent, not a trust failure", r.status === CODEX_NOT_FOUND_EXIT, r.stderr);
  check("T1c machine-readable Codex-not-installed marker",
    r.stderr.includes("PRESS1_CODEX_RESULT=codex_not_installed"), r.stderr);
  check("T1c hooks.json merge is still safely staged", s.hooks?.PermissionRequest?.[0]?.hooks?.[0]?.command === CMD_PERM);
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
  check("T1b exit 2: merge succeeded but trust is unverified", r.status === TRUST_REQUIRED_EXIT, r.stderr);
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
  check("T2 exit 2: merge succeeded but trust is unverified", r.status === TRUST_REQUIRED_EXIT, r.stderr);
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
  check("T3 second run exit 2: idempotent merge, trust still unverified", r2.status === TRUST_REQUIRED_EXIT, r2.stderr);
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
  check("T4 exit 2: merge succeeded but trust is unverified", r.status === TRUST_REQUIRED_EXIT, r.stderr);
  check("T4 foreign wrapper hook preserved", s.hooks.PostToolUse[0].hooks[0].command.includes("other.js"));
  check("T4 our teardown added alongside", s.hooks.PostToolUse[1]?.hooks?.[0]?.command === CMD_TD);
}

// T5: invalid JSON → exit 1, file untouched.

// T4b: GSD's context monitor must keep its Stop side effects but its empty/plain
// output is invalid for Codex Stop. Only that Stop registration is wrapped;
// the normal PostToolUse registration remains owned by GSD and untouched.
{
  const directGsd = '"C:/Users/test/.codex/hooks/gsd-context-monitor.cmd"';
  const d = caseDir("t4b-gsd-stop-wrapper", JSON.stringify({ hooks: {
    Stop: [{ hooks: [{ type: "command", command: directGsd, timeout: 10 }] }],
    PostToolUse: [{ hooks: [{ type: "command", command: directGsd, timeout: 10 }] }],
  } }));
  const r = run(d);
  const s = readJ(d);
  check("T4b incompatible GSD Stop is wrapped", s.hooks.Stop[0].hooks[0].command === CMD_GSD_WRAPPER);
  check("T4b GSD timeout preserved", s.hooks.Stop[0].hooks[0].timeout === 10);
  check("T4b GSD PostToolUse remains direct", s.hooks.PostToolUse[0].hooks[0].command === directGsd);
  check("T4b compatibility action logged", r.stdout.includes("wrapped incompatible GSD"), r.stdout);
  const before = readRaw(d);
  const r2 = run(d);
  check("T4b wrapper merge is idempotent", readRaw(d) === before && r2.stdout.includes("изменений нет"), r2.stdout);
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
  check("T14 exit 2: merge succeeded but trust is unverified", r.status === TRUST_REQUIRED_EXIT, r.stderr);
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
  const attention = { source: "user", handlerType: "command", command: "node \"C:/U/.codex/hooks/codex-attention.js\"" };
  const gsdWrapper = { source: "user", handlerType: "command", command: "node \"C:/U/.codex/hooks/codex-gsd-context-monitor.js\"" };
  const foreign = { source: "user", handlerType: "command", command: "node \"C:/foo/gsd-hook.js\"" };
  const managed = { source: "managed", handlerType: "command", command: "node \"C:/U/.codex/hooks/codex-permission-request.js\"" };
  check("T12 isOurHook: our permission hook matched", isOurHook(ours) === true);
  check("T12 isOurHook: our teardown matched", isOurHook(teardown) === true);
  check("T12 isOurHook: our attention hook matched", isOurHook(attention) === true);
  check("T12 isOurHook: our GSD Stop wrapper matched", isOurHook(gsdWrapper) === true);
  check("T12 isOurHook: foreign rejected", isOurHook(foreign) === false);
  check("T12 isOurHook: non-user source rejected", isOurHook(managed) === false);
}

// T15: trust verification is strict: all installed press-1 entries must
// be visible and trusted/managed. A partial list or any untrusted entry keeps
// the installer in the manual-action state.
{
  const hook = (key, eventName, command, trustStatus) => ({
    source: "user", handlerType: "command", command, key, eventName,
    currentHash: `sha256:${key}`, trustStatus,
  });
  const allTrusted = [
    hook("C:/U/.codex/hooks.json:permission_request:0:0", "permission_request", CMD_PERM, "trusted"),
    hook("C:/U/.codex/hooks.json:stop:0:0", "stop", CMD_TD, "trusted"),
    hook("C:/U/.codex/hooks.json:post_tool_use:0:0", "post_tool_use", CMD_TD, "managed"),
    hook("C:/U/.codex/hooks.json:user_prompt_submit:0:0", "user_prompt_submit", CMD_ATTN, "trusted"),
    hook("C:/U/.codex/hooks.json:stop:1:0", "stop", CMD_ATTN, "trusted"),
    hook("C:/U/.codex/hooks.json:session_end:0:0", "session_end", CMD_ATTN, "trusted"),
  ];
  let r = assessTrustVerification(allTrusted);
  check("T15 realistic required eventName+script slots verify", r.verified === true, JSON.stringify(r));

  r = assessTrustVerification(allTrusted.slice(0, 2));
  check("T15 partial hooks/list does not verify", r.verified === false && r.oursCount === 2, JSON.stringify(r));

  r = assessTrustVerification([allTrusted[0], allTrusted[0], allTrusted[1]]);
  check("T15 duplicate keys do not impersonate installed hooks",
    r.verified === false && r.oursCount === 2, JSON.stringify(r));

  const permissionOnly = [0, 1, 2].map((i) => hook(
    `C:/U/.codex/hooks.json:permission_request:${i}:0`,
    "permission_request", CMD_PERM, "trusted"
  ));
  r = assessTrustVerification(permissionOnly);
  check("T15 three distinct PermissionRequest keys cannot impersonate required slots",
    r.verified === false && r.matchedSlotCount === 1
      && r.missingSlots.includes("stop") && r.missingSlots.includes("post_tool_use"),
    JSON.stringify(r));

  const legacyWireNames = [
    { ...allTrusted[0], eventName: "permissionRequest" },
    allTrusted[1],
    { ...allTrusted[2], eventName: "postToolUse" },
    { ...allTrusted[3], eventName: "userPromptSubmit" },
    allTrusted[4],
    { ...allTrusted[5], eventName: "sessionEnd" },
  ];
  r = assessTrustVerification(legacyWireNames);
  check("T15 documented legacy camelCase eventName aliases still verify",
    r.verified === true, JSON.stringify(r));

  r = assessTrustVerification([
    allTrusted[0], allTrusted[1], { ...allTrusted[2], trustStatus: "untrusted" },
    allTrusted[3], allTrusted[4], allTrusted[5],
  ]);
  check("T15 one untrusted entry does not verify", r.verified === false && r.untrustedCount === 1, JSON.stringify(r));

  const optionalWrapper = hook("C:/U/.codex/hooks.json:stop:2:0", "stop", CMD_GSD_WRAPPER, "trusted");
  r = assessTrustVerification([...allTrusted, optionalWrapper]);
  check("T15 trusted optional GSD wrapper verifies", r.verified === true && r.oursCount === 7, JSON.stringify(r));
  r = assessTrustVerification([...allTrusted, { ...optionalWrapper, trustStatus: "untrusted" }]);
  check("T15 untrusted optional GSD wrapper blocks verification", r.verified === false && r.untrustedCount === 1, JSON.stringify(r));
}

// T16: Codex command resolver supports Desktop-only installs without guessing a
// fixed build hash: explicit test override -> PATH -> newest Desktop bundle.
{
  const d = path.join(ROOT, "t16-resolver");
  const pathDir = path.join(d, "path-bin");
  const local = path.join(d, "local");
  const oldExe = path.join(local, "OpenAI", "Codex", "bin", "old-build", "codex.exe");
  const newExe = path.join(local, "OpenAI", "Codex", "bin", "new-build", "codex.exe");
  fs.mkdirSync(pathDir, { recursive: true });
  fs.mkdirSync(path.dirname(oldExe), { recursive: true });
  fs.mkdirSync(path.dirname(newExe), { recursive: true });
  fs.writeFileSync(path.join(pathDir, "codex.cmd"), "@exit /b 0\n");
  fs.writeFileSync(oldExe, "old");
  fs.writeFileSync(newExe, "new");
  fs.utimesSync(oldExe, new Date(1_000), new Date(1_000));
  fs.utimesSync(newExe, new Date(2_000), new Date(2_000));

  let r = resolveCodexCommand({
    PRESS1_CODEX_BIN: "C:\\test\\explicit-codex.exe",
    PATH: pathDir, PATHEXT: ".EXE;.CMD", LOCALAPPDATA: local,
  }, "win32");
  check("T16 explicit override wins and absolute binary avoids shell",
    r?.source === "env" && r.command === "C:\\test\\explicit-codex.exe" && r.shell === false,
    JSON.stringify(r));

  const absoluteCmd = path.join(pathDir, "codex.cmd");
  r = resolveCodexCommand({ PRESS1_CODEX_BIN: absoluteCmd }, "win32");
  check("T16 absolute .cmd override is explicitly supported via shell",
    r?.source === "env" && r.command === absoluteCmd && r.shell === true,
    JSON.stringify(r));

  r = resolveCodexCommand({ PATH: pathDir, PATHEXT: ".EXE;.CMD", LOCALAPPDATA: local }, "win32");
  check("T16 PATH command resolves exact .cmd and uses Windows shell",
    r?.source === "path" && r.command.toLowerCase() === absoluteCmd.toLowerCase() && r.shell === true,
    JSON.stringify(r));

  const exePathDir = path.join(d, "path-exe-bin");
  const pathExe = path.join(exePathDir, "codex.exe");
  fs.mkdirSync(exePathDir, { recursive: true });
  fs.writeFileSync(pathExe, "exe");
  r = resolveCodexCommand({ PATH: exePathDir, PATHEXT: ".EXE", LOCALAPPDATA: local }, "win32");
  check("T16 PATH .exe resolves exactly without a shell",
    r?.source === "path" && r.command.toLowerCase() === pathExe.toLowerCase() && r.shell === false,
    JSON.stringify(r));

  r = resolveCodexCommand({ PATH: "", PATHEXT: ".EXE;.CMD", LOCALAPPDATA: local }, "win32");
  check("T16 Desktop fallback selects newest bundled codex.exe without shell",
    r?.source === "desktop" && r.command === newExe && r.shell === false,
    JSON.stringify(r));

  r = resolveCodexCommand({
    PATH: "", PATHEXT: ".EXE;.CMD", LOCALAPPDATA: path.join(d, "missing"),
  }, "win32");
  check("T16 missing PATH and Desktop binaries resolve to null", r === null, JSON.stringify(r));
}

// T17: the PowerShell installer must distinguish "merge failed" from
// "hooks installed, trust still required" and include the latter in its final
// problems list instead of printing a false fully-successful completion.
{
  const install = fs.readFileSync(path.join(__dirname, "..", "install.ps1"), "utf8");
  check("T17 install handles dedicated trust-required exit code",
    install.includes("$codexMergeExit -eq 2"));
  check("T17 install adds unverified trust to final problems list",
    install.includes('$problems += "Codex hooks installed but NOT TRUSTED'));
  const noCodexBranch = install.match(/\} elseif \(\$codexMergeExit -eq 3\) \{([\s\S]*?)\} elseif/);
  check("T17 install handles Codex-not-installed exit separately", !!noCodexBranch);
  check("T17 missing optional Codex emits warning but does not add a final problem",
    !!noCodexBranch && /Codex support was skipped/.test(noCodexBranch[1])
      && !noCodexBranch[1].includes("$problems"), noCodexBranch?.[1]);
}

// T18/T19: full auto-trust handshake through a deterministic fake app-server.
// This exercises both app-server calls, config.toml writes, strict re-list
// verification, process markers, and exit codes without touching real Codex.
{
  const d = caseDir("t18-auto-trust-success");
  const r = runWithFakeCodex(d, "success");
  const cfgPath = path.join(d, "config.toml");
  const cfg = fs.existsSync(cfgPath) ? fs.readFileSync(cfgPath, "utf8") : "";
  check("T18 verified auto-trust exits 0", r.status === 0, `${r.error || ""}\n${r.stdout}\n${r.stderr}`);
  check("T18 trusted machine marker emitted",
    r.stdout.includes("PRESS1_CODEX_RESULT=hooks_installed_trusted"), r.stdout + r.stderr);
  check("T18 all six current hashes written to config.toml",
    ["sha256:permission", "sha256:stop", "sha256:post", "sha256:userprompt", "sha256:attentionstop", "sha256:sessionend"]
      .every((hash) => cfg.includes(hash)), cfg);
}

{
  const d = caseDir("t19-auto-trust-partial");
  const r = runWithFakeCodex(d, "partial");
  const s = readJ(d);
  check("T19 partial/untrusted re-list exits 2", r.status === TRUST_REQUIRED_EXIT,
    `${r.error || ""}\n${r.stdout}\n${r.stderr}`);
  check("T19 trust-required machine marker emitted",
    r.stderr.includes("PRESS1_CODEX_RESULT=hooks_installed_trust_required"), r.stdout + r.stderr);
  check("T19 hooks.json merge remains applied despite trust failure",
    s.hooks?.PermissionRequest?.[0]?.hooks?.[0]?.command === CMD_PERM);
}

// T20: a discovered command that exits before the RPC handshake must fail fast,
// not wait for the 15 s watchdog or crash on an unhandled stdin EPIPE.
{
  const d = caseDir("t20-app-server-immediate-exit");
  const started = Date.now();
  const r = runWithFakeCodex(d, "immediate_exit");
  const elapsed = Date.now() - started;
  check("T20 immediate app-server exit becomes trust failure",
    r.status === TRUST_REQUIRED_EXIT
      && r.stderr.includes("PRESS1_CODEX_RESULT=hooks_installed_trust_required"),
    `elapsed=${elapsed} error=${r.error || ""}\n${r.stdout}\n${r.stderr}`);
  check("T20 immediate app-server exit fails in under 2 seconds",
    elapsed < 2000, `elapsed=${elapsed}ms status=${r.status} error=${r.error || ""}`);
}

// T21: the explicit absolute .cmd override uses the same quoted shell path as
// PATH discovery; spaces in a user profile must not split the executable name.
{
  const d = caseDir("t21-absolute-cmd-override-spaces");
  const r = runWithFakeCodex(d, "success", true);
  check("T21 absolute .cmd override with spaces completes the handshake",
    r.status === 0 && r.stdout.includes("PRESS1_CODEX_RESULT=hooks_installed_trusted"),
    `${r.error || ""}\n${r.stdout}\n${r.stderr}`);
}

console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
process.exit(fail ? 1 : 0);
