// Offline tests for codex-permission-request.js: Codex host fingerprint,
// decision channel (panel/WT/vsterm/conhost — every host blocks on it), 3-button
// options, clamped wait window, always-allow → default.rules append (tokenize +
// escape + dedup), no updatedPermissions echo, exact auto-review pass-through,
// fail-safe. Isolated TEMP/USERPROFILE per test.
// Run: node tests/codex-hook.test.js
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HOOK = path.join(__dirname, "..", "codex-permission-request.js");
const BASE = path.join(require("os").tmpdir(), "press-1-tests", "codex-hook");
const REVIEWER_STATUS_FIELDS = [
  "attempts", "elapsed_ms", "file_bytes", "grew", "outcome", "pid", "reason",
  "scanned_bytes", "schema", "tail_truncated", "ts",
];
const REVIEWER_STATUS_REASONS = new Set([
  "exact_auto_review", "reviewer_user", "reviewer_other", "input_missing",
  "path_rejected", "read_failed", "turn_not_found", "record_invalid",
  "reviewer_conflict", "budget_exceeded",
]);

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log(`  OK   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}${extra ? " — " + extra : ""}`); }
}

function freshTemp(name) {
  const dir = path.join(BASE, name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// Codex sets NO CLAUDE_CODE_ENTRYPOINT. Clear every host marker (the runner may
// itself live in a VS Code terminal) then set only what the case needs.
function hostEnv(kind) {
  const env = { ...process.env };
  for (const k of ["CLAUDE_CODE_ENTRYPOINT", "TERM_PROGRAM", "WT_SESSION", "VSCODE_PID",
    "VSCODE_GIT_ASKPASS_NODE", "PRESS1_CODEX_WAIT_MS", "PRESS1_CODEX_HYBRID_WAIT_MS",
    "PRESS1_CODEX_RULES_PATH",
    "PRESS1_CODEX_NATIVE_CONTROL", "PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS", "PRESS1_PROXY",
    "CODEX_HOME"]) delete env[k];
  if (kind === "panel") env.VSCODE_PID = "4242";
  if (kind === "wt") env.WT_SESSION = "guid-test";
  if (kind === "vsterm") {
    env.TERM_PROGRAM = "vscode";
    env.VSCODE_GIT_ASKPASS_NODE = "C:/Users/test/AppData/Local/Programs/cursor/Cursor.exe";
  }
  // conhost: nothing set → classifyHost falls through to conhost.
  return env;
}

const PAYLOAD = {
  session_id: "cdx-sess-1",
  tool_name: "Bash",
  tool_input: { command: "node -e \"console.log('x')\"" },
  cwd: "D:/dev/proj-a",
  permission_mode: "default",
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(cond, timeoutMs, stepMs = 80) {
  const t0 = Date.now();
  for (;;) {
    const v = cond();
    if (v) return v;
    if (Date.now() - t0 > timeoutMs) return null;
    await sleep(stepMs);
  }
}
function pendingFiles(tempDir) {
  const dir = path.join(tempDir, "press-1", "pending");
  try { return fs.readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => path.join(dir, f)); }
  catch { return []; }
}
function runHookAsync(payload, env, tempDir, extra = {}) {
  const e = {
    ...env,
    TEMP: tempDir,
    TMP: tempDir,
    USERPROFILE: tempDir,
    PRESS1_NO_SOUND: "1",
    PRESS1_CODEX_NATIVE_CONTROL: "0",
    ...extra,
  };
  const child = spawn("node", [HOOK], { env: e });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", () => {});
  let exitCode = null;
  const exitP = new Promise((r) => child.on("exit", (c) => { exitCode = c; r(c); }));
  child.stdin.write(JSON.stringify(payload));
  child.stdin.end();
  return {
    child,
    stdout: () => out,
    exitCode: () => exitCode,
    waitExit: (ms) => Promise.race([exitP, sleep(ms).then(() => "timeout")]),
  };
}
function writeDecision(decisionFile, word) {
  const tmp = decisionFile + ".tmp";
  fs.writeFileSync(tmp, word, "utf8");
  fs.renameSync(tmp, decisionFile);
}

function reviewerStatusPath(tempDir) {
  return path.join(tempDir, "press-1", "codex-reviewer-last.json");
}
function readReviewerStatus(tempDir) {
  try { return JSON.parse(fs.readFileSync(reviewerStatusPath(tempDir), "utf8")); }
  catch { return null; }
}
function transcriptPath(tempDir, name = "rollout.jsonl", codexHome = path.join(tempDir, ".codex")) {
  const dir = path.join(codexHome, "sessions", "2026", "07", "26");
  fs.mkdirSync(dir, { recursive: true });
  return path.join(dir, name);
}
function writeJsonl(file, records) {
  const text = records
    .map((record) => typeof record === "string" ? record : JSON.stringify(record))
    .join("\n") + "\n";
  fs.writeFileSync(file, text, "utf8");
  return file;
}
function turnContext(turnId, reviewer, extra = {}) {
  return {
    type: "turn_context",
    payload: { turn_id: turnId, approvals_reviewer: reviewer, ...extra },
  };
}
function reviewerPayload(file, turnId = "turn-reviewer-1", extra = {}) {
  return { ...PAYLOAD, turn_id: turnId, transcript_path: file, ...extra };
}
// Child-only fs/parse instrumentation. NODE_OPTIONS loads this before the hook
// so the production file needs no test seam: modes record/choke transcript I/O,
// force snapshot growth, or delay only a multi-megabyte JSON.parse call.
function reviewerFsProbeEnv(tempDir, transcript, mode = "record") {
  const preload = path.join(tempDir, "reviewer-fs-preload.cjs");
  const log = path.join(tempDir, "reviewer-fs-probe.json");
  fs.writeFileSync(preload, `
const fs = require("fs");
const path = require("path");
const target = path.resolve(fs.realpathSync(process.env.PRESS1_TEST_TRANSCRIPT)).toLowerCase();
const log = process.env.PRESS1_TEST_READ_LOG;
const mode = process.env.PRESS1_TEST_FS_MODE;
const openSync = fs.openSync;
const readSync = fs.readSync;
const readFileSync = fs.readFileSync;
const writeFileSync = fs.writeFileSync;
const jsonParse = JSON.parse;
let targetFd = -1;
let opens = 0;
let calls = 0;
let fileReads = 0;
let maxRead = 0;
let mutated = false;
function writeProbe() {
  writeFileSync(log, JSON.stringify({ opens, calls, fileReads, maxRead }), "utf8");
}
fs.openSync = function(file, flags, fileMode) {
  const fd = openSync(file, flags, fileMode);
  if (flags === "r" && path.resolve(String(file)).toLowerCase() === target) {
    targetFd = fd;
    opens++;
    writeProbe();
  }
  return fd;
};
fs.readSync = function(fd, buffer, offset, length, position) {
  const n = readSync(fd, buffer, offset, length, position);
  if (fd !== targetFd) return n;
  calls++;
  maxRead = Math.max(maxRead, length);
  writeProbe();
  if (mode === "slow-read") {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
  if (mode === "grow-once" && !mutated) {
    mutated = true;
    const appendFd = openSync(process.env.PRESS1_TEST_TRANSCRIPT, "a");
    try { fs.writeSync(appendFd, "\\n"); } finally { fs.closeSync(appendFd); }
  }
  return n;
};
fs.readFileSync = function(file, options) {
  if (typeof file !== "number" && path.resolve(String(file)).toLowerCase() === target) {
    fileReads++;
    writeProbe();
  }
  return readFileSync(file, options);
};
JSON.parse = function(text, reviver) {
  if (mode === "slow-parse" && typeof text === "string" && text.length > 4 * 1024 * 1024) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 300);
  }
  return jsonParse(text, reviver);
};
`, "utf8");
  return {
    NODE_OPTIONS: `--require="${preload.replace(/\\/g, "/")}"`,
    PRESS1_TEST_TRANSCRIPT: transcript,
    PRESS1_TEST_READ_LOG: log,
    PRESS1_TEST_FS_MODE: mode,
    probeLog: log,
  };
}

// Simulate a filesystem ambiguity while checking the dedicated auto-review
// opt-out: the production lstatSync lookup fails with EACCES → probe disabled.
function autoReviewFlagErrorEnv(tempDir, flag) {
  const preload = path.join(tempDir, "auto-review-flag-preload.cjs");
  fs.writeFileSync(preload, `
const fs = require("fs");
const path = require("path");
const target = path.resolve(process.env.PRESS1_TEST_AUTO_REVIEW_FLAG).toLowerCase();
const lstatSync = fs.lstatSync;
function isTarget(file) {
  return path.resolve(String(file)).toLowerCase() === target;
}
function blocked() {
  const error = new Error("simulated flag lookup failure");
  error.code = "EACCES";
  throw error;
}
fs.lstatSync = function(file, options) {
  if (isTarget(file)) return blocked();
  return lstatSync(file, options);
};
`, "utf8");
  return {
    NODE_OPTIONS: `--require="${preload.replace(/\\/g, "/")}"`,
    PRESS1_TEST_AUTO_REVIEW_FLAG: flag,
  };
}

// Simulate the opt-out becoming ambiguous after the reviewer probe starts.
// The first lookup proves the flag absent; the second must fail closed before
// status is written or an exact auto_review request is bypassed.
function autoReviewFlagSecondCheckErrorEnv(tempDir, flag) {
  const preload = path.join(tempDir, "auto-review-flag-second-check-preload.cjs");
  fs.writeFileSync(preload, `
const fs = require("fs");
const path = require("path");
const target = path.resolve(process.env.PRESS1_TEST_AUTO_REVIEW_FLAG).toLowerCase();
const lstatSync = fs.lstatSync;
let targetCalls = 0;
fs.lstatSync = function(file, options) {
  if (path.resolve(String(file)).toLowerCase() === target) {
    targetCalls++;
    if (targetCalls === 2) {
      const error = new Error("simulated second-check flag lookup failure");
      error.code = "EACCES";
      throw error;
    }
  }
  return lstatSync(file, options);
};
`, "utf8");
  return {
    NODE_OPTIONS: `--require="${preload.replace(/\\/g, "/")}"`,
    PRESS1_TEST_AUTO_REVIEW_FLAG: flag,
  };
}

// Observe whether the hook passed through before creating a pending, or reached
// the existing popup route. A popup is answered with `pass` so RED cases never
// sit through the 60-second conhost decision window.
async function observeReviewerRoute(payload, env, tempDir, extra = {}) {
  const h = runHookAsync(payload, env, tempDir, extra);
  const seen = await waitFor(() => {
    const pending = pendingFiles(tempDir)[0];
    if (pending) return { route: "popup", pending };
    if (h.exitCode() !== null) return { route: "auto_pass", pending: null };
    return null;
  }, 5000);
  if (!seen) {
    try { h.child.kill(); } catch {}
    await h.waitExit(2000);
    return { route: "timeout", code: h.exitCode(), stdout: h.stdout(), pending: null };
  }
  if (seen.pending) {
    try {
      const entry = JSON.parse(fs.readFileSync(seen.pending, "utf8"));
      writeDecision(entry.decision_file, "pass");
    } catch {
      try { fs.unlinkSync(seen.pending); } catch {}
    }
  }
  const code = await h.waitExit(5000);
  return { ...seen, code, stdout: h.stdout() };
}

function checkReviewerStatus(name, status, outcome, reason) {
  check(`${name} status written`, !!status);
  if (!status) return;
  check(`${name} status outcome/reason`, status.outcome === outcome && status.reason === reason,
    JSON.stringify({ outcome: status.outcome, reason: status.reason }));
  check(`${name} status reason is enumerated`, REVIEWER_STATUS_REASONS.has(status.reason), status.reason);
  check(`${name} status schema has exact safe fields`,
    JSON.stringify(Object.keys(status).sort()) === JSON.stringify(REVIEWER_STATUS_FIELDS),
    Object.keys(status).sort().join(","));
  check(`${name} status metric types`,
    status.schema === 1 && Number.isFinite(status.ts) && Number.isInteger(status.pid)
      && status.pid > 0 && Number.isFinite(status.elapsed_ms) && status.elapsed_ms >= 0
      && Number.isInteger(status.attempts) && status.attempts >= 0
      && Number.isInteger(status.file_bytes) && status.file_bytes >= 0
      && Number.isInteger(status.scanned_bytes) && status.scanned_bytes >= 0
      && typeof status.grew === "boolean" && typeof status.tail_truncated === "boolean");
}

async function runReviewerCase(name, payload, env, tempDir, expectedRoute, expectedStatus, extra = {}) {
  const result = await observeReviewerRoute(payload, env, tempDir, extra);
  check(`${name} route=${expectedRoute}`, result.route === expectedRoute, `route=${result.route}`);
  check(`${name} exits 0`, result.code === 0, `code=${result.code}`);
  check(`${name} stdout empty`, result.stdout.trim() === "", result.stdout.slice(0, 120));
  const status = readReviewerStatus(tempDir);
  if (expectedStatus) checkReviewerStatus(name, status, expectedStatus.outcome, expectedStatus.reason);
  else check(`${name} writes no reviewer status`, status === null);
  return { result, status };
}

async function main() {
  // T1: panel host → pending carries agent=codex, decision channel, 3 buttons,
  // no walk; allow decision → stdout allow with NO updatedPermissions.
  {
    const dir = freshTemp("t1");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T1 panel pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T1 agent=codex", j.agent === "codex");
      check("T1 host.type=vscode-extension", j.host.type === "vscode-extension");
      check("T1 kind=permission", j.kind === "permission");
      check("T1 options 3-button", JSON.stringify(j.options) === JSON.stringify(["Allow", "Always allow", "Deny"]));
      check("T1 decision_file declared", typeof j.decision_file === "string" && j.decision_file.includes("response-hook-"));
      check("T1 no walk for panel", j.host.walk_ms === 0 && j.host.ancestry.length === 0);
      writeDecision(j.decision_file, "allow");
      const r = await h.waitExit(5000);
      check("T1 hook exited after decision", r !== "timeout");
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T1 stdout allow", dec && dec.behavior === "allow");
      check("T1 NO updatedPermissions echoed", dec && !("updatedPermissions" in dec));
      check("T1 pending cleaned up", !fs.existsSync(pf));
    }
  }

  // T2: deny → stdout deny with message.
  {
    const dir = freshTemp("t2");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T2 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "deny");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T2 stdout deny", dec && dec.behavior === "deny" && /Denied by user/.test(dec.message), h.stdout().slice(0, 120));
    }
  }

  // T3: always → stdout allow AND a prefix_rule appended to default.rules.
  {
    const dir = freshTemp("t3");
    const rules = path.join(dir, "default.rules");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { PRESS1_CODEX_RULES_PATH: rules });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T3 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "always");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T3 stdout allow (always → allow)", dec && dec.behavior === "allow");
      check("T3 no updatedPermissions on always", dec && !("updatedPermissions" in dec));
      const ruleTxt = fs.existsSync(rules) ? fs.readFileSync(rules, "utf8") : "";
      const expected = 'prefix_rule(pattern=["node", "-e", "console.log(\'x\')"], decision="allow")';
      check("T3 prefix_rule appended (full-command, tokenized)", ruleTxt.includes(expected), ruleTxt);
    }
  }

  // T4: always with a backslash/space Windows path → backslashes escaped; second
  // identical always does NOT duplicate the line (exact-line dedup).
  {
    const dir = freshTemp("t4");
    const rules = path.join(dir, "default.rules");
    const payload = { ...PAYLOAD, tool_input: { command: '"C:\\Program Files\\app.exe" --run' } };
    for (let i = 0; i < 2; i++) {
      const h = runHookAsync(payload, hostEnv("panel"), dir, { PRESS1_CODEX_RULES_PATH: rules });
      const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
      if (pf) { writeDecision(JSON.parse(fs.readFileSync(pf, "utf8")).decision_file, "always"); await h.waitExit(5000); }
    }
    const ruleTxt = fs.existsSync(rules) ? fs.readFileSync(rules, "utf8") : "";
    const expected = 'prefix_rule(pattern=["C:\\\\Program Files\\\\app.exe", "--run"], decision="allow")';
    check("T4 backslashes escaped in rule", ruleTxt.includes(expected), ruleTxt);
    const occurrences = ruleTxt.split(expected).length - 1;
    check("T4 dedup — exactly one line after two always", occurrences === 1, `occurrences=${occurrences}`);
  }

  // T5: always on a non-Bash tool (no command) → allow, but NO rule written.
  {
    const dir = freshTemp("t5");
    const rules = path.join(dir, "default.rules");
    const payload = { session_id: "cdx-write", tool_name: "Write", tool_input: { file_path: "D:/dev/proj-a/x.txt" }, cwd: "D:/dev/proj-a" };
    const h = runHookAsync(payload, hostEnv("panel"), dir, { PRESS1_CODEX_RULES_PATH: rules });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) { writeDecision(JSON.parse(fs.readFileSync(pf, "utf8")).decision_file, "always"); await h.waitExit(5000); }
    let dec = null; try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
    check("T5 always allow on non-Bash tool", dec && dec.behavior === "allow");
    check("T5 NO rule written for empty command", !fs.existsSync(rules) || fs.readFileSync(rules, "utf8").trim() === "");
  }

  // T6: classifyHost — WT walks, vsterm/conhost classify, conhost is the fallback.
  {
    const dirWT = freshTemp("t6-wt");
    const hWT = runHookAsync(PAYLOAD, hostEnv("wt"), dirWT);
    const pWT = await waitFor(() => pendingFiles(dirWT)[0], 8000);
    if (pWT) {
      const j = JSON.parse(fs.readFileSync(pWT, "utf8"));
      check("T6 WT_SESSION → windows-terminal", j.host.type === "windows-terminal");
      check("T6 WT walks (walk_ms > 0)", j.host.walk_ms > 0);
      writeDecision(j.decision_file, "allow"); await hWT.waitExit(5000);
    }
    const dirVT = freshTemp("t6-vt");
    const hVT = runHookAsync(PAYLOAD, hostEnv("vsterm"), dirVT);
    const pVT = await waitFor(() => pendingFiles(dirVT)[0], 8000);
    if (pVT) {
      const j = JSON.parse(fs.readFileSync(pVT, "utf8"));
      check("T6 TERM_PROGRAM=vscode → vscode-terminal", j.host.type === "vscode-terminal");
      check("T6 vsterm editor_exe captured", j.host.editor_exe === "Cursor.exe", j.host.editor_exe);
      check("T6 vsterm no walk", j.host.walk_ms === 0);
      writeDecision(j.decision_file, "allow"); await hVT.waitExit(5000);
    }
    const dirCH = freshTemp("t6-ch");
    const hCH = runHookAsync(PAYLOAD, hostEnv("conhost"), dirCH);
    const pCH = await waitFor(() => pendingFiles(dirCH)[0], 8000);
    if (pCH) {
      const j = JSON.parse(fs.readFileSync(pCH, "utf8"));
      check("T6 no markers → conhost fallback (never unknown)", j.host.type === "conhost");
      check("T6 conhost no walk in 2a", j.host.walk_ms === 0);
      writeDecision(j.decision_file, "allow"); await hCH.waitExit(5000);
    }
  }

  // T7: wait window clamp — a too-large PRESS1_CODEX_WAIT_MS is capped at 60 s
  // (= 70 s hooks.json outer timeout − 4 s sound − 3 s WT walk − 3 s margin).
  // wait_until additionally carries the 4 s sound budget on top of the window.
  {
    const dir = freshTemp("t7");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { PRESS1_CODEX_WAIT_MS: "99999" });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T7 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const window = j.wait_until - j.timestamp;
      check("T7 wait clamped to 60s+sound (not 99999)", window <= 64500 && window >= 63500, `window=${window}`);
      writeDecision(j.decision_file, "allow"); await h.waitExit(5000);
    }
  }

  // T8: default decision-only window 60 s (+4 s sound budget in wait_until) —
  // the pre-hybrid behavior must stay intact under PRESS1_CODEX_NATIVE_CONTROL=0.
  {
    const dir = freshTemp("t8");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const window = j.wait_until - j.timestamp;
      check("T8 decision-only default window 60s+sound", window >= 63000 && window <= 65000, `window=${window}`);
      writeDecision(j.decision_file, "allow"); await h.waitExit(5000);
    }
  }

  // T9: early-exit — deleting the pending releases the blocked hook (pass-through,
  // empty stdout), exactly like the Claude hook.
  {
    const dir = freshTemp("t9");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T9 pending written", !!pf);
    if (pf) {
      fs.unlinkSync(pf);
      const r = await h.waitExit(5000);
      check("T9 hook exited on pending deletion", r !== "timeout");
      check("T9 no stdout (pass-through)", h.stdout().trim() === "");
    }
  }

  // T10: fail-safe — malformed stdin never crashes, exits 0, writes nothing.
  {
    const dir = freshTemp("t10");
    const e = { ...hostEnv("panel"), TEMP: dir, TMP: dir, PRESS1_NO_SOUND: "1" };
    const child = spawn("node", [HOOK], { env: e });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    const code = await new Promise((r) => { child.on("exit", r); child.stdin.write("{ not json"); child.stdin.end(); });
    check("T10 malformed stdin → exit 0", code === 0, `code=${code}`);
    check("T10 malformed stdin → no stdout", out.trim() === "");
  }

  // T11: per-agent kill switch — ~/.press-1-off-codex present → hook exits 0
  // empty and writes no pending (press-1 out of the way → Codex's native prompt).
  {
    const dir = freshTemp("t11-off");
    fs.writeFileSync(path.join(dir, ".press-1-off-codex"), "");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { USERPROFILE: dir });
    const code = await h.waitExit(5000);
    check("T11 off-flag → exit 0", code === 0, `code=${code}`);
    check("T11 off-flag → no stdout (native prompt)", h.stdout().trim() === "");
    check("T11 off-flag → no pending written", pendingFiles(dir).length === 0,
      `pending=${pendingFiles(dir).length}`);
  }

  // T12: native-control is opt-in and only applies to the
  // panel: the hook writes a popup row, then exits empty so Codex's own prompt
  // can render in parallel.
  {
    const dir = freshTemp("t12-native");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "1",
      PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS: "123456",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T12 native-control pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T12 native-control panel only", j.host.type === "vscode-extension" && j.native_control === true);
      check("T12 native-control has no decision_file", !("decision_file" in j));
      const window = j.wait_until - j.timestamp;
      check("T12 native-control wait window honored (+sound budget)", window >= 126000 && window <= 129000, `window=${window}`);
      const code = await h.waitExit(5000);
      check("T12 native-control hook exits immediately", code === 0, `code=${code}`);
      check("T12 native-control no stdout", h.stdout().trim() === "");
      check("T12 native-control pending left for AHK", fs.existsSync(pf));
    }
  }

  // T13: tool_input_full carries the full, newline-preserving command for the
  // popup expand affordance. The short field collapses whitespace + caps at 200;
  // the full field keeps newlines and is capped wider (2000).
  {
    const dir = freshTemp("t13");
    const payload = { ...PAYLOAD, tool_input: { command: "echo first\necho second\n" + "x".repeat(250) } };
    const h = runHookAsync(payload, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T13 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T13 tool_input_full preserves newlines", /\n/.test(j.tool_input_full || ""), `got=${JSON.stringify(j.tool_input_full)}`);
      check("T13 tool_input_full not truncated at 200", (j.tool_input_full || "").length > 200, `len=${(j.tool_input_full || "").length}`);
      check("T13 tool_input_short one-line + capped 200", !/\n/.test(j.tool_input_short || "") && (j.tool_input_short || "").length === 200, `len=${(j.tool_input_short || "").length}`);
      writeDecision(j.decision_file, "allow"); await h.waitExit(5000);
    }
  }

  // ---- Hybrid two-phase (Stage 2d). runHookAsync pins NATIVE_CONTROL="0"
  // (decision-only) for the legacy tests above; hybrid cases override with ""
  // (= unset: neither "0" nor "1" → the default hybrid mode). ----

  // T14: hybrid timeout → the pending is REWRITTEN in place (same id,
  // native_control:true, decision_file removed, wait_until extended to the
  // phase-2 TTL), hook exits 0 with empty stdout, orphan decision file removed.
  {
    const dir = freshTemp("t14-hybrid");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "1200",
      PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS: "300000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T14 pending written", !!pf);
    if (pf) {
      const j1 = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T14 phase 1 = decision channel", typeof j1.decision_file === "string" && !j1.native_control);
      const w1 = j1.wait_until - j1.timestamp;
      check("T14 phase-1 wait_until covers sound budget", w1 >= 1200 + 4000 - 200 && w1 <= 1200 + 4000 + 500, `w=${w1}`);
      const code = await h.waitExit(9000);
      check("T14 hook exited on its own", code !== "timeout");
      check("T14 no stdout on handoff", h.stdout().trim() === "");
      check("T14 pending survived the handoff", fs.existsSync(pf));
      if (fs.existsSync(pf)) {
        const j2 = JSON.parse(fs.readFileSync(pf, "utf8"));
        check("T14 rewritten to native_control", j2.native_control === true);
        check("T14 decision_file removed", !("decision_file" in j2));
        check("T14 same id (row morphs in place)", j2.id === j1.id);
        check("T14 wait_until extended to phase-2 TTL", j2.wait_until > j1.wait_until && j2.wait_until - Date.now() > 250000, `wu=${j2.wait_until - Date.now()}`);
        check("T14 orphan decision file removed", !fs.existsSync(j1.decision_file));
      }
    }
  }

  // T15: hybrid + a decision word before the timeout → normal answer path,
  // pending deleted, NO rewrite.
  {
    const dir = freshTemp("t15-hybrid");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "8000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T15 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T15 hybrid decision answered", dec && dec.behavior === "allow");
      check("T15 pending deleted (no rewrite)", !fs.existsSync(pf));
    }
  }

  // T16: hybrid + pass (popup Esc) → pending deleted, empty stdout, NO phase 2
  // (Esc is the explicit "hand over to the native prompt, drop the remote").
  {
    const dir = freshTemp("t16-hybrid");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "8000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "pass");
      await h.waitExit(5000);
      check("T16 pass → empty stdout", h.stdout().trim() === "");
      check("T16 pass → pending deleted, no rewrite", !fs.existsSync(pf));
    }
  }

  // T17: hybrid + teardown (pending deleted externally mid-window) → early-exit
  // WITHOUT resurrecting the file as a phase-2 row.
  {
    const dir = freshTemp("t17-hybrid");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "8000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) {
      fs.unlinkSync(pf);
      const r = await h.waitExit(5000);
      check("T17 early-exit on teardown", r !== "timeout");
      check("T17 no stdout", h.stdout().trim() === "");
      await sleep(300);
      check("T17 pending NOT resurrected", pendingFiles(dir).length === 0, `left=${pendingFiles(dir).length}`);
    }
  }

  // T18: conhost never gets phase 2 — hybrid config behaves as decision-only
  // there (timeout deletes the pending; window = DECISION_WAIT_MS, not hybrid).
  {
    const dir = freshTemp("t18-conhost");
    const h = runHookAsync(PAYLOAD, hostEnv("conhost"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_WAIT_MS: "1200",
      PRESS1_CODEX_HYBRID_WAIT_MS: "50000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T18 conhost pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const w = j.wait_until - j.timestamp;
      check("T18 conhost uses the decision window", w >= 1200 + 4000 - 200 && w <= 1200 + 4000 + 500, `w=${w}`);
      const code = await h.waitExit(9000);
      check("T18 conhost hook exited", code !== "timeout");
      check("T18 conhost timeout deletes pending (no rewrite)", !fs.existsSync(pf));
    }
  }

  // T19: the native-control opt-in (=1) on a NON-panel host degrades to hybrid —
  // phase 1 (decision channel) must exist, not the instant native exit.
  {
    const dir = freshTemp("t19-optin-vsterm");
    const h = runHookAsync(PAYLOAD, hostEnv("vsterm"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "1",
      PRESS1_CODEX_HYBRID_WAIT_MS: "8000",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T19 vsterm pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T19 opt-in on vsterm = hybrid phase 1 (decision channel present)",
        typeof j.decision_file === "string" && !j.native_control);
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
    }
  }

  // T20: window defaults/clamps of the two-window model. Hybrid default 15 s;
  // hybrid env is clamped at 60 s like the decision window.
  {
    const dir = freshTemp("t20-windows");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { PRESS1_CODEX_NATIVE_CONTROL: "" });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const w = j.wait_until - j.timestamp;
      check("T20 hybrid default window 15s+sound", w >= 18500 && w <= 19500, `w=${w}`);
      fs.unlinkSync(pf);  // early-exit — don't sit out the window
      await h.waitExit(5000);
    }
    const dir2 = freshTemp("t20-clamp");
    const h2 = runHookAsync(PAYLOAD, hostEnv("panel"), dir2, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "99999",
    });
    const pf2 = await waitFor(() => pendingFiles(dir2)[0], 8000);
    if (pf2) {
      const j = JSON.parse(fs.readFileSync(pf2, "utf8"));
      const w = j.wait_until - j.timestamp;
      check("T20 hybrid env clamped to 60s+sound", w >= 63500 && w <= 64500, `w=${w}`);
      fs.unlinkSync(pf2);
      await h2.waitExit(5000);
    }
  }

  // T21: a word landing right at the deadline is answered, never lost to the
  // phase-2 handoff (normal-tick pickup or the final re-read — either way the
  // decision must win over the rewrite).
  {
    const dir = freshTemp("t21-race");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, {
      PRESS1_CODEX_NATIVE_CONTROL: "",
      PRESS1_CODEX_HYBRID_WAIT_MS: "1500",
    });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      await sleep(1350);  // ~deadline minus a tick
      writeDecision(j.decision_file, "deny");
      await h.waitExit(6000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      const rewritten = fs.existsSync(pf) && JSON.parse(fs.readFileSync(pf, "utf8")).native_control === true;
      check("T21 near-deadline word answered OR cleanly handed over (never both)",
        (dec && dec.behavior === "deny" && !fs.existsSync(pf)) || (!dec && rewritten),
        `dec=${JSON.stringify(dec)} rewritten=${rewritten}`);
    }
  }

  // T22: same-session cleanup — a new prompt deletes previous pendings of the
  // SAME codex session (interrupt/Esc in the TUI fires no teardown event, so a
  // dead pending lingers until TTL; retries stacked identical cards — live smoke
  // 2026-07-02). Other codex sessions and claude-agent pendings are untouched.
  {
    const dir = freshTemp("t22-session-cleanup");
    const pd = path.join(dir, "press-1", "pending");
    fs.mkdirSync(pd, { recursive: true });
    const mk = (name, obj) => fs.writeFileSync(path.join(pd, name), JSON.stringify(obj), "utf8");
    mk("100-old.json", { agent: "codex", session_id: "cdx-sess-1", native_control: true });
    mk("101-other.json", { agent: "codex", session_id: "cdx-sess-OTHER" });
    mk("102-claude.json", { agent: "claude", session_id: "cdx-sess-1" });
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const newPf = await waitFor(
      () => pendingFiles(dir).find((p) => !/100-old|101-other|102-claude/.test(p)), 8000);
    check("T22 new pending written", !!newPf);
    const names = pendingFiles(dir).map((p) => path.basename(p));
    check("T22 same-session codex pending deleted", !names.includes("100-old.json"), names.join(","));
    check("T22 other-session codex pending survives", names.includes("101-other.json"));
    check("T22 claude pending with same session_id survives", names.includes("102-claude.json"));
    if (newPf) {
      try {
        const j = JSON.parse(fs.readFileSync(newPf, "utf8"));
        writeDecision(j.decision_file, "deny"); // release the blocked hook
      } catch {}
    }
    await h.waitExit(6000);
  }

  // T23: proxy-channel mute — PRESS1_PROXY set (non-empty) → hook exits 0 empty
  // and writes no pending (the codex-mitm wrapper owns that panel's approvals;
  // the hook self-mutes to avoid a duplicate card). Mirrors the off-flag path.
  {
    const dir = freshTemp("t23-proxy");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { PRESS1_PROXY: "1" });
    const code = await h.waitExit(5000);
    check("T23 PRESS1_PROXY=1 → exit 0", code === 0, `code=${code}`);
    check("T23 PRESS1_PROXY=1 → no stdout (proxy owns the panel)", h.stdout().trim() === "");
    check("T23 PRESS1_PROXY=1 → no pending written", pendingFiles(dir).length === 0,
      `pending=${pendingFiles(dir).length}`);
  }

  // T24: PRESS1_PROXY set to an EMPTY string is NOT a live proxy → hook behaves
  // normally (writes a pending). Convention: the guard is JS truthiness
  // (`if (process.env.PRESS1_PROXY)`), so "" (falsy) reads as absent — same result
  // whether the OS drops an empty env var or passes it through as "".
  {
    const dir = freshTemp("t24-proxy-empty");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir, { PRESS1_PROXY: "" });
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T24 PRESS1_PROXY='' → not muted, pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
    }
  }

  // (PRESS1_PROXY unset → normal behavior is already exercised by every other
  // test above — runHookAsync never sets it — so it is not duplicated here.)

  // ---- Codex reviewer routing. Exact same-turn auto_review passes through on
  // every standard hook surface before pending/sound. Proxy remains excluded;
  // every uncertainty stays on the current popup route. ----

  // T25: exact top-level turn_context + same payload.turn_id + exact auto_review
  // needs no surface/originator marker: immediate empty pass-through, no pending.
  // The diagnostic status is fixed-schema and contains no request secrets.
  {
    const dir = freshTemp("t25-desktop-auto-exact");
    const turnId = "SECRET-TURN-25";
    const file = transcriptPath(dir, "SECRET-PATH-25.jsonl");
    writeJsonl(file, [
      { type: "session_meta", payload: { id: "not-the-reviewer-record" } },
      turnContext(turnId, "auto_review"),
    ]);
    const payload = reviewerPayload(file, turnId, {
      cwd: "D:/SECRET-CWD-25",
      tool_input: { command: "echo SECRET-COMMAND-25" },
    });
    const { status } = await runReviewerCase("T25 exact auto_review without originator", payload,
      hostEnv("conhost"), dir, "auto_pass",
      { outcome: "auto_pass", reason: "exact_auto_review" });
    check("T25 exact auto_review leaves no pending", pendingFiles(dir).length === 0);
    if (status) {
      const raw = JSON.stringify(status);
      const secrets = ["SECRET-COMMAND-25", "SECRET-CWD-25", "SECRET-PATH-25", turnId,
        PAYLOAD.session_id];
      check("T25 status contains no command/cwd/path/turn/session secrets",
        secrets.every((secret) => !raw.includes(secret)), raw);
      check("T25 status scan metrics are bounded",
        status.attempts >= 1 && status.scanned_bytes > 0
          && status.scanned_bytes <= status.file_bytes && status.tail_truncated === false,
        JSON.stringify(status));
    }

    // One thread/turn may contain concurrent approval hooks without a unique
    // approval id. Force the first exact-auto payload into the popup via the
    // opt-out, then remove the opt-out and run the same payload again: the
    // second hook must not delete or release the first hook's live pending.
    const concurrentFile = transcriptPath(dir, "concurrent.jsonl");
    const concurrentTurn = "turn-concurrent-same";
    writeJsonl(concurrentFile, [turnContext(concurrentTurn, "auto_review")]);
    const concurrentSession = "concurrent-session";
    const concurrentOptOut = path.join(dir, ".press-1-off-codex-desktop-auto-review");
    fs.writeFileSync(concurrentOptOut, "", "utf8");
    const manualHook = runHookAsync(
      reviewerPayload(concurrentFile, concurrentTurn, { session_id: concurrentSession }),
      hostEnv("conhost"), dir);
    const manualPending = await waitFor(() => pendingFiles(dir)[0], 5000);
    check("T25 concurrent same-turn manual pending written", !!manualPending);
    fs.unlinkSync(concurrentOptOut);

    const autoHook = runHookAsync(
      reviewerPayload(concurrentFile, concurrentTurn, { session_id: concurrentSession }),
      hostEnv("conhost"), dir);
    const autoCode = await autoHook.waitExit(5000);
    check("T25 concurrent same-turn exact auto exits 0", autoCode === 0, `code=${autoCode}`);
    check("T25 concurrent same-turn exact auto stdout empty", autoHook.stdout().trim() === "");
    const manualSurvived = !!manualPending && fs.existsSync(manualPending);
    check("T25 concurrent same-turn exact auto preserves live pending", manualSurvived);

    if (manualSurvived) {
      const entry = JSON.parse(fs.readFileSync(manualPending, "utf8"));
      writeDecision(entry.decision_file, "allow");
    } else {
      try { manualHook.child.kill(); } catch {}
    }
    const manualCode = await manualHook.waitExit(5000);
    check("T25 concurrent same-turn manual hook exits 0", manualCode === 0, `code=${manualCode}`);
    let manualDecision = null;
    try { manualDecision = JSON.parse(manualHook.stdout()).hookSpecificOutput.decision; } catch {}
    check("T25 concurrent same-turn manual approval remains answerable",
      manualDecision && manualDecision.behavior === "allow", manualHook.stdout().slice(0, 120));

  }

  // T26: the dedicated opt-out flag restores today's popup behavior and does
  // not emit reviewer diagnostics (the probe is disabled, not attempted).
  // Missing USERPROFILE and any lookup error are also opt-out ambiguity: only a
  // definitely absent flag may enable the version-sensitive transcript probe.
  {
    const dir = freshTemp("t26-auto-review-opt-out");
    fs.writeFileSync(path.join(dir, ".press-1-off-codex-desktop-auto-review"), "");
    const turnId = "turn-opt-out";
    const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, "auto_review")]);
    const noReadProbe = reviewerFsProbeEnv(dir, file);
    await runReviewerCase("T26 reviewer opt-out on a non-Desktop surface",
      reviewerPayload(file, turnId), hostEnv("panel"), dir, "popup", null, noReadProbe);
    check("T26 opt-out performs zero transcript reads",
      !fs.existsSync(noReadProbe.probeLog));

    const dir2 = freshTemp("t26-auto-review-profile-missing");
    const codexHome2 = path.join(dir2, "custom-codex-home");
    const turnId2 = "turn-profile-missing";
    const file2 = writeJsonl(transcriptPath(dir2, "rollout.jsonl", codexHome2),
      [turnContext(turnId2, "auto_review")]);
    await runReviewerCase("T26 missing USERPROFILE fails safe to popup",
      reviewerPayload(file2, turnId2), hostEnv("panel"), dir2, "popup", null,
      {
        USERPROFILE: "",
        CODEX_HOME: codexHome2,
        PRESS1_CODEX_RULES_PATH: path.join(dir2, "rules", "default.rules"),
      });

    const dir3 = freshTemp("t26-auto-review-flag-error");
    const turnId3 = "turn-flag-error";
    const file3 = writeJsonl(transcriptPath(dir3), [turnContext(turnId3, "auto_review")]);
    const flag3 = path.join(dir3, ".press-1-off-codex-desktop-auto-review");
    await runReviewerCase("T26 opt-out lookup error fails safe to popup",
      reviewerPayload(file3, turnId3), hostEnv("panel"), dir3, "popup", null,
      autoReviewFlagErrorEnv(dir3, flag3));

    const dir4 = freshTemp("t26-auto-review-second-check-error");
    const turnId4 = "turn-second-check-error";
    const file4 = writeJsonl(transcriptPath(dir4), [turnContext(turnId4, "auto_review")]);
    const flag4 = path.join(dir4, ".press-1-off-codex-desktop-auto-review");
    await runReviewerCase("T26 opt-out second-check error fails safe to popup",
      reviewerPayload(file4, turnId4), hostEnv("panel"), dir4, "popup", null,
      autoReviewFlagSecondCheckErrorEnv(dir4, flag4));
  }

  // T27: only the exact auto_review enum passes. User, guardian, unknown and
  // null reviewers all fail safe to popup, with user distinguished in status.
  {
    const cases = [
      ["user", "user", "reviewer_user"],
      ["guardian", "guardian_subagent", "reviewer_other"],
      ["unknown", "future_reviewer", "reviewer_other"],
      ["null", null, "reviewer_other"],
    ];
    for (const [label, reviewer, reason] of cases) {
      const dir = freshTemp(`t27-reviewer-${label}`);
      const turnId = `turn-reviewer-${label}`;
      const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, reviewer)]);
      await runReviewerCase(`T27 reviewer=${label}`, reviewerPayload(file, turnId),
        hostEnv("vsterm"), dir, "popup", { outcome: "popup", reason });
    }
  }

  // T28: exact auto_review applies across every standard hook surface — host
  // classification does not change reviewer routing; PRESS1_PROXY is tested
  // separately as a hard exclusion. Native/resumed Windows threads (Desktop)
  // publish transcript_path as an extended local drive path (\\?\X:\...), so
  // the last case exercises that production shape.
  {
    const cases = [
      ["CLI/conhost", hostEnv("conhost")],
      ["CLI/Windows Terminal", hostEnv("wt")],
      ["VS Code terminal", hostEnv("vsterm")],
      ["VS Code hook panel", hostEnv("panel")],
      ["Desktop extended local path", hostEnv("conhost"),
        (file) => "\\\\?\\" + path.resolve(file)],
    ];
    for (let i = 0; i < cases.length; i++) {
      const [label, env, shapePath] = cases[i];
      const dir = freshTemp(`t28-surface-${i}`);
      const turnId = `turn-surface-${i}`;
      const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, "auto_review")]);
      const payloadPath = shapePath ? shapePath(file) : file;
      await runReviewerCase(`T28 surface=${label}`, reviewerPayload(payloadPath, turnId),
        env, dir, "auto_pass", { outcome: "auto_pass", reason: "exact_auto_review" });
    }
  }

  // T29: record matching is exact at the top level and on payload.turn_id.
  // Near-miss type/nesting/turn records are ignored rather than guessed.
  {
    const cases = [
      ["wrong-type", (turnId) => ({ type: "Turn_Context", payload: {
        turn_id: turnId, approvals_reviewer: "auto_review" } })],
      ["nested-type", (turnId) => ({ type: "event_msg", payload: {
        type: "turn_context", payload: { turn_id: turnId, approvals_reviewer: "auto_review" } } })],
      ["mismatched-turn", () => turnContext("different-turn", "auto_review")],
    ];
    for (const [label, makeRecord] of cases) {
      const dir = freshTemp(`t29-match-${label}`);
      const turnId = `turn-match-${label}`;
      const file = writeJsonl(transcriptPath(dir), [makeRecord(turnId)]);
      await runReviewerCase(`T29 ${label}`, reviewerPayload(file, turnId), hostEnv("conhost"), dir,
        "popup", { outcome: "popup", reason: "turn_not_found" });
    }
  }

  // T30: missing hook inputs are not inferred. A named-but-missing transcript is
  // a read failure; absent/null turn/path values are input_missing.
  {
    const cases = [
      ["path-absent", (file) => reviewerPayload(file, "turn-input", { transcript_path: undefined })],
      ["path-null", (file) => reviewerPayload(file, "turn-input", { transcript_path: null })],
      ["turn-absent", (file) => reviewerPayload(file, undefined, { turn_id: undefined })],
      ["turn-null", (file) => reviewerPayload(file, null, { turn_id: null })],
    ];
    for (const [label, makePayload] of cases) {
      const dir = freshTemp(`t30-input-${label}`);
      const file = writeJsonl(transcriptPath(dir), [turnContext("turn-input", "auto_review")]);
      await runReviewerCase(`T30 ${label}`, makePayload(file), hostEnv("conhost"), dir, "popup",
        { outcome: "popup", reason: "input_missing" });
    }
    const dir = freshTemp("t30-input-file-missing");
    const missing = transcriptPath(dir, "does-not-exist.jsonl");
    await runReviewerCase("T30 transcript file missing", reviewerPayload(missing, "turn-input"),
      hostEnv("conhost"), dir, "popup", { outcome: "popup", reason: "read_failed" });
  }

  // T31: transcript reads are confined to a real regular .jsonl under the real
  // Codex sessions root. Outside, relative, remote/arbitrary device namespaces,
  // wrong-extension and directory inputs all fail safe before content can
  // influence routing. T28 separately proves that the narrow \\?\X:\ local-drive
  // form used by Native Codex is accepted only after normal containment checks.
  {
    const cases = [];
    {
      const dir = freshTemp("t31-path-outside");
      const outside = path.join(dir, "outside.jsonl");
      writeJsonl(outside, [turnContext("turn-path", "auto_review")]);
      cases.push(["outside-root", dir, outside]);
    }
    {
      const dir = freshTemp("t31-path-relative");
      cases.push(["relative", dir, "rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-unc");
      cases.push(["UNC", dir, "\\\\server\\share\\rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-win32-device");
      cases.push(["Win32 device", dir, "\\\\.\\C:\\rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-namespaced-unc");
      cases.push(["namespaced UNC", dir, "\\\\?\\UNC\\server\\share\\rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-globalroot");
      cases.push(["GLOBALROOT device", dir,
        "\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy1\\rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-volume-guid");
      cases.push(["volume GUID", dir,
        "\\\\?\\Volume{00000000-0000-0000-0000-000000000000}\\rollout.jsonl"]);
    }
    {
      const dir = freshTemp("t31-path-extended-outside");
      const outside = path.join(dir, "outside-extended.jsonl");
      writeJsonl(outside, [turnContext("turn-path", "auto_review")]);
      cases.push(["extended local outside-root", dir, "\\\\?\\" + path.resolve(outside)]);
    }
    {
      const dir = freshTemp("t31-path-extended-drive-relative");
      const drive = path.parse(path.resolve(dir)).root.slice(0, 2);
      cases.push(["extended drive-relative", dir,
        `\\\\?\\${drive}relative\\rollout.jsonl`]);
    }
    {
      const dir = freshTemp("t31-path-extended-mixed-separator");
      const file = writeJsonl(transcriptPath(dir), [turnContext("turn-path", "auto_review")]);
      const mixed = ("\\\\?\\" + path.resolve(file)).replace(/\\([^\\]+)$/, "/$1");
      cases.push(["extended mixed separator", dir, mixed]);
    }
    {
      const dir = freshTemp("t31-path-extended-ads");
      const file = writeJsonl(transcriptPath(dir), [turnContext("turn-path", "auto_review")]);
      cases.push(["extended alternate data stream", dir,
        ("\\\\?\\" + path.resolve(file)).replace(/\.jsonl$/i, ":reviewer.jsonl")]);
    }
    {
      const dir = freshTemp("t31-path-extended-newline");
      const file = writeJsonl(transcriptPath(dir), [turnContext("turn-path", "auto_review")]);
      cases.push(["extended trailing newline", dir, "\\\\?\\" + path.resolve(file) + "\n"]);
    }
    {
      const dir = freshTemp("t31-path-extension");
      const wrongExt = transcriptPath(dir, "rollout.txt");
      writeJsonl(wrongExt, [turnContext("turn-path", "auto_review")]);
      cases.push(["wrong-extension", dir, wrongExt]);
    }
    {
      const dir = freshTemp("t31-path-directory");
      const directory = transcriptPath(dir, "directory.jsonl");
      fs.mkdirSync(directory);
      cases.push(["not-regular-file", dir, directory]);
    }
    {
      const dir = freshTemp("t31-path-junction-escape");
      const inside = path.dirname(transcriptPath(dir));
      const outside = path.join(dir, "outside-junction-target");
      fs.mkdirSync(outside);
      writeJsonl(path.join(outside, "rollout.jsonl"), [turnContext("turn-path", "auto_review")]);
      const junction = path.join(inside, "escape");
      fs.symlinkSync(outside, junction, "junction");
      cases.push(["junction-escape", dir, path.join(junction, "rollout.jsonl")]);
      cases.push(["extended local junction-escape", dir,
        "\\\\?\\" + path.resolve(path.join(junction, "rollout.jsonl"))]);
    }
    for (const [label, dir, file] of cases) {
      await runReviewerCase(`T31 ${label}`, reviewerPayload(file, "turn-path"), hostEnv("conhost"), dir,
        "popup", { outcome: "popup", reason: "path_rejected" });
    }
  }

  // T32: CODEX_HOME, when present, owns the allowed sessions root. A transcript
  // there can pass; USERPROFILE/.codex is outside the selected root and cannot.
  // Native/Windows may use the same extended local-drive spelling for both the
  // configured root and transcript, so normalization must be symmetric.
  {
    const dir = freshTemp("t32-codex-home-valid");
    const codexHome = path.join(dir, "custom-codex-home");
    const turnId = "turn-codex-home";
    const file = writeJsonl(transcriptPath(dir, "custom.jsonl", codexHome),
      [turnContext(turnId, "auto_review")]);
    await runReviewerCase("T32 CODEX_HOME sessions accepted", reviewerPayload(file, turnId),
      hostEnv("conhost"), dir, "auto_pass", { outcome: "auto_pass", reason: "exact_auto_review" },
      { CODEX_HOME: codexHome });

    const dir2 = freshTemp("t32-codex-home-reject-default");
    const codexHome2 = path.join(dir2, "custom-codex-home");
    fs.mkdirSync(path.join(codexHome2, "sessions"), { recursive: true });
    const file2 = writeJsonl(transcriptPath(dir2), [turnContext(turnId, "auto_review")]);
    await runReviewerCase("T32 CODEX_HOME rejects USERPROFILE sessions",
      reviewerPayload(file2, turnId), hostEnv("conhost"), dir2, "popup",
      { outcome: "popup", reason: "path_rejected" }, { CODEX_HOME: codexHome2 });

    const dir3 = freshTemp("t32-codex-home-extended-local");
    const codexHome3 = path.join(dir3, "custom-codex-home");
    const turnId3 = "turn-codex-home-extended";
    const file3 = writeJsonl(transcriptPath(dir3, "extended.jsonl", codexHome3),
      [turnContext(turnId3, "auto_review")]);
    await runReviewerCase("T32 extended local CODEX_HOME and transcript accepted",
      reviewerPayload("\\\\?\\" + path.resolve(file3), turnId3), hostEnv("conhost"), dir3,
      "auto_pass", { outcome: "auto_pass", reason: "exact_auto_review" },
      { CODEX_HOME: "\\\\?\\" + path.resolve(codexHome3) });
  }

  // T33: corrupt/truncated JSONL and structurally invalid exact-turn candidates
  // never auto-pass, even if another line tries to provide an auto match.
  {
    const cases = [
      ["malformed-only", (turnId) => ["{ not json"]],
      ["malformed-plus-match", (turnId) => ["{ not json", turnContext(turnId, "auto_review")]],
      ["truncated-match", (turnId) => [
        `{"type":"turn_context","payload":{"turn_id":"${turnId}","approvals_reviewer":"auto_review"}`]],
      ["payload-not-object", (turnId) => [{ type: "turn_context", payload: [turnId, "auto_review"] }]],
      ["reviewer-missing", (turnId) => [{ type: "turn_context", payload: { turn_id: turnId } }]],
    ];
    for (const [label, makeRecords] of cases) {
      const dir = freshTemp(`t33-record-${label}`);
      const turnId = `turn-record-${label}`;
      const file = writeJsonl(transcriptPath(dir), makeRecords(turnId));
      await runReviewerCase(`T33 ${label}`, reviewerPayload(file, turnId), hostEnv("conhost"), dir,
        "popup", { outcome: "popup", reason: "record_invalid" });
    }
  }

  // T34: two exact-turn reviewer records that disagree are a conflict, never a
  // last-line-wins auto-pass. Duplicate identical auto records remain unambiguous.
  {
    for (const [label, other] of [["user", "user"], ["guardian", "guardian_subagent"]]) {
      const dir = freshTemp(`t34-conflict-${label}`);
      const turnId = `turn-conflict-${label}`;
      const file = writeJsonl(transcriptPath(dir), [
        turnContext(turnId, "auto_review"), turnContext(turnId, other),
      ]);
      await runReviewerCase(`T34 auto/${label} conflict`, reviewerPayload(file, turnId),
        hostEnv("conhost"), dir, "popup", { outcome: "popup", reason: "reviewer_conflict" });
    }
    const dir = freshTemp("t34-duplicate-auto");
    const turnId = "turn-duplicate-auto";
    const file = writeJsonl(transcriptPath(dir), [
      turnContext(turnId, "auto_review"), turnContext(turnId, "auto_review"),
    ]);
    await runReviewerCase("T34 duplicate identical auto_review", reviewerPayload(file, turnId),
      hostEnv("conhost"), dir, "auto_pass", { outcome: "auto_pass", reason: "exact_auto_review" });
  }

  // T35: the 4 MiB cap belongs to turn_context candidates, not unrelated valid
  // tool/image records. Codex legitimately embeds multi-megabyte tool outputs in
  // rollout JSONL; those records must not poison a later exact reviewer match.
  // Malformed oversized records and oversized same-turn candidates remain
  // fail-safe because neither can be ruled out as ambiguous reviewer evidence.
  {
    const dir = freshTemp("t35-record-over-4mib");
    const turnId = "turn-over-4mib";
    const file = transcriptPath(dir);
    writeJsonl(file, [turnContext(turnId, "auto_review", { padding: "x".repeat(4 * 1024 * 1024) })]);
    await runReviewerCase("T35 candidate line over 4 MiB", reviewerPayload(file, turnId),
      hostEnv("conhost"), dir, "popup", { outcome: "popup", reason: "record_invalid" });

    const dir2 = freshTemp("t35-unrelated-oversized-records");
    const turnId2 = "turn-after-large-tool-output";
    const file2 = transcriptPath(dir2);
    writeJsonl(file2, [
      {
        type: "response_item",
        payload: { type: "custom_tool_call_output", output: "x".repeat(7 * 1024 * 1024) },
      },
      turnContext(turnId2, "auto_review"),
      {
        type: "response_item",
        payload: { type: "function_call_output", output: "y".repeat(5 * 1024 * 1024) },
      },
    ]);
    await runReviewerCase("T35 valid oversized non-turn records stay irrelevant",
      reviewerPayload(file2, turnId2), hostEnv("conhost"), dir2, "auto_pass",
      { outcome: "auto_pass", reason: "exact_auto_review" });

    const dir3 = freshTemp("t35-malformed-oversized-record");
    const turnId3 = "turn-after-malformed-large-record";
    const file3 = transcriptPath(dir3);
    const malformed = '{"type":"response_item","payload":{"type":"custom_tool_call_output",'
      + '"output":"' + "z".repeat(5 * 1024 * 1024);
    writeJsonl(file3, [malformed, turnContext(turnId3, "auto_review")]);
    await runReviewerCase("T35 malformed oversized record stays fail-safe",
      reviewerPayload(file3, turnId3), hostEnv("conhost"), dir3, "popup",
      { outcome: "popup", reason: "record_invalid" });

    const dir4 = freshTemp("t35-oversized-conflicting-candidate");
    const turnId4 = "turn-large-conflict";
    const file4 = transcriptPath(dir4);
    writeJsonl(file4, [
      turnContext(turnId4, "user", { padding: "q".repeat(5 * 1024 * 1024) }),
      turnContext(turnId4, "auto_review"),
    ]);
    await runReviewerCase("T35 oversized conflicting candidate stays fail-safe",
      reviewerPayload(file4, turnId4), hostEnv("conhost"), dir4, "popup",
      { outcome: "popup", reason: "record_invalid" });

    const dir5 = freshTemp("t35-invalid-utf8-oversized-candidate");
    const turnId5 = "turn-invalid-utf8-conflict";
    const file5 = transcriptPath(dir5);
    const corruptUserCandidate = Buffer.concat([
      Buffer.from('{"type":"turn_conte', "utf8"),
      Buffer.from([0xc3, 0x28]),  // invalid UTF-8; permissive decoding would insert U+FFFD
      Buffer.from(`xt","payload":{"turn_id":"${turnId5}",`
        + '"approvals_reviewer":"user","padding":"', "utf8"),
      Buffer.alloc(5 * 1024 * 1024, 0x78),
      Buffer.from('"}}\n' + JSON.stringify(turnContext(turnId5, "auto_review")) + "\n", "utf8"),
    ]);
    fs.writeFileSync(file5, corruptUserCandidate);
    await runReviewerCase("T35 invalid UTF-8 oversized candidate stays fail-safe",
      reviewerPayload(file5, turnId5), hostEnv("conhost"), dir5, "popup",
      { outcome: "popup", reason: "record_invalid" });
  }

  // T36: only the newest 32 MiB are scanned. A real exact match older than that
  // bounded tail cannot authorize; the partial first tail line is ignored safely.
  {
    const dir = freshTemp("t36-tail-over-32mib");
    const turnId = "turn-before-tail";
    const file = transcriptPath(dir);
    const exact = JSON.stringify(turnContext(turnId, "auto_review")) + "\n";
    const filler = JSON.stringify(turnContext("other-turn", "user", {
      padding: "x".repeat(1024 * 1024),
    })) + "\n";
    fs.writeFileSync(file, exact + filler.repeat(33), "utf8");
    const { status } = await runReviewerCase("T36 match outside newest 32 MiB",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "popup",
      { outcome: "popup", reason: "turn_not_found" });
    if (status) {
      check("T36 status marks bounded tail truncation",
        status.tail_truncated === true && status.file_bytes > 32 * 1024 * 1024
          && status.scanned_bytes <= 32 * 1024 * 1024,
        JSON.stringify(status));
    }
  }

  // T37: global off and a live proxy take precedence over reviewer detection.
  // Feed each route a valid exact-auto transcript: neither may probe it, write a
  // status, or create a pending. The proxy sees only later real manual requests.
  {
    const dir = freshTemp("t37-global-off-precedence");
    fs.writeFileSync(path.join(dir, ".press-1-off-codex"), "");
    const turnId = "turn-global-off-precedence";
    const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, "auto_review")]);
    const offProbe = reviewerFsProbeEnv(dir, file);
    await runReviewerCase("T37 global off precedes reviewer probe",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "auto_pass", null, offProbe);
    check("T37 global off performs zero transcript reads", !fs.existsSync(offProbe.probeLog));

    const dir2 = freshTemp("t37-proxy-precedence");
    const turnId2 = "turn-proxy-precedence";
    const file2 = writeJsonl(transcriptPath(dir2), [turnContext(turnId2, "auto_review")]);
    const proxyProbe = reviewerFsProbeEnv(dir2, file2);
    await runReviewerCase("T37 PRESS1_PROXY precedes reviewer probe",
      reviewerPayload(file2, turnId2), hostEnv("panel"), dir2, "auto_pass", null,
      { ...proxyProbe, PRESS1_PROXY: "1" });
    check("T37 PRESS1_PROXY performs zero transcript reads",
      !fs.existsSync(proxyProbe.probeLog));
  }

  // T38: diagnostic persistence is best-effort. Making the status destination a
  // directory forces its atomic rename/write to fail, but must not change either
  // the exact-auto pass route or the fail-safe user popup route.
  {
    const dir = freshTemp("t38-status-unwritable-auto");
    fs.mkdirSync(reviewerStatusPath(dir), { recursive: true });
    const turnId = "turn-status-unwritable-auto";
    const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, "auto_review")]);
    await runReviewerCase("T38 unwritable status preserves auto-pass",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "auto_pass", null);

    const dir2 = freshTemp("t38-status-unwritable-user");
    fs.mkdirSync(reviewerStatusPath(dir2), { recursive: true });
    const turnId2 = "turn-status-unwritable-user";
    const file2 = writeJsonl(transcriptPath(dir2), [turnContext(turnId2, "user")]);
    await runReviewerCase("T38 unwritable status preserves popup",
      reviewerPayload(file2, turnId2), hostEnv("conhost"), dir2, "popup", null);
  }

  // T39: a current exact match near EOF of a >32 MiB rollout is inside the
  // authorized tail and can pass. The preload also enforces the implementation
  // contract that no individual synchronous read asks the OS for more than
  // 256 KiB, keeping deadline checks meaningful during a full tail scan.
  {
    const dir = freshTemp("t39-match-inside-bounded-tail");
    const turnId = "turn-inside-tail";
    const file = transcriptPath(dir);
    const exact = JSON.stringify(turnContext(turnId, "auto_review")) + "\n";
    fs.writeFileSync(file, "x".repeat(33 * 1024 * 1024) + "\n" + exact, "utf8");
    const probe = reviewerFsProbeEnv(dir, file);
    const { status } = await runReviewerCase("T39 match inside newest 32 MiB",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "auto_pass",
      { outcome: "auto_pass", reason: "exact_auto_review" }, probe);
    const readProbe = JSON.parse(fs.readFileSync(probe.probeLog, "utf8"));
    check("T39 transcript reads are chunked to at most 256 KiB",
      readProbe.calls > 1 && readProbe.maxRead <= 256 * 1024, JSON.stringify(readProbe));
    if (status) {
      check("T39 positive match came from a bounded truncated tail",
        status.tail_truncated === true && status.file_bytes > 32 * 1024 * 1024
          && status.scanned_bytes === 32 * 1024 * 1024,
        JSON.stringify(status));
    }
  }

  // T40: growth during the first snapshot forces a retry. The second stable
  // snapshot still proves the same exact auto_review, and diagnostics preserve
  // both the retry count and the fact that the rollout grew.
  {
    const dir = freshTemp("t40-growth-retry");
    const turnId = "turn-growth-retry";
    const file = writeJsonl(transcriptPath(dir), [turnContext(turnId, "auto_review")]);
    const probe = reviewerFsProbeEnv(dir, file, "grow-once");
    const { status } = await runReviewerCase("T40 growth retries stable snapshot",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "auto_pass",
      { outcome: "auto_pass", reason: "exact_auto_review" }, probe);
    if (status) {
      check("T40 diagnostics report one retry after growth",
        status.grew === true && status.attempts === 2, JSON.stringify(status));
    }
  }

  // T41: if individual reads are slow, the probe checks its deadline between
  // bounded chunks and fails toward the popup instead of completing the scan
  // after the 250 ms reviewer budget.
  {
    const dir = freshTemp("t41-slow-read-budget");
    const turnId = "turn-slow-read-budget";
    const file = transcriptPath(dir);
    const filler = JSON.stringify(turnContext("other-turn", "user", {
      padding: "x".repeat(128 * 1024),
    })) + "\n";
    fs.writeFileSync(file,
      filler.repeat(32) + JSON.stringify(turnContext(turnId, "auto_review")) + "\n", "utf8");
    const probe = reviewerFsProbeEnv(dir, file, "slow-read");
    const { status } = await runReviewerCase("T41 slow chunks respect reviewer budget",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "popup",
      { outcome: "popup", reason: "budget_exceeded" }, probe);
    if (status) {
      check("T41 budget stops before the full snapshot is read",
        status.elapsed_ms >= 250 && status.scanned_bytes < status.file_bytes,
        JSON.stringify(status));
    }
  }

  // T42: JSON.parse is synchronous and cannot be preempted, but its result must
  // not authorize after the cooperative 250 ms budget has expired. Delay only
  // the new oversized non-turn parse path, then require a fail-safe popup.
  {
    const dir = freshTemp("t42-slow-parse-budget");
    const turnId = "turn-slow-parse-budget";
    const file = writeJsonl(transcriptPath(dir), [
      {
        type: "response_item",
        payload: { type: "custom_tool_call_output", output: "x".repeat(5 * 1024 * 1024) },
      },
      turnContext(turnId, "auto_review"),
    ]);
    const probe = reviewerFsProbeEnv(dir, file, "slow-parse");
    const { status } = await runReviewerCase("T42 slow oversized parse respects reviewer budget",
      reviewerPayload(file, turnId), hostEnv("conhost"), dir, "popup",
      { outcome: "popup", reason: "budget_exceeded" }, probe);
    if (status) {
      check("T42 budget is checked immediately after the blocking parse",
        status.elapsed_ms >= 250 && status.scanned_bytes === status.file_bytes,
        JSON.stringify(status));
    }
  }

  console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
  process.exit(fail ? 1 : 0);
}

main();
