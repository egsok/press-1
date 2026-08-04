// press-1 — codex-mitm: stdio MITM wrapper for the Codex VS Code panel
// (experimental proxy channel; design: docs/DESIGN-CODEX-PROXY.md).
// Deployed as a Node SEA .exe and pointed to by chatgpt.cliExecutable; the
// extension spawns it instead of the bundled `codex app-server`.
//
//   extension  <--stdio-->  THIS WRAPPER  <--stdio-->  real codex app-server
//     process.stdin  = frames from extension -> child.stdin  (relay + observe)
//     child.stdout   = frames from server    -> process.stdout(relay + observe + inject)
//
// SAFETY-FIRST invariants (this sits in the extension's critical path — the only
// press-1 component able to break the agent):
//   1. The raw relay ALWAYS runs first, per whole frame, and can NEVER be blocked
//      or thrown-into by the observer/injector. A bug in inject => the panel still
//      works (worst case: the press-1 feature is inert), never a dead agent.
//   2. If the control channel can't be set up, degrade to pure pass-through —
//      and do NOT set PRESS1_PROXY, so the hook channel stays alive for the panel.
//   3. Missing real binary => fail LOUD (exit 127), not a silent zombie.
//
// Channel arbitration: PRESS1_PROXY=1 is added to the child app-server env only
// when the control channel is up; hook processes inherit it and self-mute
// (codex-permission-request.js). The var exists only under a live wrapper, so a
// dead/removed wrapper self-heals back to the hook channel.
//
// Control channel:  %TEMP%\press-1\proxy\   (protocol press1.codex.proxy/1)
//   <pid>-<requestId>.pending.json    wrapper  -> press-1 : approval payload
//   <pid>-<requestId>.decision.json   press-1  -> wrapper : { decision }
// Per-(pid,requestId) files: multiple panels = distinct wrapper pids = no
// collisions, and fail-closed matching is by requestId.
//
// Env overrides (tests): PRESS1_CODEX_TARGET (pin the real binary),
// PRESS1_MITM_EXT_ROOT (bundle scan root); dirs isolate via TEMP like the hooks.
//
// Runs as `node codex-mitm.js app-server …` and as a Node SEA `.exe`.
"use strict";
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

let isSea = false;
try { isSea = require("node:sea").isSea(); } catch { isSea = false; }
// Real args start at index 2 in BOTH forms: plain node is [node, script, ...args];
// a Node SEA is [exe, exe, ...args] (argv[1] repeats the exe path). Verified SP-1.
const args = process.argv.slice(2);

// --- forensic log (never allowed to break the relay) -----------------------
const LOGDIR = path.join(os.tmpdir(), "press-1", "wrapper");
const log = (obj) => {
  try {
    fs.mkdirSync(LOGDIR, { recursive: true });
    fs.appendFileSync(
      path.join(LOGDIR, "mitm-" + process.pid + ".log"),
      JSON.stringify({ pid: process.pid, dt: Date.now(), ...obj }) + "\n"
    );
  } catch { /* logging must never break pass-through */ }
};

// --- resolve the freshest bundled codex.exe (proven in SP-1/SP-2) ----------
function resolveBundledCodex() {
  const override = process.env.PRESS1_CODEX_TARGET; // test seam / manual pin
  if (override && fs.existsSync(override)) return override;
  const extRoot = process.env.PRESS1_MITM_EXT_ROOT
    || path.join(os.homedir(), ".vscode", "extensions");
  let cands;
  try { cands = fs.readdirSync(extRoot); } catch { return null; }
  const cmp = (a, b) => {
    const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const d = (pa[i] || 0) - (pb[i] || 0);
      if (d) return d;
    }
    return 0;
  };
  const matches = cands
    .map((name) => {
      const m = /^openai\.chatgpt-(\d+(?:\.\d+)*)-win32-x64$/.exec(name);
      return m ? { name, ver: m[1] } : null;
    })
    .filter(Boolean)
    .sort((a, b) => cmp(b.ver, a.ver));
  for (const c of matches) {
    const exe = path.join(extRoot, c.name, "bin", "windows-x86_64", "codex.exe");
    if (fs.existsSync(exe)) return exe;
  }
  return null;
}

const target = resolveBundledCodex();
log({ ev: "spawn", isSea, args, target });
if (!target) {
  process.stderr.write("[press-1 mitm] no bundled Codex binary found under ~/.vscode/extensions/openai.chatgpt-*-win32-x64\n");
  log({ ev: "fail", reason: "no target" });
  process.exit(127);
}

// --- control channel (best-effort; failure => pure pass-through) -----------
const CTRL_DIR = path.join(os.tmpdir(), "press-1", "proxy");
let ctrlOk = false;
try { fs.mkdirSync(CTRL_DIR, { recursive: true }); ctrlOk = true; }
catch (e) { log({ ev: "ctrl_disabled", err: String(e) }); }

const pendingPath = (id) => path.join(CTRL_DIR, process.pid + "-" + id + ".pending.json");
const decisionPath = (id) => path.join(CTRL_DIR, process.pid + "-" + id + ".decision.json");

// --- inlined line splitter (same logic as spikes/codex-proxy/linesplit.mjs) -
// forwardRaw(lineBuf) transmits exact bytes (incl. \n) untouched; onMsg(obj) gets
// the parsed copy for observe/inject. Partial trailing bytes retained across chunks.
function makeLineSplitter(forwardRaw, onMsg) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    let nl;
    while ((nl = buf.indexOf(0x0a)) >= 0) {
      const lineBuf = buf.slice(0, nl + 1);
      buf = buf.slice(nl + 1);
      forwardRaw(lineBuf); // <-- transit FIRST, always, per whole frame
      let obj = null;
      const s = lineBuf.toString("utf8").trim();
      if (s) { try { obj = JSON.parse(s); } catch { obj = null; } }
      if (obj) { try { onMsg(obj); } catch (e) { log({ ev: "observe_throw", err: String(e) }); } }
    }
  };
}

// PRESS1_PROXY only under a working control channel: if the channel is dead the
// proxy feature is inert, so the hook channel must stay alive for the panel.
const childEnv = ctrlOk ? { ...process.env, PRESS1_PROXY: "1" } : { ...process.env };
const child = spawn(target, args, {
  stdio: ["pipe", "pipe", "pipe"],
  env: childEnv,
});
child.on("error", (e) => {
  process.stderr.write("[press-1 mitm] failed to spawn " + target + ": " + e.message + "\n");
  log({ ev: "child_error", err: String(e) });
  process.exit(126);
});

// stderr is opaque: relay bytes straight through.
child.stderr.on("data", (d) => { try { process.stderr.write(d); } catch {} });

// --- MITM state ------------------------------------------------------------
// outstanding: requestId -> { availableDecisions, answered }
const outstanding = new Map();
let pollTimer = null;

const toServer = (obj) => { try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch (e) { log({ ev: "inject_write_err", err: String(e) }); } };

function cleanupFiles(id) {
  if (!ctrlOk) return;
  for (const p of [pendingPath(id), decisionPath(id)]) {
    try { fs.rmSync(p, { force: true }); } catch {}
  }
}

function startPolling() {
  if (pollTimer || !ctrlOk) return;
  pollTimer = setInterval(() => {
    try {
      for (const [id, st] of outstanding) {
        if (st.answered) continue;
        let raw;
        try { raw = fs.readFileSync(decisionPath(id), "utf8"); } catch { continue; } // not written yet
        let dec;
        try { dec = JSON.parse(raw).decision; } catch { continue; } // partial write; retry next tick
        if (dec === undefined) continue;
        // Validate against what the server offered for THIS request; fail loud in
        // the log but still forward a sane fallback so a decision is never dropped.
        const names = (st.availableDecisions || []).map((d) => (typeof d === "string" ? d : Object.keys(d)[0]));
        if (names.length && !decisionOffered(dec, names)) {
          log({ ev: "decision_not_offered", id, dec, names });
        }
        st.answered = true;
        toServer({ jsonrpc: "2.0", id, result: { decision: dec } });
        log({ ev: "inject", id, decision: dec });
      }
    } catch (e) { log({ ev: "poll_throw", err: String(e) }); }
    if (![...outstanding.values()].some((s) => !s.answered)) stopPolling();
  }, 80);
  if (pollTimer.unref) pollTimer.unref();
}
function stopPolling() { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } }

function decisionOffered(dec, names) {
  if (typeof dec === "string") return names.includes(dec);
  if (dec && typeof dec === "object") return names.includes(Object.keys(dec)[0]);
  return false;
}

// server -> client observer
function onServer(m) {
  const method = typeof m.method === "string" ? m.method : "";
  if (m.id != null && /requestApproval/i.test(method)) {
    const p = m.params || {};
    outstanding.set(m.id, { availableDecisions: p.availableDecisions || [], answered: false });
    if (ctrlOk) {
      const payload = {
        schema: "press1.codex.proxy/1",
        pid: process.pid,
        agent: "codex",
        channel: "proxy",
        requestId: m.id,
        threadId: p.threadId ?? null,
        turnId: p.turnId ?? null,
        itemId: p.itemId ?? null,
        command: p.command ?? null,
        cwd: p.cwd ?? null,
        reason: p.reason ?? null,
        availableDecisions: p.availableDecisions ?? [],
        proposedExecpolicyAmendment: p.proposedExecpolicyAmendment ?? null,
        ts: Date.now(),
      };
      // Atomic publish: AHK polls this dir every 200 ms — never expose a torn file.
      try {
        const tmp = pendingPath(m.id) + ".tmp";
        fs.writeFileSync(tmp, JSON.stringify(payload));
        fs.renameSync(tmp, pendingPath(m.id));
      }
      catch (e) { log({ ev: "pending_write_err", err: String(e) }); }
    }
    log({ ev: "approval", id: m.id, method, command: (p.command || "").slice(0, 120) });
    startPolling();
  } else if (/serverRequest\/resolved|(^|\/)resolved$/i.test(method)) {
    // The request is resolved (by us or the extension). Drop the pending file so
    // press-1 knows the card is gone, and stop tracking it.
    const id = m.params && (m.params.requestId ?? m.params.id);
    if (id != null) { cleanupFiles(id); outstanding.delete(id); }
    log({ ev: "resolved", id });
    if (![...outstanding.values()].some((s) => !s.answered)) stopPolling();
  }
}

// client -> server observer (relay only; the extension's own late answer is
// harmless — the server ignores a stale callback, proven in SP-0 scenario 4).
// Diagnostic: log the extension's own answers to approvals (id + result). This
// is how the NATIVE panel "No, and tell Codex differently" is captured — it lets
// us see whether the graceful decline is a different decision value we could
// inject, vs our abort-y `cancel` (BACKLOG 20). Cheap: approvals are rare.
function onClient(m) {
  // Diagnostic only: log the extension's own JSON-RPC answer to an approval, if
  // it ever sends one on this channel. Discovery 2026-07-17 (BACKLOG 20): the
  // native panel Deny does NOT travel this path — the server resolves it out of
  // band, so this stays quiet in practice. Kept as a cheap probe for the "late
  // loser" (a webview answer arriving after our inject).
  if (m && m.id != null && m.result !== undefined && outstanding.has(m.id)) {
    log({ ev: "client_answer", id: m.id, result: m.result });
  }
}

const serverRelay = makeLineSplitter((raw) => { try { process.stdout.write(raw); } catch {} }, onServer);
const clientRelay = makeLineSplitter((raw) => { try { child.stdin.write(raw); } catch {} }, onClient);

child.stdout.on("data", serverRelay);
process.stdin.on("data", clientRelay);
process.stdin.on("end", () => { try { child.stdin.end(); } catch {} });

function shutdown(code, signal) {
  stopPolling();
  for (const id of outstanding.keys()) cleanupFiles(id);
  log({ ev: "child_exit", code, signal });
  if (signal) { try { process.kill(process.pid, signal); } catch {} }
  process.exit(code == null ? 0 : code);
}
child.on("exit", (code, signal) => shutdown(code, signal));
