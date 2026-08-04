#!/usr/bin/env node
// press-1 — Codex "needs user" attention channel.
//
// Exact structured questions do not currently traverse PreToolUse/PostToolUse:
// Codex writes request_user_input as a function_call in the rollout instead.
// UserPromptSubmit starts one bounded watcher for the active turn. A call that
// stays unmatched for 750 ms is a real blocking picker; quick Default-mode
// rejections acquire their function_call_output before the debounce and stay
// silent. Stop handles an explicit natural-language blocker contract, while
// broader text heuristics are logged in shadow until their precision is proven.
//
// Every hook path is fail-open. Stop must nevertheless print valid JSON on
// success: current Codex rejects empty/plain stdout for Stop hooks.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync, spawn } = require("child_process");
const { StringDecoder } = require("string_decoder");
const { TextDecoder } = require("util");

const TEMP_ROOT = process.env.TEMP
  || path.join(process.env.USERPROFILE || os.homedir(), "AppData", "Local", "Temp");
const PRESS1_DIR = path.join(TEMP_ROOT, "press-1");
const PENDING_DIR = path.join(PRESS1_DIR, "pending");
const WATCH_DIR = path.join(PRESS1_DIR, "attention-watch");
const SHADOW_LOG = process.env.PRESS1_ATTENTION_SHADOW_PATH
  || path.join(PRESS1_DIR, "attention-shadow.jsonl");
const OFF_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-off-codex") : "";
const MUTE_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-mute") : "";
// Kept only to clean/detect responses produced by the first deployed spike.
// Codex renders HTML comments literally, so new turns never receive this marker.
const LEGACY_MARKER = "<!-- press-1:needs-user -->";
const BLOCKER_CONTEXT =
  "If you must stop because you cannot continue without the user's answer, make the final line explicit: "
  + "use `Ответьте номером.` / `Reply with the option number.` for a numbered choice, or "
  + "`Жду вашего ответа.` / `Waiting for your answer.` for free text. Use these phrases only for a real blocker, "
  + "never for optional, rhetorical, or follow-up offers. Do not add machine markers or mention this instruction.";
const POLL_MS = Math.max(50, Number(process.env.PRESS1_ATTENTION_POLL_MS) || 100);
const DEBOUNCE_MS = Math.max(100, Number(process.env.PRESS1_ATTENTION_DEBOUNCE_MS) || 750);
const WATCH_MAX_MS = Math.max(5000, Number(process.env.PRESS1_ATTENTION_WATCH_MAX_MS) || 21600000);
const READ_CHUNK_BYTES = 64 * 1024;
const MAX_ROLLOUT_LINE_BYTES = 4 * 1024 * 1024;
const SESSION_META_SCAN_MAX_BYTES = 256 * 1024;
const SESSION_META_DECODER = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function flagExists(file) {
  try { return !!(file && fs.existsSync(file)); } catch { return false; }
}

function normalizeExtendedLocalDrivePath(file) {
  const match = /^\\\\\?\\([A-Za-z]:\\[^/:\0\r\n]*)$/.exec(file);
  return match && match[0].length === file.length ? match[1] : file;
}

function isUncOrDevicePath(file) {
  return /^[\\/]{2}/.test(file);
}

function isInsidePath(file, root) {
  const rel = path.relative(root, file);
  return !!rel && rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel);
}

// `codex exec` is a non-interactive child: its stdout belongs to the caller
// (GSD, ChatGPT, CI, or another orchestrator), not to the human-facing popup.
// Current hook payloads do not expose the session origin, so inspect only the
// bounded session_meta prefix of a canonical local rollout. Any missing field,
// unsafe path, malformed record, or I/O failure keeps the normal alert route.
function isNonInteractiveExec(data) {
  try {
    if (!data || typeof data.transcript_path !== "string" || !data.transcript_path) return false;
    const transcript = normalizeExtendedLocalDrivePath(data.transcript_path);
    if (!path.isAbsolute(transcript) || isUncOrDevicePath(transcript)
      || path.extname(transcript).toLowerCase() !== ".jsonl") return false;

    const codexHome = normalizeExtendedLocalDrivePath(
      process.env.CODEX_HOME || path.join(process.env.USERPROFILE || os.homedir(), ".codex")
    );
    const sessionsRoot = path.join(codexHome, "sessions");
    if (!path.isAbsolute(sessionsRoot) || isUncOrDevicePath(sessionsRoot)
      || !isInsidePath(path.resolve(transcript), path.resolve(sessionsRoot))) return false;

    const realRoot = fs.realpathSync(sessionsRoot);
    const realTranscript = fs.realpathSync(transcript);
    if (isUncOrDevicePath(realTranscript)
      || path.extname(realTranscript).toLowerCase() !== ".jsonl"
      || !isInsidePath(realTranscript, realRoot)) return false;

    const fd = fs.openSync(realTranscript, "r");
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile()) return false;
      const readLength = Math.min(stat.size, SESSION_META_SCAN_MAX_BYTES);
      const buffer = Buffer.allocUnsafe(readLength);
      let offset = 0;
      while (offset < readLength) {
        const count = fs.readSync(fd, buffer, offset, readLength - offset, offset);
        if (!count) break;
        offset += count;
      }
      if (offset !== readLength) return false;
      const complete = stat.size <= readLength ? buffer
        : buffer.subarray(0, Math.max(0, buffer.lastIndexOf(0x0a) + 1));
      if (!complete.length) return false;
      for (const line of SESSION_META_DECODER.decode(complete).split(/\r?\n/)) {
        if (!line) continue;
        let record;
        try { record = JSON.parse(line); } catch { return false; }
        if (record && record.type === "session_meta") {
          const payload = record.payload;
          if (!payload || typeof payload !== "object" || Array.isArray(payload)) return false;
          return payload.originator === "codex_exec" || payload.source === "exec";
        }
      }
      return false;
    } finally { fs.closeSync(fd); }
  } catch { return false; }
}

function classifyHost(env = process.env) {
  if (env.TERM_PROGRAM === "vscode") return "vscode-terminal";
  if (env.WT_SESSION) return "windows-terminal";
  if (env.VSCODE_PID && !env.TERM_PROGRAM && !env.WT_SESSION) return "vscode-extension";
  return "conhost";
}

function baseHost(env = process.env) {
  return {
    type: classifyHost(env),
    entrypoint: "",
    term_program: env.TERM_PROGRAM || "",
    wt_session: env.WT_SESSION || "",
    editor_exe: env.VSCODE_GIT_ASKPASS_NODE
      ? path.basename(env.VSCODE_GIT_ASKPASS_NODE) : "",
    ancestry: [], top_level_pid: 0, top_level_exe: "", hwnd: 0, title: "",
  };
}

// Run only after an attention event is detected, never on every user prompt.
// The watcher receives Codex's long-lived parent PID because its own hook parent
// exits immediately after spawning it.
function hydrateStandaloneHost(host, startPid) {
  if (host.type !== "windows-terminal" && host.type !== "conhost") return host;
  try {
    const ps = [
      "$m=@{}",
      "Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name | ForEach-Object { $m[[int]$_.ProcessId] = @([int]$_.ParentProcessId, $_.Name) }",
      "$stop=@('explorer.exe','services.exe','svchost.exe','wininit.exe','winlogon.exe')",
      "$p=[int]$env:PRESS1_WALK_PID", "$out=@()",
      "for($i=0; $i -lt 12 -and $m.ContainsKey($p); $i++){ $e=$m[$p]; if($stop -contains $e[1]){ break }; $out += ('{0}:{1}' -f $p, $e[1]); $p = $e[0] }",
      "$hwnd=0; for($j=$out.Count-1; $j -ge 0 -and $hwnd -eq 0; $j--){ $cp=[int](($out[$j] -split ':')[0]); $gp=Get-Process -Id $cp -ErrorAction SilentlyContinue; if($gp -and $gp.MainWindowHandle -ne 0){ $hwnd=[int64]$gp.MainWindowHandle } }",
      "($out -join '|') + ';' + $hwnd",
    ].join("; ");
    const raw = execSync(
      "powershell -NoProfile -NonInteractive -EncodedCommand "
        + Buffer.from(ps, "utf16le").toString("base64"),
      { timeout: 3000, windowsHide: true,
        env: { ...process.env, PRESS1_WALK_PID: String(startPid || process.ppid) } }
    ).toString().trim();
    const split = raw.lastIndexOf(";");
    if (split < 0) return host;
    const ancestry = raw.slice(0, split).split("|").filter(Boolean).map((item) => {
      const at = item.indexOf(":");
      return { pid: Number(item.slice(0, at)), exe: item.slice(at + 1) };
    }).filter((item) => Number.isInteger(item.pid) && item.pid > 0);
    const top = ancestry[ancestry.length - 1];
    return { ...host, ancestry, top_level_pid: top ? top.pid : 0,
      top_level_exe: top ? top.exe : "", hwnd: Number(raw.slice(split + 1)) || 0 };
  } catch { return host; }
}

function strictTextCandidate(message) {
  const text = String(message || "");
  const blocker = /(?:нуж(?:ен|на|но)\s+(?:ваш(?:е|его|а)?\s+)?(?:выбор|ответ|решение)|без\s+(?:вашего\s+)?(?:ответа|выбора)\s+не\s+(?:могу|получится)\s+продолж|cannot\s+continue\s+without|need\s+your\s+(?:choice|answer|input|decision)|waiting\s+for\s+your\s+(?:answer|input|decision))/iu.test(text);
  const reply = /(?:ответьте|напишите|выберите|укажите|подтвердите|reply|respond|choose|select|type)\b/iu.test(text);
  const options = (text.match(/^\s*(?:\d+[.)]|[A-CА-В][.)])\s+.+$/gimu) || []).length >= 2;
  return blocker && (reply || options);
}

function exactTextBlocker(message) {
  const text = String(message || "");
  const options = (text.match(/^\s*(?:\d+[.)]|[A-CА-В][.)])\s+.+$/gimu) || []).length >= 2;
  const numberedReply = /(?:ответ(?:ь|ьте)|напиши(?:те)?|выбери(?:те)?|укажи(?:те)?)\s+(?:(?:только|одним)\s+)?(?:номер(?:ом)?|цифр(?:у|ой))|(?:reply|respond)\s+with\s+(?:(?:the|one)\s+)?(?:option\s+)?number/iu.test(text);
  const freeTextWait = /(?:^|\n)\s*(?:жду\s+(?:вашего\s+)?ответа|waiting\s+for\s+your\s+answer)\s*[.!]?\s*$/iu.test(text);
  return (options && numberedReply) || freeTextWait;
}

// Popup cards render plain text, so terminal-width decorative frames wrap into
// broken corners. Normalize only the copied display text; Codex's response and
// the blocker classifier always see the original message.
function popupText(message) {
  const lines = String(message || "").replace(/\r\n?/g, "\n").split("\n");
  const output = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*[┌╔╭][─━═]+[┐╗╮]\s*$/.test(lines[i])
      && i + 2 < lines.length
      && /^\s*[│║┃].*[│║┃]\s*$/.test(lines[i + 1])
      && /^\s*[└╚╰][─━═]+[┘╝╯]\s*$/.test(lines[i + 2])) {
      output.push(lines[i + 1].replace(/^\s*[│║┃]\s*/, "")
        .replace(/\s*[│║┃]\s*$/, "").trim());
      i += 2;
      continue;
    }
    output.push(lines[i]);
  }
  return output.join("\n")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/\*\*([^*\n]+)\*\*/g, "$1")
    .replace(/__([^_\n]+)__/g, "$1")
    .replace(/`([^`\n]+)`/g, "$1")
    .trim();
}

function questionSummary(rawArguments) {
  let args = rawArguments;
  try { if (typeof args === "string") args = JSON.parse(args); } catch { args = {}; }
  const questions = Array.isArray(args && args.questions) ? args.questions : [];
  const parts = [];
  for (const q of questions.slice(0, 3)) {
    const prompt = String(q && q.question || "").trim();
    if (!prompt) continue;
    const labels = Array.isArray(q.options)
      ? q.options.slice(0, 4).map((o) => String(o && o.label || "").trim()).filter(Boolean) : [];
    parts.push(prompt + (labels.length ? "\n" + labels.map((v, i) => `${i + 1}. ${v}`).join("\n") : ""));
  }
  const full = popupText(parts.join("\n\n") || "Codex needs your input");
  return { short: full.replace(/\s+/g, " ").trim().slice(0, 400), full: full.slice(0, 3000) };
}

function writeAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

function attentionFilesForSession(sessionId) {
  try {
    return fs.readdirSync(PENDING_DIR).filter((name) => name.endsWith(".json")).map((name) => {
      const file = path.join(PENDING_DIR, name);
      try { return { file, entry: JSON.parse(fs.readFileSync(file, "utf8")) }; }
      catch { return null; }
    }).filter((item) => item && item.entry.kind === "attention"
      && (!sessionId || item.entry.session_id === sessionId));
  } catch { return []; }
}

function cleanupAttention(sessionId) {
  for (const item of attentionFilesForSession(sessionId)) {
    try { fs.unlinkSync(item.file); } catch {}
  }
}

function playSound() {
  if (process.env.PRESS1_NO_SOUND || flagExists(MUTE_FLAG)) return;
  try {
    const wav = String(process.env.PRESS1_SOUND || "ding.wav").replace(/\\/g, "/");
    const expr = /[/:]/.test(wav) ? `'${wav.replace(/'/g, "''")}'`
      : `($env:WINDIR + '/Media/${wav.replace(/'/g, "''")}')`;
    execSync(`powershell -NoProfile -Command "(New-Object Media.SoundPlayer ${expr}).PlaySync()"`,
      { timeout: 4000, stdio: "ignore", windowsHide: true });
  } catch {}
}

function publishAttention(spec, source, summary, callId = "") {
  if (flagExists(OFF_FLAG)) return "";
  fs.mkdirSync(PENDING_DIR, { recursive: true });
  const stable = String(callId || spec.turn_id || Date.now()).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 100);
  const id = `attention-${stable || Date.now()}`;
  const file = path.join(PENDING_DIR, `${id}.json`);
  if (fs.existsSync(file)) return file;
  const host = hydrateStandaloneHost(spec.host || baseHost(), spec.parent_pid);
  const entry = {
    schema: 2, id, agent: "codex", timestamp: Date.now(),
    project_name: path.basename(spec.cwd || process.cwd()), cwd: spec.cwd || process.cwd(),
    session_id: spec.session_id || "", turn_id: spec.turn_id || "", call_id: callId,
    tool_name: "User input", tool_input_short: summary.short, tool_input_full: summary.full,
    kind: "attention", attention_source: source, options: [], host,
  };
  writeAtomic(file, entry);
  playSound();
  return file;
}

function appendShadow(spec, message) {
  try {
    fs.mkdirSync(path.dirname(SHADOW_LOG), { recursive: true });
    fs.appendFileSync(SHADOW_LOG, JSON.stringify({ schema: 1, timestamp: Date.now(),
      session_id: spec.session_id || "", turn_id: spec.turn_id || "",
      classification: "strict_text_candidate", preview: String(message).slice(0, 1500) }) + "\n");
  } catch {}
}

function turnOf(payload) {
  return payload && (payload.turn_id
    || (payload.internal_chat_message_metadata_passthrough
      && payload.internal_chat_message_metadata_passthrough.turn_id)) || "";
}

async function watchTranscript(spec) {
  fs.mkdirSync(WATCH_DIR, { recursive: true });
  const lease = path.join(WATCH_DIR, `${String(spec.turn_id).replace(/[^A-Za-z0-9_-]/g, "")}.lock`);
  let leaseFd;
  try { leaseFd = fs.openSync(lease, "wx"); } catch { return; }
  let offset = Number(spec.offset) || 0;
  let carry = "";
  let decoder = new StringDecoder("utf8");
  let droppingOversizedLine = false;
  const calls = new Map();
  const started = Date.now();
  try {
    while (Date.now() - started < WATCH_MAX_MS) {
      try {
        const size = fs.statSync(spec.transcript_path).size;
        if (size < offset) {
          offset = 0; carry = ""; decoder = new StringDecoder("utf8");
          droppingOversizedLine = false;
        }
        if (size > offset) {
          const fd = fs.openSync(spec.transcript_path, "r");
          const lines = [];
          try {
            while (offset < size) {
              const len = Math.min(READ_CHUNK_BYTES, size - offset);
              const buf = Buffer.allocUnsafe(len);
              const read = fs.readSync(fd, buf, 0, len, offset);
              if (!read) break;
              offset += read;
              const pieces = (carry + decoder.write(buf.subarray(0, read))).split("\n");
              carry = pieces.pop() || "";
              for (let line of pieces) {
                if (droppingOversizedLine) { droppingOversizedLine = false; continue; }
                if (line.endsWith("\r")) line = line.slice(0, -1);
                lines.push(line);
              }
              if (Buffer.byteLength(carry, "utf8") > MAX_ROLLOUT_LINE_BYTES) {
                carry = ""; droppingOversizedLine = true;
              }
            }
          } finally { fs.closeSync(fd); }
          for (const line of lines) {
            let record;
            try { record = JSON.parse(line); } catch { continue; }
            const payload = record && record.payload;
            if (!payload) continue;
            if (record.type === "response_item" && turnOf(payload) === spec.turn_id) {
              if (payload.type === "function_call" && payload.name === "request_user_input" && payload.call_id) {
                calls.set(payload.call_id, { due: Date.now() + DEBOUNCE_MS,
                  args: payload.arguments, pending: "" });
              } else if (payload.type === "function_call_output" && payload.call_id && calls.has(payload.call_id)) {
                const call = calls.get(payload.call_id);
                if (call.pending) try { fs.unlinkSync(call.pending); } catch {}
                calls.delete(payload.call_id);
              }
            }
            if (record.type === "event_msg" && payload.type === "task_complete"
              && payload.turn_id === spec.turn_id) {
              for (const call of calls.values()) if (call.pending) try { fs.unlinkSync(call.pending); } catch {}
              return;
            }
          }
        }
      } catch {}
      for (const [callId, call] of calls) {
        if (!call.pending && Date.now() >= call.due)
          call.pending = publishAttention(spec, "request_user_input", questionSummary(call.args), callId);
      }
      await new Promise((resolve) => setTimeout(resolve, POLL_MS));
    }
  } finally {
    for (const call of calls.values()) if (call.pending) try { fs.unlinkSync(call.pending); } catch {}
    try { fs.closeSync(leaseFd); } catch {}
    try { fs.unlinkSync(lease); } catch {}
  }
}

function spawnWatcher(data) {
  if (!data.transcript_path || !data.turn_id || flagExists(OFF_FLAG)) return;
  let offset = 0;
  try { offset = fs.statSync(data.transcript_path).size; } catch {}
  const spec = { session_id: data.session_id || "", turn_id: data.turn_id,
    transcript_path: data.transcript_path, cwd: data.cwd || process.cwd(), offset,
    parent_pid: process.ppid, host: baseHost() };
  const encoded = Buffer.from(JSON.stringify(spec)).toString("base64url");
  const child = spawn(process.execPath, [__filename, "--watch", encoded],
    { detached: true, stdio: "ignore", windowsHide: true, env: process.env });
  child.unref();
}

function hookOutput(data) {
  const event = String(data.hook_event_name || "").toLowerCase();
  if (event === "userpromptsubmit") {
    cleanupAttention(data.session_id || "");
    if (isNonInteractiveExec(data)) return {};
    if (!flagExists(OFF_FLAG)) spawnWatcher(data);
    return flagExists(OFF_FLAG) ? {} : { hookSpecificOutput: {
      hookEventName: "UserPromptSubmit", additionalContext: BLOCKER_CONTEXT } };
  }
  if (event === "sessionend") {
    cleanupAttention(data.session_id || "");
    return {};
  }
  if (event === "stop" || (!data.tool_name && Object.prototype.hasOwnProperty.call(data, "last_assistant_message"))) {
    if (isNonInteractiveExec(data)) return {};
    const message = String(data.last_assistant_message || "");
    if (!flagExists(OFF_FLAG) && message.includes(LEGACY_MARKER)) {
      const clean = popupText(message.replaceAll(LEGACY_MARKER, ""));
      publishAttention({ session_id: data.session_id || "", turn_id: data.turn_id || "",
        cwd: data.cwd || process.cwd(), parent_pid: process.ppid, host: baseHost() },
      "legacy_marker", { short: clean.replace(/\s+/g, " ").slice(0, 400), full: clean.slice(0, 3000) });
    } else if (!flagExists(OFF_FLAG) && exactTextBlocker(message)) {
      const clean = popupText(message);
      publishAttention({ session_id: data.session_id || "", turn_id: data.turn_id || "",
        cwd: data.cwd || process.cwd(), parent_pid: process.ppid, host: baseHost() },
      "text_contract", { short: clean.replace(/\s+/g, " ").slice(0, 400), full: clean.slice(0, 3000) });
    } else if (!flagExists(OFF_FLAG) && strictTextCandidate(message)) {
      appendShadow(data, message);
    }
    return {};
  }
  return {};
}

function runHook() {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    let output = {};
    try { output = hookOutput(JSON.parse(input)); } catch {}
    process.stdout.write(JSON.stringify(output));
  });
}

if (require.main === module) {
  if (process.argv[2] === "--watch") {
    try { watchTranscript(JSON.parse(Buffer.from(process.argv[3], "base64url").toString("utf8"))); }
    catch {}
  } else runHook();
}

module.exports = { LEGACY_MARKER, BLOCKER_CONTEXT, classifyHost, strictTextCandidate,
  exactTextBlocker, popupText, questionSummary, isNonInteractiveExec, hookOutput, watchTranscript };
