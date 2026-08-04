// Offline suite for session-teardown.js (PostToolUse + Stop hook).
// Sandbox: %TEMP%\press-1-tests\teardown-<pid> (isolated TEMP for the child).
//
// Contract under test, two events with different powers (2026-08-03):
//  - PostToolUse (payload HAS tool_name): scoped. Deletes dead-hook zombies,
//    native_control and picker rows as before, PLUS the one pending whose
//    tool_key matches the tool that just completed — a completed tool means
//    its prompt was answered, whatever the hook's liveness says. Live siblings
//    with a different tool_key survive and stay hotkey-answerable.
//  - Stop (payload has NO tool_name): blanket delete of the session's pendings.
//    A finished turn cannot leave a prompt waiting — a waiting prompt blocks
//    the turn — so nothing answerable can be lost. This is what covers a
//    natively DENIED prompt (deny fires no PostToolUse).

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn, spawnSync } = require("child_process");

// Mirror of the hook's tool identity (permission-request.js). Pinned by a
// literal expected digest in T10 so the two copies cannot drift apart.
function toolKey(name, input) {
  const canon = (v) => {
    if (Array.isArray(v)) return v.map(canon);
    if (v && typeof v === "object")
      return Object.keys(v).sort().reduce((o, k) => ((o[k] = canon(v[k])), o), {});
    return v;
  };
  return crypto
    .createHash("sha1")
    .update(String(name || "") + " " + JSON.stringify(canon(input === undefined ? null : input)))
    .digest("hex");
}

const ROOT = path.join(__dirname, "..");
const HOOK = path.join(ROOT, "session-teardown.js");
const SANDBOX = path.join(
  process.env.TEMP || ".",
  "press-1-tests",
  "teardown-" + process.pid
);
const PENDING_DIR = path.join(SANDBOX, "press-1", "pending");

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log("  OK   " + name); }
  else { fail++; console.log("  FAIL " + name + (extra ? "  [" + extra + "]" : "")); }
}

function resetPending() {
  fs.rmSync(PENDING_DIR, { recursive: true, force: true });
  fs.mkdirSync(PENDING_DIR, { recursive: true });
}

function writePending(name, entry) {
  const full = path.join(PENDING_DIR, name);
  fs.writeFileSync(full, typeof entry === "string" ? entry : JSON.stringify(entry, null, 2), "utf8");
  return full;
}

function runTeardown(payload) {
  const r = spawnSync("node", [HOOK], {
    input: typeof payload === "string" ? payload : JSON.stringify(payload),
    env: Object.assign({}, process.env, { TEMP: SANDBOX }),
    encoding: "utf8",
    timeout: 15000,
  });
  return r.status;
}

// A PostToolUse payload — the real one always carries tool_name + tool_input.
function postToolUse(sid, name, input) {
  return {
    session_id: sid,
    hook_event_name: "PostToolUse",
    tool_name: name || "Bash",
    tool_input: input || { command: "unrelated --command" },
  };
}
const stop = (sid) => ({ session_id: sid, hook_event_name: "Stop" });

// A PID that is guaranteed dead: spawn a no-op node child and wait for exit.
function deadPid() {
  return new Promise((resolve) => {
    const child = spawn("node", ["-e", ""], { stdio: "ignore" });
    const pid = child.pid;
    child.on("exit", () => resolve(pid));
  });
}

(async () => {
  const DEAD = await deadPid();
  const LIVE = process.pid;  // this test runner is alive for the whole run

  console.log("T1: dead-hook same-session pending is deleted");
  resetPending();
  const p1 = writePending("a.json", { session_id: "s1", hook_pid: DEAD });
  check("T1 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T1 zombie deleted", !fs.existsSync(p1));

  console.log("T2: live-hook same-session sibling SURVIVES (parallel tools)");
  resetPending();
  const p2 = writePending("a.json", { session_id: "s1", hook_pid: LIVE });
  const p2b = writePending("b.json", { session_id: "s1", hook_pid: DEAD });
  check("T2 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T2 live sibling survives", fs.existsSync(p2));
  check("T2 dead sibling still cleaned", !fs.existsSync(p2b));

  console.log("T3: native_control row is deleted regardless of liveness");
  resetPending();
  const p3 = writePending("a.json", { session_id: "s1", hook_pid: LIVE, native_control: true });
  check("T3 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T3 native_control deleted", !fs.existsSync(p3));

  console.log("T4: other-session pending is never touched");
  resetPending();
  const p4 = writePending("a.json", { session_id: "s2", hook_pid: DEAD });
  check("T4 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T4 other session untouched", fs.existsSync(p4));

  console.log("T5: payload without session_id deletes nothing");
  resetPending();
  const p5 = writePending("a.json", { session_id: "s1", hook_pid: DEAD });
  check("T5 exit 0", runTeardown({}) === 0);
  check("T5 nothing deleted", fs.existsSync(p5));

  console.log("T6: legacy pending without hook_pid is cleaned (conservative)");
  resetPending();
  const p6 = writePending("a.json", { session_id: "s1" });
  check("T6 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T6 legacy cleaned", !fs.existsSync(p6));

  console.log("T7: malformed pending and non-json files are skipped, no crash");
  resetPending();
  const p7 = writePending("a.json", "{ not json");
  const p7b = writePending("b.txt", "not a pending");
  check("T7 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T7 malformed left in place", fs.existsSync(p7));
  check("T7 non-json untouched", fs.existsSync(p7b));

  console.log("T9: picker beacon row is deleted even with a LIVE hook (release path)");
  resetPending();
  const p9 = writePending("a.json", { session_id: "s1", hook_pid: LIVE, kind: "picker" });
  const p9b = writePending("b.json", { session_id: "s1", hook_pid: LIVE, kind: "permission" });
  check("T9 exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T9 live picker beacon released", !fs.existsSync(p9));
  check("T9 live permission sibling still survives", fs.existsSync(p9b));

  // ---- 2026-08-03: the liveness oracle alone is not enough --------------
  // Live incident: two panel prompts answered natively, both tools ran, yet
  // BOTH hooks stayed alive minutes later — this Claude Code build does not
  // kill the losing PermissionRequest hook. The cards hung for the full
  // 60-min window. The completed tool itself is the missing proof of answer.

  const CMD = { command: 'ssh root@example "git fetch origin" 2>&1 | tail -8' };
  const KEY = toolKey("Bash", CMD);

  console.log("T10: PostToolUse deletes the matching pending even with a LIVE hook");
  resetPending();
  const p10 = writePending("a.json", {
    session_id: "s1", hook_pid: LIVE, kind: "permission",
    tool_name: "Bash", tool_key: KEY, timestamp: 1000,
  });
  check("T10 exit 0", runTeardown(postToolUse("s1", "Bash", CMD)) === 0);
  check("T10 answered-and-completed row deleted", !fs.existsSync(p10));
  // Digest pinned literally: permission-request.js computes this key with its
  // own copy of the formula, so a silent drift on either side must fail here
  // (and in hook.test.js T17) rather than quietly stop matching in production.
  check("T10 key spec pinned", KEY === "4dd67e21f03c69d425d9269b70b99e5bf0c5a70b", KEY);

  console.log("T11: tool_input key ORDER does not affect the match");
  resetPending();
  const p11 = writePending("a.json", {
    session_id: "s1", hook_pid: LIVE, kind: "permission",
    tool_name: "Write", tool_key: toolKey("Write", { file_path: "a.txt", content: "x" }),
  });
  check("T11 exit 0", runTeardown(postToolUse("s1", "Write", { content: "x", file_path: "a.txt" })) === 0);
  check("T11 canonical match deleted the row", !fs.existsSync(p11));

  console.log("T12: only ONE pending is matched per completed tool");
  resetPending();
  const p12a = writePending("a.json", {
    session_id: "s1", hook_pid: LIVE, kind: "permission",
    tool_name: "Bash", tool_key: KEY, timestamp: 1000,
  });
  const p12b = writePending("b.json", {
    session_id: "s1", hook_pid: LIVE, kind: "permission",
    tool_name: "Bash", tool_key: KEY, timestamp: 2000,
  });
  check("T12 exit 0", runTeardown(postToolUse("s1", "Bash", CMD)) === 0);
  check("T12 oldest identical row deleted", !fs.existsSync(p12a));
  check("T12 the second identical row survives", fs.existsSync(p12b));

  console.log("T13: a DIFFERENT tool completing leaves the live row alone");
  resetPending();
  const p13 = writePending("a.json", {
    session_id: "s1", hook_pid: LIVE, kind: "permission",
    tool_name: "Bash", tool_key: KEY,
  });
  check("T13 exit 0", runTeardown(postToolUse("s1", "Bash", { command: "echo other" })) === 0);
  check("T13 unrelated completion keeps the sibling", fs.existsSync(p13));

  console.log("T14: Stop blanket-deletes the session (covers native DENY)");
  resetPending();
  const p14 = writePending("a.json", { session_id: "s1", hook_pid: LIVE, kind: "permission", tool_key: KEY });
  const p14b = writePending("b.json", { session_id: "s1", hook_pid: LIVE, kind: "permission" });
  const p14c = writePending("c.json", { session_id: "s2", hook_pid: LIVE, kind: "permission" });
  check("T14 exit 0", runTeardown(stop("s1")) === 0);
  check("T14 live row a cleared at end of turn", !fs.existsSync(p14));
  check("T14 live row b cleared at end of turn", !fs.existsSync(p14b));
  check("T14 other session untouched by Stop", fs.existsSync(p14c));

  console.log("T15: Stop semantics need a Stop event — SubagentStop stays scoped");
  resetPending();
  const p15 = writePending("a.json", { session_id: "s1", hook_pid: LIVE, kind: "permission" });
  check("T15 exit 0", runTeardown({ session_id: "s1", hook_event_name: "SubagentStop" }) === 0);
  check("T15 live sibling survives a non-Stop tool-less event", fs.existsSync(p15));

  console.log("T16: legacy tool-less payload without an event name still blankets");
  resetPending();
  const p16 = writePending("a.json", { session_id: "s1", hook_pid: LIVE, kind: "permission" });
  check("T16 exit 0", runTeardown({ session_id: "s1" }) === 0);
  check("T16 unnamed tool-less event treated as Stop", !fs.existsSync(p16));

  console.log("T8: missing pending dir and malformed stdin still exit 0");
  fs.rmSync(path.join(SANDBOX, "press-1"), { recursive: true, force: true });
  check("T8 missing dir exit 0", runTeardown(postToolUse("s1")) === 0);
  check("T8 malformed stdin exit 0", runTeardown("{ nope") === 0);

  fs.rmSync(SANDBOX, { recursive: true, force: true });
  console.log(`\n${pass + fail === 0 ? "" : ""}${pass}/${pass + fail} passed`);
  process.exit(fail ? 1 : 0);
})();
