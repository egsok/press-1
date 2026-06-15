// session-teardown.js — PostToolUse + Stop hook (one file serves both events).
//
// A pending file means "a prompt is waiting for the user". Scenarios A (WT/
// conhost) and C (extension panel) have no scrape channel to notice the user
// answering in the TUI/native box — without this hook those pendings linger as
// zombie popup rows until a coarse TTL. Both events imply no prompt is waiting
// anymore for this session: PostToolUse fires after an allowed tool ran, Stop
// when the turn ended (covers deny/cancel paths). So: delete every pending
// whose session_id matches the event's.
//
// Accepted race (documented in ARCHITECTURE): with parallel tool calls, a
// PostToolUse for tool A could delete the still-live pending of tool B in the
// same session. Failure direction is safe — the popup row disappears and the
// user answers in the TUI; a response is never misrouted.
//
// Like every hook here: never break Claude Code — swallow all errors, exit 0.

const fs = require("fs");
const path = require("path");

const PENDING_DIR = path.join(
  process.env.TEMP || path.join(process.env.USERPROFILE, "AppData", "Local", "Temp"),
  "press-1",
  "pending"
);

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  try {
    const data = JSON.parse(input);
    const sid = data.session_id;
    if (sid) {
      for (const f of fs.readdirSync(PENDING_DIR)) {
        if (!f.endsWith(".json")) continue;
        const full = path.join(PENDING_DIR, f);
        try {
          const entry = JSON.parse(fs.readFileSync(full, "utf8"));
          if (entry.session_id === sid) fs.unlinkSync(full);
        } catch {}
      }
    }
  } catch {}
  process.exit(0);
});
