// Offline tests for Codex needs-user attention detection. All runtime files are
// isolated under %TEMP%\press-1-tests; live Codex config is never touched.
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "codex-attention.js");
const { LEGACY_MARKER, BLOCKER_CONTEXT, classifyHost, strictTextCandidate,
  exactTextBlocker, popupText, questionSummary } = require(SCRIPT);
const ROOT = path.join(os.tmpdir(), "press-1-tests", "codex-attention");
const TEMP = path.join(ROOT, "temp");
const PROFILE = path.join(ROOT, "profile");
const PENDING = path.join(TEMP, "press-1", "pending");
const SHADOW = path.join(TEMP, "press-1", "attention-shadow.jsonl");
const TRANSCRIPT = path.join(ROOT, "rollout.jsonl");
fs.rmSync(ROOT, { recursive: true, force: true });
fs.mkdirSync(TEMP, { recursive: true });
fs.mkdirSync(PROFILE, { recursive: true });
fs.writeFileSync(TRANSCRIPT, "");

let pass = 0, fail = 0;
function check(name, condition, extra = "") {
  if (condition) pass++; else fail++;
  console.log(`${condition ? "PASS" : "FAIL"}  ${name}${!condition && extra ? ` — ${extra}` : ""}`);
}
const env = {
  ...process.env, TEMP, TMP: TEMP, USERPROFILE: PROFILE, VSCODE_PID: "4242",
  TERM_PROGRAM: "", WT_SESSION: "", PRESS1_NO_SOUND: "1",
  PRESS1_ATTENTION_POLL_MS: "50", PRESS1_ATTENTION_DEBOUNCE_MS: "150",
  PRESS1_ATTENTION_WATCH_MAX_MS: "5000", PRESS1_ATTENTION_SHADOW_PATH: SHADOW,
};
function runHook(payload) {
  return spawnSync(process.execPath, [SCRIPT], { input: JSON.stringify(payload),
    env, encoding: "utf8", timeout: 5000 });
}
function append(payload, type = "response_item") {
  fs.appendFileSync(TRANSCRIPT, JSON.stringify({ timestamp: new Date().toISOString(), type, payload }) + "\n");
}
function clearPending() {
  fs.rmSync(PENDING, { recursive: true, force: true });
  fs.mkdirSync(PENDING, { recursive: true });
}
function pendingEntries() {
  try {
    return fs.readdirSync(PENDING).filter((f) => f.endsWith(".json")).map((f) => ({
      file: path.join(PENDING, f),
      value: JSON.parse(fs.readFileSync(path.join(PENDING, f), "utf8")),
    }));
  } catch { return []; }
}
async function waitFor(predicate, timeout = 3000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return predicate();
}

(async () => {
  console.log("T1: pure classifier and question formatting");
  check("T1 extension host", classifyHost({ VSCODE_PID: "1" }) === "vscode-extension");
  check("T1 editor terminal beats WT", classifyHost({ TERM_PROGRAM: "vscode", WT_SESSION: "x" }) === "vscode-terminal");
  check("T1 strict RU blocker", strictTextCandidate("Нужен ваш выбор:\n1. Продолжить\n2. Остановить\nОтветьте номером."));
  check("T1 optional question ignored", !strictTextCandidate("Хотите, я ещё добавлю тесты?"));
  check("T1 GSD numbered blocker exact", exactTextBlocker("Исследовать перед планированием?\n1. Сначала исследовать\n2. Пропустить\nОтветь номером: 1 или 2."));
  check("T1 free-text blocker exact", exactTextBlocker("Нужен путь к проекту.\nЖду вашего ответа."));
  check("T1 optional numbered prose ignored", !exactTextBlocker("Можно сделать так:\n1. Быстро\n2. Надёжно"));
  const summary = questionSummary(JSON.stringify({ questions: [{ question: "Как поступить?", options: [{ label: "Да" }, { label: "Нет" }] }] }));
  check("T1 question and options preserved", summary.full === "Как поступить?\n1. Да\n2. Нет", summary.full);
  const decorated = "┌──────────────────────────┐\n│ CHECKPOINT: Verification │\n└──────────────────────────┘\n\nПлан **05.3-01**, коммит `a1b2c3d`.";
  check("T1 popup text removes terminal frame and Markdown", popupText(decorated)
    === "CHECKPOINT: Verification\n\nПлан 05.3-01, коммит a1b2c3d.", popupText(decorated));

  console.log("T2: unmatched request_user_input becomes exact attention");
  clearPending();
  const turn2 = "turn-exact";
  let r = runHook({ hook_event_name: "UserPromptSubmit", session_id: "s2", turn_id: turn2,
    transcript_path: TRANSCRIPT, cwd: "D:/dev/project-two", prompt: "plan it" });
  let out;
  try { out = JSON.parse(r.stdout); } catch {}
  check("T2 hook exits 0", r.status === 0, r.stderr);
  check("T2 valid blocker context without visible marker", out?.hookSpecificOutput?.hookEventName === "UserPromptSubmit"
    && out.hookSpecificOutput.additionalContext === BLOCKER_CONTEXT
    && !out.hookSpecificOutput.additionalContext.includes("press-1:needs-user"), r.stdout);
  // Real rollouts can contain multi-megabyte image/tool records. The watcher must
  // discard an oversized non-target line and keep following the active turn.
  fs.appendFileSync(TRANSCRIPT, JSON.stringify({ timestamp: new Date().toISOString(), type: "response_item",
    payload: { type: "message", role: "assistant", content: "x".repeat(4 * 1024 * 1024 + 1024) } }) + "\n");
  append({ type: "function_call", name: "request_user_input", call_id: "call_exact",
    arguments: JSON.stringify({ questions: [{ question: "Choose one", options: [{ label: "A" }, { label: "B" }] }] }),
    internal_chat_message_metadata_passthrough: { turn_id: turn2 } });
  let rows = await waitFor(() => pendingEntries().length && pendingEntries());
  check("T2 exact attention published", rows.length === 1 && rows[0].value.kind === "attention"
    && rows[0].value.attention_source === "request_user_input", JSON.stringify(rows));
  check("T2 popup payload carries question", rows[0]?.value.tool_input_full.includes("Choose one"));
  append({ type: "function_call_output", call_id: "call_exact", output: "{}",
    internal_chat_message_metadata_passthrough: { turn_id: turn2 } });
  check("T2 answer removes attention", await waitFor(() => pendingEntries().length === 0));
  append({ type: "task_complete", turn_id: turn2 }, "event_msg");

  console.log("T3: quick Default-mode rejection is debounced and silent");
  clearPending();
  const turn3 = "turn-rejected";
  runHook({ hook_event_name: "UserPromptSubmit", session_id: "s3", turn_id: turn3,
    transcript_path: TRANSCRIPT, cwd: "D:/dev/project-three", prompt: "do it" });
  append({ type: "function_call", name: "request_user_input", call_id: "call_rejected", arguments: "{}",
    internal_chat_message_metadata_passthrough: { turn_id: turn3 } });
  append({ type: "function_call_output", call_id: "call_rejected",
    output: "request_user_input is unavailable in Default mode",
    internal_chat_message_metadata_passthrough: { turn_id: turn3 } });
  await new Promise((resolve) => setTimeout(resolve, 400));
  check("T3 no pending and no false alert", pendingEntries().length === 0);
  append({ type: "task_complete", turn_id: turn3 }, "event_msg");

  console.log("T4: exact text contract is live; broader heuristic remains shadow-only");
  clearPending();
  const framedBlocker = "┌──────────────────────────────────────┐\n│ CHECKPOINT: Verification Required    │\n└──────────────────────────────────────┘\n\nПлан **05.3-01**, коммит `a1b2c3d`.\n\n1. **Approved** — продолжить.\n2. Есть замечания — опишите их текстом.\n\nОтветьте номером.";
  r = runHook({ hook_event_name: "Stop", session_id: "s4", turn_id: "turn-marker",
    cwd: "D:/dev/project-four",
    last_assistant_message: framedBlocker });
  check("T4 Stop returns valid JSON", r.status === 0 && r.stdout === "{}", `${r.stdout} ${r.stderr}`);
  rows = pendingEntries();
  check("T4 exact blocker creates live attention", rows.length === 1 && rows[0].value.attention_source === "text_contract");
  check("T4 card contains no machine marker", !rows[0]?.value.tool_input_full.includes("press-1:needs-user"));
  check("T4 card has clean heading and plain Markdown", rows[0]?.value.tool_input_full.startsWith("CHECKPOINT: Verification Required")
    && rows[0].value.tool_input_full.includes("План 05.3-01, коммит a1b2c3d.")
    && !/[┌┐└┘`]|\*\*/.test(rows[0].value.tool_input_full), rows[0]?.value.tool_input_full);
  clearPending();
  fs.rmSync(SHADOW, { force: true });
  runHook({ hook_event_name: "Stop", session_id: "s5", turn_id: "turn-shadow",
    cwd: "D:/dev/project-five",
    last_assistant_message: "Нужен ваш выбор:\n1. Продолжить\n2. Отменить" });
  check("T4 heuristic remains shadow-only", pendingEntries().length === 0);
  const shadow = fs.existsSync(SHADOW) ? fs.readFileSync(SHADOW, "utf8") : "";
  check("T4 shadow candidate logged", shadow.includes("strict_text_candidate"), shadow);

  console.log("T5: next UserPromptSubmit owns attention cleanup");
  runHook({ hook_event_name: "Stop", session_id: "s6", turn_id: "turn-old",
    cwd: "D:/dev/project-six", last_assistant_message: "Нужны детали.\nЖду вашего ответа." });
  check("T5 setup attention exists", pendingEntries().length === 1);
  runHook({ hook_event_name: "UserPromptSubmit", session_id: "s6", turn_id: "turn-new",
    transcript_path: TRANSCRIPT, cwd: "D:/dev/project-six", prompt: "answer" });
  check("T5 user answer clears old attention", pendingEntries().length === 0);
  append({ type: "task_complete", turn_id: "turn-new" }, "event_msg");

  console.log("T6: legacy visible marker remains cleanable during rollout transition");
  clearPending();
  runHook({ hook_event_name: "Stop", session_id: "s7", turn_id: "turn-legacy",
    cwd: "D:/dev/project-seven", last_assistant_message: `Legacy blocker. ${LEGACY_MARKER}` });
  rows = pendingEntries();
  check("T6 legacy marker still creates attention", rows.length === 1
    && rows[0].value.attention_source === "legacy_marker");
  check("T6 legacy marker stripped from card", !rows[0]?.value.tool_input_full.includes(LEGACY_MARKER));

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})().catch((error) => { console.error(error); process.exitCode = 1; });
