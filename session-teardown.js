// session-teardown.js — PostToolUse + Stop hook (one file serves both events).
//
// A pending file means "a prompt is waiting for the user". Scenarios A (WT/
// conhost) and C (extension panel) have no scrape channel to notice the user
// answering in the TUI/native box — without this hook those pendings linger as
// zombie popup rows until a coarse TTL.
//
// The two events have different powers, and the payload tells them apart
// without depending on hook_event_name spelling across two agents: PostToolUse
// always carries tool_name, Stop never does.
//
// PostToolUse — scoped. A same-session pending is deleted when:
//  - its tool_key matches the tool that JUST COMPLETED (2026-08-03). A finished
//    tool is proof its prompt was answered — this is the only rule that does
//    not depend on the hook dying, and the current Claude Code no longer kills
//    the losing PermissionRequest hook (live incident: two panel prompts
//    answered, both tools ran, both hooks still polling minutes later, both
//    cards on screen). At most ONE pending per event, oldest first, so two
//    identical parallel commands each need their own completion.
//  - its hook is DEAD (older builds killed the loser; also covers crashes),
//  - it is a native_control row (Codex phase 2 — the hook exited by design),
//  - it is kind:"picker" — INVERTED semantics: the hook is a liveness BEACON
//    deliberately blocked on waitForPendingGone, and deleting the pending on a
//    same-session event IS its designed release path (the row carries no
//    decision channel, so nothing answerable is lost). Live regression proof
//    2026-07-28: an answered AskUserQuestion card hung for minutes under the
//    liveness shield.
// Everything else survives: a live hook with an unrelated tool_key is a
// genuinely waiting sibling prompt (parallel tool calls are routine now), and
// one hotkey answer must never downgrade the other cards to native-only.
//
// Stop — blanket delete of the session's pendings. The turn is over, and a
// waiting prompt BLOCKS the turn, so nothing answerable can still exist. This
// is the backstop that covers what PostToolUse cannot see: a natively DENIED
// prompt (deny runs no tool → no PostToolUse). Interrupt/Esc fires neither
// event — that path stays with the AHK orphan-gate.
//
// PID reuse can misread "alive" — the AHK orphan-gate (ProcessStartMs +
// PidStaleDecision) still reaps that row within a tick, so the failure
// direction is "row lives slightly longer", never a misrouted answer.
//
// Like every hook here: never break Claude Code — swallow all errors, exit 0.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const PENDING_DIR = path.join(
  process.env.TEMP || path.join(process.env.USERPROFILE, "AppData", "Local", "Temp"),
  "press-1",
  "pending"
);

function hookAlive(pid) {
  if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return !!(e && e.code === "EPERM"); }
}

// Byte-identical copy of permission-request.js's toolKey (see the comment
// there for why it is duplicated rather than shared). Both sides are pinned to
// the same digest by session-teardown.test.js T10 / hook.test.js T17.
function toolKey(name, input) {
  const canon = (v) => {
    if (Array.isArray(v)) return v.map(canon);
    if (v && typeof v === "object")
      return Object.keys(v).sort().reduce((o, k) => ((o[k] = canon(v[k])), o), {});
    return v;
  };
  try {
    return crypto
      .createHash("sha1")
      .update(String(name || "") + " " + JSON.stringify(canon(input === undefined ? null : input)))
      .digest("hex");
  } catch {
    return "";
  }
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  try {
    const data = JSON.parse(input);
    const sid = data.session_id;
    if (sid) {
      // Stop = a tool-less event. The event name is only a guard: an unknown
      // tool-less event (SubagentStop — a sibling subagent's prompt CAN still
      // be waiting) must not get blanket powers. Missing name stays blanket:
      // that is the legacy Stop payload shape.
      const evName = typeof data.hook_event_name === "string" ? data.hook_event_name : "";
      const turnOver = !data.tool_name && (!evName || /^stop$/i.test(evName));
      const doneKey = data.tool_name ? toolKey(data.tool_name, data.tool_input) : "";

      const matched = [];  // same-session rows that answer to the completed tool
      for (const f of fs.readdirSync(PENDING_DIR)) {
        if (!f.endsWith(".json")) continue;
        const full = path.join(PENDING_DIR, f);
        try {
          const entry = JSON.parse(fs.readFileSync(full, "utf8"));
          if (entry.session_id !== sid) continue;
          if (turnOver || entry.native_control === true || entry.kind === "picker"
            || !hookAlive(entry.hook_pid)) {
            fs.unlinkSync(full);
            continue;
          }
          if (doneKey && entry.tool_key === doneKey)
            matched.push({ full, at: Number(entry.timestamp) || 0 });
        } catch {}
      }
      // One completion answers one card: with two identical parallel commands
      // the popup shows two rows, and each needs its own PostToolUse.
      if (matched.length) {
        matched.sort((a, b) => a.at - b.at);
        try { fs.unlinkSync(matched[0].full); } catch {}
      }
    }
  } catch {}
  process.exit(0);
});
