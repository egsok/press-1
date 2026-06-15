// Offline tests for codex-mitm.js (experimental proxy channel): byte-exact
// relay, pending publish (atomic), decision inject (accept/cancel/amendment),
// resolved cleanup, passthrough, ctrl-dir degradation, PRESS1_PROXY env gating,
// fail-loud resolve, exit propagation. Isolated TEMP per test (CTRL/LOG dirs
// derive from os.tmpdir(), same isolation as the hook suites).
// Run: node tests/codex-mitm.test.js
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const MITM = path.join(__dirname, "..", "codex-mitm.js");
const BASE = path.join(os.tmpdir(), "press-1-tests", "mitm");

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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(cond, timeoutMs, stepMs = 50) {
  const t0 = Date.now();
  for (;;) {
    const v = cond();
    if (v) return v;
    if (Date.now() - t0 > timeoutMs) return null;
    await sleep(stepMs);
  }
}

// --- fake codex app-server -------------------------------------------------
// Speaks JSONL on stdio. Behavior is driven by control lines the test sends
// through the wrapper's stdin (they relay to the fake server byte-exact):
//   {"fake":"approval","id":N,"params":{...}}  -> emit requestApproval N to stdout
//   {"fake":"echo","blob":"..."}               -> emit the blob back verbatim
//   {"fake":"dumpenv","file":"..."}            -> write PRESS1_PROXY value to file
//   {"fake":"exit","code":N}                   -> exit
// Any OTHER frame (e.g. an injected decision {"jsonrpc":"2.0","id":N,"result":…})
// is recorded to FAKE_RECV_FILE and, if it answers an open approval, followed by
// serverRequest/resolved for that id.
const FAKE_SRC = `
const fs = require("fs");
const recvFile = process.env.FAKE_RECV_FILE;
const open = new Set();
let buf = "";
const out = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
process.stdin.on("data", (d) => {
  buf += d.toString("utf8");
  let nl;
  while ((nl = buf.indexOf("\\n")) >= 0) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.fake === "approval") { open.add(m.id); out({ jsonrpc: "2.0", id: m.id, method: "item/commandExecution/requestApproval", params: m.params || {} }); }
    else if (m.fake === "echo") { process.stdout.write(m.blob); }
    else if (m.fake === "dumpenv") { fs.writeFileSync(m.file, JSON.stringify({ PRESS1_PROXY: process.env.PRESS1_PROXY ?? null })); }
    else if (m.fake === "exit") { process.exit(m.code || 0); }
    else {
      fs.appendFileSync(recvFile, line + "\\n");
      if (m.id != null && open.has(m.id)) { open.delete(m.id); out({ jsonrpc: "2.0", method: "serverRequest/resolved", params: { requestId: m.id } }); }
    }
  }
});
`;

const APPROVAL_PARAMS = {
  threadId: "th-1", turnId: "tu-1", itemId: "call_x",
  command: '"C:\\\\Program Files\\\\PowerShell\\\\7\\\\pwsh.exe" -Command "Set-Content -LiteralPath \\"C:\\\\Users\\\\Ёжик Тест\\\\out.txt\\" -Value hi"',
  cwd: "D:\\dev\\claude-approve",
  reason: "Нужны права",
  availableDecisions: ["accept", { acceptWithExecpolicyAmendment: { execpolicy_amendment: ["Set-Content", "-LiteralPath", "C:\\Users\\Ёжик Тест\\out.txt"] } }, "cancel"],
  proposedExecpolicyAmendment: ["Set-Content", "-LiteralPath", "C:\\Users\\Ёжик Тест\\out.txt"],
};

// Start the wrapper (node form) around the fake server, with TEMP isolated.
function startMitm(tempDir, { breakCtrl = false, extraEnv = {} } = {}) {
  const fakePath = path.join(tempDir, "fake-codex.js");
  fs.writeFileSync(fakePath, FAKE_SRC);
  const recvFile = path.join(tempDir, "fake-recv.jsonl");
  fs.writeFileSync(recvFile, "");
  if (breakCtrl) {
    // %TEMP%\press-1\proxy occupied by a FILE => mkdir fails => ctrlOk=false.
    fs.mkdirSync(path.join(tempDir, "press-1"), { recursive: true });
    fs.writeFileSync(path.join(tempDir, "press-1", "proxy"), "not a dir");
  }
  const env = {
    ...process.env,
    TEMP: tempDir, TMP: tempDir,
    PRESS1_CODEX_TARGET: process.execPath, // fake child = node.exe fake-codex.js
    FAKE_RECV_FILE: recvFile,
    ...extraEnv,
  };
  delete env.PRESS1_PROXY; // never inherit from the runner
  const child = spawn(process.execPath, [MITM, fakePath], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = Buffer.alloc(0), stderr = "";
  child.stdout.on("data", (d) => { stdout = Buffer.concat([stdout, d]); });
  child.stderr.on("data", (d) => { stderr += d.toString(); });
  const exited = new Promise((r) => child.on("exit", (code) => r(code)));
  return {
    child, recvFile, exited,
    getStdout: () => stdout, getStderr: () => stderr,
    send: (line) => child.stdin.write(line),
    ctrlDir: path.join(tempDir, "press-1", "proxy"),
    recvLines: () => fs.readFileSync(recvFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)),
  };
}

function pendingIn(dir) {
  try { return fs.readdirSync(dir).filter((f) => f.endsWith(".pending.json")); } catch { return []; }
}

async function tAcceptFlow() {
  console.log("T1 accept: pending appears (atomic), inject, resolved cleanup");
  const dir = freshTemp("t1");
  const m = startMitm(dir);
  m.send(JSON.stringify({ fake: "approval", id: 0, params: APPROVAL_PARAMS }) + "\n");
  const pend = await waitFor(() => pendingIn(m.ctrlDir)[0], 4000);
  check("pending file appears", !!pend);
  if (pend) {
    const p = JSON.parse(fs.readFileSync(path.join(m.ctrlDir, pend), "utf8"));
    check("schema press1.codex.proxy/1", p.schema === "press1.codex.proxy/1");
    check("payload fields", p.agent === "codex" && p.channel === "proxy" && p.requestId === 0 && p.command === APPROVAL_PARAMS.command && p.cwd === APPROVAL_PARAMS.cwd && Array.isArray(p.availableDecisions));
    check("pending name is <pid>-<reqId>", pend === `${m.child.pid}-0.pending.json`);
    check("no .tmp remnants", !fs.readdirSync(m.ctrlDir).some((f) => f.endsWith(".tmp")));
    fs.writeFileSync(path.join(m.ctrlDir, `${m.child.pid}-0.decision.json`), JSON.stringify({ decision: "accept" }));
    const injected = await waitFor(() => m.recvLines().find((l) => l.id === 0), 4000);
    check("inject reached server", !!injected && injected.jsonrpc === "2.0" && injected.result && injected.result.decision === "accept");
    const cleaned = await waitFor(() => pendingIn(m.ctrlDir).length === 0 && !fs.existsSync(path.join(m.ctrlDir, `${m.child.pid}-0.decision.json`)), 4000);
    check("pending+decision cleaned on resolved", !!cleaned);
    const resolvedOut = await waitFor(() => m.getStdout().toString("utf8").includes("serverRequest/resolved"), 2000);
    check("resolved relayed to extension", !!resolvedOut);
  }
  m.send(JSON.stringify({ fake: "exit", code: 0 }) + "\n");
  check("exit code propagated", (await m.exited) === 0);
}

async function tCancelAndAmendment() {
  console.log("T2 cancel + amendment objects inject verbatim");
  const dir = freshTemp("t2");
  const m = startMitm(dir);
  m.send(JSON.stringify({ fake: "approval", id: 5, params: APPROVAL_PARAMS }) + "\n");
  await waitFor(() => pendingIn(m.ctrlDir).length === 1, 4000);
  fs.writeFileSync(path.join(m.ctrlDir, `${m.child.pid}-5.decision.json`), JSON.stringify({ decision: "cancel" }));
  const cancel = await waitFor(() => m.recvLines().find((l) => l.id === 5), 4000);
  check("cancel injected", !!cancel && cancel.result.decision === "cancel");

  m.send(JSON.stringify({ fake: "approval", id: 6, params: APPROVAL_PARAMS }) + "\n");
  await waitFor(() => pendingIn(m.ctrlDir).length === 1, 4000);
  const amendment = { acceptWithExecpolicyAmendment: { execpolicy_amendment: APPROVAL_PARAMS.proposedExecpolicyAmendment } };
  fs.writeFileSync(path.join(m.ctrlDir, `${m.child.pid}-6.decision.json`), JSON.stringify({ decision: amendment }));
  const amend = await waitFor(() => m.recvLines().find((l) => l.id === 6), 4000);
  check("amendment injected structurally", !!amend && JSON.stringify(amend.result.decision) === JSON.stringify(amendment));
  m.send(JSON.stringify({ fake: "exit", code: 0 }) + "\n");
  await m.exited;
}

async function tPassthroughAndRelay() {
  console.log("T3 passthrough (no decision) + byte-exact relay");
  const dir = freshTemp("t3");
  const m = startMitm(dir);
  // Odd blob: multi-frame, split-unfriendly, non-JSON line included.
  const blob = '{"jsonrpc":"2.0","id":9,"method":"x/y","params":{"s":"привет\\"кавычки\\""}}\nnot json at all\n{"a":1}\n';
  m.send(JSON.stringify({ fake: "echo", blob }) + "\n");
  const got = await waitFor(() => m.getStdout().toString("utf8").includes('{"a":1}'), 4000);
  check("relay delivered", !!got);
  check("relay byte-exact", m.getStdout().toString("utf8").includes(blob));
  // Passthrough: approval with NO decision file; the extension answers instead.
  m.send(JSON.stringify({ fake: "approval", id: 7, params: APPROVAL_PARAMS }) + "\n");
  await waitFor(() => pendingIn(m.ctrlDir).length === 1, 4000);
  m.send(JSON.stringify({ jsonrpc: "2.0", id: 7, result: { decision: "accept" } }) + "\n"); // native answer via wrapper stdin
  const cleaned = await waitFor(() => pendingIn(m.ctrlDir).length === 0, 4000);
  check("pending cleaned on native resolve (no inject)", !!cleaned);
  const injected = m.recvLines().filter((l) => l.id === 7);
  check("exactly one answer reached server (the native one)", injected.length === 1);
  const logDir = path.join(dir, "press-1", "wrapper");
  const logTxt = fs.existsSync(logDir) ? fs.readdirSync(logDir).map((f) => fs.readFileSync(path.join(logDir, f), "utf8")).join("") : "";
  check("native answer logged (client_answer diag)", /"ev":"client_answer"/.test(logTxt) && /"id":7/.test(logTxt));
  m.send(JSON.stringify({ fake: "exit", code: 0 }) + "\n");
  await m.exited;
}

async function tCtrlDegradation() {
  console.log("T4 ctrl-dir unavailable: pass-through, no pending, NO PRESS1_PROXY");
  const dir = freshTemp("t4");
  const m = startMitm(dir, { breakCtrl: true });
  const envFile = path.join(dir, "env-dump.json");
  m.send(JSON.stringify({ fake: "dumpenv", file: envFile }) + "\n");
  const dumped = await waitFor(() => fs.existsSync(envFile), 4000);
  check("fake server alive (relay works)", !!dumped);
  if (dumped) check("PRESS1_PROXY NOT set when ctrl dead", JSON.parse(fs.readFileSync(envFile, "utf8")).PRESS1_PROXY === null);
  m.send(JSON.stringify({ fake: "approval", id: 1, params: APPROVAL_PARAMS }) + "\n");
  await sleep(600);
  check("no pending written", pendingIn(path.join(dir, "press-1", "proxy")).length === 0);
  const relayed = m.getStdout().toString("utf8").includes("requestApproval");
  check("approval still relayed to extension", relayed);
  m.send(JSON.stringify({ fake: "exit", code: 0 }) + "\n");
  await m.exited;
}

async function tEnvGating() {
  console.log("T5 PRESS1_PROXY=1 in child env when ctrl is up");
  const dir = freshTemp("t5");
  const m = startMitm(dir);
  const envFile = path.join(dir, "env-dump.json");
  m.send(JSON.stringify({ fake: "dumpenv", file: envFile }) + "\n");
  const dumped = await waitFor(() => fs.existsSync(envFile), 4000);
  check("env dumped", !!dumped);
  if (dumped) check("PRESS1_PROXY=1 inherited by server", JSON.parse(fs.readFileSync(envFile, "utf8")).PRESS1_PROXY === "1");
  m.send(JSON.stringify({ fake: "exit", code: 3 }) + "\n");
  check("nonzero exit propagated", (await m.exited) === 3);
}

async function tFailLoud() {
  console.log("T6 fail-loud when no binary resolvable");
  const dir = freshTemp("t6");
  const emptyExt = path.join(dir, "no-extensions");
  fs.mkdirSync(emptyExt, { recursive: true });
  const env = { ...process.env, TEMP: dir, TMP: dir, PRESS1_MITM_EXT_ROOT: emptyExt };
  delete env.PRESS1_CODEX_TARGET;
  const child = spawn(process.execPath, [MITM, "app-server"], { env, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d.toString(); });
  const code = await new Promise((r) => child.on("exit", (c) => r(c)));
  check("exit 127", code === 127);
  check("loud stderr", stderr.includes("no bundled Codex binary"));
}

async function tExitCleanup() {
  console.log("T7 wrapper exit cleans its pendings");
  const dir = freshTemp("t7");
  const m = startMitm(dir);
  m.send(JSON.stringify({ fake: "approval", id: 2, params: APPROVAL_PARAMS }) + "\n");
  await waitFor(() => pendingIn(m.ctrlDir).length === 1, 4000);
  m.send(JSON.stringify({ fake: "exit", code: 0 }) + "\n");
  await m.exited;
  check("pending removed on exit", pendingIn(m.ctrlDir).length === 0);
}

(async () => {
  await tAcceptFlow();
  await tCancelAndAmendment();
  await tPassthroughAndRelay();
  await tCtrlDegradation();
  await tEnvGating();
  await tFailLoud();
  await tExitCleanup();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
