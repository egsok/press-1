const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const PERM_DIR = path.join(
  process.env.TEMP || path.join(process.env.USERPROFILE, "AppData", "Local", "Temp"),
  "press-1"
);
const PENDING_DIR = path.join(PERM_DIR, "pending");

// Notification sound. A filename resolves under %WINDIR%\Media; a value with a
// path separator is used as-is. Override with PRESS1_SOUND=<file|path>, or mute
// with PRESS1_NO_SOUND=1. Other soft built-ins: "chimes.wav", "Windows Notify.wav",
// "Windows Background.wav" (subtlest), "Windows Notify Messaging.wav".
const SOUND_WAV = process.env.PRESS1_SOUND || "ding.wav";

// Persistent mute flag, toggled from the AHK tray ("Mute prompt sound"): the tray
// writes/removes ~/.press-1-mute, the hook checks it before playing. Guarded
// against a missing USERPROFILE — an unconditional path.join(undefined, ...) would
// throw, and the hook otherwise needs USERPROFILE only as a TEMP fallback, so keep
// it optional: a no-USERPROFILE env must never break sound delivery.
const MUTE_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-mute")
  : "";

// All editor terminals (B), standalone terminals (A), and the extension panel
// (C): how long the hook blocks waiting for an AHK decision before passing
// through to the TUI/native box. The popup row lives exactly this long (AHK
// reads wait_until from the pending), and waiting is free for the user — Claude
// Code races the hook against the UI, so answering in the window always wins
// instantly. 60 min covers "stepped away for a while"; teardown/liveness
// early-exit (see waitForDecision) keeps no zombie hooks alive past the actual
// answer. Two hard constraints: settings.json per-hook timeout must EXCEED this
// (3660 s > 3600 s — smaller silently drops late decisions, see DEVLOG "timeout
// trap"), and AHK's STANDALONE_BACKSTOP_MS pending sweep must stay above it.
const DECISION_WAIT_MS = parseInt(process.env.PRESS1_DECISION_WAIT_MS, 10) || 3600000;
const POLL_MS = 100;

// Hosts whose permission prompts are answered via the hook-decision channel.
// S8 proved it for the panel, S10 for terminal TUIs — Promise.race(hook↔UI)
// is core Claude Code behavior, not a host feature, so ONE channel answers all
// of them. vscode-terminal joined the set when the companion extension was
// dropped: the proposed scrape API it relied on is blocked for sideloaded
// extensions in the VS Code forks (Cursor/Windsurf-Devin), so every editor
// terminal — real VS Code and the forks alike, all classified vscode-terminal —
// now rides the decision channel instead of the extension's response-file path.
const DECISION_HOSTS = new Set([
  "vscode-terminal",
  "vscode-extension",
  "windows-terminal",
  "conhost",
]);

// Tools whose panel UI is a multi-option picker, not an allow/deny box —
// a hook decision can't answer them (S8 covers kind=permission only).
const NO_DECISION_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

// Host fingerprint from env (schema v2). CHECK ORDER IS LOAD-BEARING:
// - CLAUDE_CODE_ENTRYPOINT is set by claude itself per launch path, so it
//   beats inherited terminal vars ("claude-vscode" = extension panel even if
//   the env还 carries stale TERM_PROGRAM/WT_SESSION from how VS Code started).
// - TERM_PROGRAM=vscode beats WT_SESSION: a VS Code launched FROM Windows
//   Terminal leaks WT_SESSION into its integrated terminals.
function classifyHost(env) {
  if (env.CLAUDE_CODE_ENTRYPOINT === "claude-vscode") return "vscode-extension";
  if (env.TERM_PROGRAM === "vscode") return "vscode-terminal";
  if (env.WT_SESSION) return "windows-terminal";
  if (env.CLAUDE_CODE_ENTRYPOINT === "cli") return "conhost";
  return "unknown";
}

// Ancestry walk (S2): one CIM snapshot (~300ms) + in-memory walk, PowerShell
// startup dominates (~0.7s, total ~1.0-1.2s). Must run synchronously WHILE the
// hook is alive — the bash/cmd wrappers between node and claude.exe die the
// moment the hook exits, breaking the chain. Returns null on any failure.
function walkAncestry() {
  const ps = [
    "$m=@{}",
    "Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name | ForEach-Object { $m[[int]$_.ProcessId] = @([int]$_.ParentProcessId, $_.Name) }",
    "$stop=@('explorer.exe','services.exe','svchost.exe','wininit.exe','winlogon.exe')",
    "$p=[int]$env:PRESS1_WALK_PID",
    "$out=@()",
    "for($i=0; $i -lt 12 -and $m.ContainsKey($p); $i++){ $e=$m[$p]; if($stop -contains $e[1]){ break }; $out += ('{0}:{1}' -f $p, $e[1]); $p = $e[0] }",
    // Window handle: scan the chain TOP-DOWN and take the first process that
    // owns a window. The top alone is blind for conhost — Win32 attributes the
    // ConsoleWindowClass window to the CLIENT process (cmd.exe), so
    // conhost.exe's MainWindowHandle is 0 (confirmed live 2026-06-12).
    "$hwnd=0; for($j=$out.Count-1; $j -ge 0 -and $hwnd -eq 0; $j--){ $cp=[int](($out[$j] -split ':')[0]); $gp=Get-Process -Id $cp -ErrorAction SilentlyContinue; if($gp -and $gp.MainWindowHandle -ne 0){ $hwnd=[int64]$gp.MainWindowHandle } }",
    "($out -join '|') + ';' + $hwnd",
  ].join("; ");
  const b64 = Buffer.from(ps, "utf16le").toString("base64");
  const raw = execSync(
    "powershell -NoProfile -NonInteractive -EncodedCommand " + b64,
    {
      timeout: 3000,
      windowsHide: true,
      env: Object.assign({}, process.env, { PRESS1_WALK_PID: String(process.pid) }),
    }
  ).toString().trim();

  // Format: "<ancestry>;<hwnd>". A third ";title" segment existed briefly in
  // v5.2 and is parsed leniently for compat — but the capture itself is dead:
  // hooks run in their OWN hidden console (claude spawns the wrapper with
  // CREATE_NO_WINDOW), so [Console]::Title only ever saw the wrapper's spawn
  // title ("...cmd.exe"), never the claude tab title (both smokes 2026-06-12).
  const i1 = raw.indexOf(";");
  if (i1 === -1) return null;
  const i2 = raw.indexOf(";", i1 + 1);
  const ancestry = raw
    .slice(0, i1)
    .split("|")
    .filter(Boolean)
    .map((s) => {
      const i = s.indexOf(":");
      return { pid: parseInt(s.slice(0, i), 10), exe: s.slice(i + 1) };
    })
    .filter((a) => !isNaN(a.pid));
  if (ancestry.length === 0) return null;
  const top = ancestry[ancestry.length - 1];
  const hwndRaw = i2 === -1 ? raw.slice(i1 + 1) : raw.slice(i1 + 1, i2);
  return {
    ancestry,
    top_level_pid: top.pid,
    top_level_exe: top.exe,
    hwnd: parseInt(hwndRaw, 10) || 0,
    // Reserved (schema stability): title capture removed — see format note.
    title: "",
  };
}

function buildHost() {
  const env = process.env;
  const host = {
    type: classifyHost(env),
    entrypoint: env.CLAUDE_CODE_ENTRYPOINT || "",
    term_program: env.TERM_PROGRAM || "",
    wt_session: env.WT_SESSION || "",
    // Basename of the editor's Electron binary (Code.exe / Cursor.exe /
    // Devin.exe), read from VSCODE_GIT_ASKPASS_NODE — present only for an
    // integrated-terminal host. Lets AHK focus the RIGHT editor for a
    // vscode-terminal picker (a Cursor prompt focuses Cursor, not a VS Code
    // window that happens to share the project name). Empty off-editor.
    editor_exe: env.VSCODE_GIT_ASKPASS_NODE
      ? path.basename(env.VSCODE_GIT_ASKPASS_NODE)
      : "",
    ancestry: [],
    top_level_pid: 0,
    top_level_exe: "",
    hwnd: 0,
    title: "",
    walk_ms: 0,
  };

  // Gated walk: ancestry is only consumed for standalone terminals (scenario
  // A: the AHK liveness gate and the focus button need the top-level
  // window/PID; delivery itself is the decision channel since v5.4). VS Code
  // hosts skip it — the decision channel needs no window, and editor pickers
  // focus by editor_exe + title, not ancestry — so daily prompts stay instant
  // (~1.1s saved).
  if (host.type === "windows-terminal" || host.type === "conhost") {
    const t0 = Date.now();
    try {
      const w = walkAncestry();
      if (w) Object.assign(host, w);
    } catch {}
    host.walk_ms = Date.now() - t0;
  }
  return host;
}

// Synchronous bounded wait for the AHK-written decision word. The hook MUST
// stay alive while waiting — its exit is what releases Claude Code to show
// the native box, so the wait is a plain blocking poll, not a timer.
// Early-exit: the pending file is the hook's own lease on "still answerable" —
// the teardown hook (answered in TUI/box) and the AHK liveness gate (terminal
// window died) delete it, and a 15-min wait must not outlive the answer.
// Decision is checked FIRST so a decision written in the same tick as a
// teardown still wins (the safe direction: it was a real user answer).
function waitForDecision(file, pendingPath, waitMs) {
  const deadline = Date.now() + waitMs;
  const lock = new Int32Array(new SharedArrayBuffer(4));
  for (;;) {
    try {
      return fs.readFileSync(file, "utf8").trim().toLowerCase();
    } catch {}
    if (!fs.existsSync(pendingPath)) return "";
    if (Date.now() >= deadline) return "";
    Atomics.wait(lock, 0, 0, POLL_MS);
  }
}

// Block while a picker's pending file exists (or until the window elapses). A
// picker (AskUserQuestion / ExitPlanMode) carries no decision channel — the hook
// can't answer the question — so it stays alive as a LIVENESS BEACON: while we
// live, the question is open; when we die, it's resolved. teardown deletes our
// pending on ANSWER (this loop notices and returns), and Claude Code kills us
// outright on CANCEL (which fires no PostToolUse/Stop — proven 2026-06-14), so
// the pending is orphaned with our dead hook_pid and AHK drops the row.
function waitForPendingGone(pendingPath, waitMs) {
  const deadline = Date.now() + waitMs;
  const lock = new Int32Array(new SharedArrayBuffer(4));
  while (fs.existsSync(pendingPath)) {
    if (Date.now() >= deadline) return;
    Atomics.wait(lock, 0, 0, POLL_MS);
  }
}

// Map the decision word to hook stdout JSON (schema verified against the
// installed 2.1.173 bundle):
//   allow  → {behavior:"allow"}
//   always → allow + updatedPermissions = the payload's permission_suggestions
//            (the exact rules the native "Always allow" button would persist;
//            same PermissionUpdate type on both sides, echo is lossless)
//   deny   → {behavior:"deny", message}
//   pass / unknown / timeout → null = no output, native box takes over
function decisionToOutput(word, data) {
  if (word === "allow" || word === "always") {
    const decision = { behavior: "allow" };
    if (
      word === "always" &&
      Array.isArray(data.permission_suggestions) &&
      data.permission_suggestions.length > 0
    ) {
      decision.updatedPermissions = data.permission_suggestions;
    }
    return {
      hookSpecificOutput: { hookEventName: "PermissionRequest", decision },
    };
  }
  if (word === "deny") {
    return {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: {
          behavior: "deny",
          message: "Denied by user via press-1 hotkey",
        },
      },
    };
  }
  return null;
}

// Orphaned decision files appear only on a lost race (AHK wrote the word the
// instant the hook timed out). Sweep old ones so they never answer a future
// prompt by accident.
function cleanupStaleDecisionFiles() {
  try {
    for (const f of fs.readdirSync(PERM_DIR)) {
      if (!/^response-hook-.*\.txt$/.test(f)) continue;
      const full = path.join(PERM_DIR, f);
      try {
        if (Date.now() - fs.statSync(full).mtimeMs > 5 * 60 * 1000) {
          fs.unlinkSync(full);
        }
      } catch {}
    }
  } catch {}
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  try {
    const data = JSON.parse(input);
    fs.mkdirSync(PENDING_DIR, { recursive: true });

    const id = Date.now() + "-" + Math.random().toString(36).slice(2, 8);

    // Collapse whitespace (incl. embedded newlines in multi-line commands) to a
    // single space BEFORE truncating — keeps tool_input_short a one-line summary
    // (a literal newline would render extra lines in the popup card).
    const oneLine = (s) => String(s).replace(/\s+/g, " ").trim();
    const cwd = data.cwd || process.cwd();
    const projectName = path.basename(cwd);
    const ti = data.tool_input;

    // Human-readable one-line summary of the tool call for the popup card.
    // The native permission box reads like "Allow write to <path>?" — we mirror
    // that intent: pull the ONE meaningful field per tool (a path, a command, a
    // query) rather than dumping raw {"file_path":...,"content":...} JSON, which
    // is unreadable and truncates mid-value. Paths show project-relative when
    // inside the workspace. Unknown tools fall back to the first readable field,
    // then to JSON, so something always shows.
    const relPath = (p) => {
      if (typeof p !== "string" || !p) return "";
      const c = String(cwd).replace(/[\\/]+$/, "");
      if (c && p.toLowerCase().startsWith(c.toLowerCase())) {
        const rest = p.slice(c.length).replace(/^[\\/]+/, "");
        if (rest) return rest;
      }
      return p;
    };
    const summarize = () => {
      if (!ti || typeof ti !== "object")
        return ti === undefined ? "" : String(ti);
      switch (data.tool_name) {
        case "Bash":
          return ti.command || "";
        case "Write":
        case "Edit":
        case "MultiEdit":
        case "Read":
          return relPath(ti.file_path);
        case "NotebookEdit":
          return relPath(ti.notebook_path || ti.file_path);
        case "Glob":
        case "Grep":
          return (ti.pattern || "") + (ti.path ? " in " + relPath(ti.path) : "");
        case "WebFetch":
          return ti.url || "";
        case "WebSearch":
          return ti.query || "";
        case "Task":
          return ti.description || ti.subagent_type || "";
        case "AskUserQuestion": {
          const q =
            Array.isArray(ti.questions) && ti.questions[0] ? ti.questions[0] : null;
          return q ? q.question || q.header || "" : ti.question || ti.header || "";
        }
        case "ExitPlanMode":
          // The plan lives in a file, not tool_input (tool_input is just
          // {allowedPrompts}). Without this case the unknown-tool loop below
          // misses it (allowedPrompts is an array) and dumps raw JSON into the
          // popup. ti.plan is kept as a priority for CC versions that do pass
          // the plan text; otherwise a clean static label. When the plan text
          // is present, strip leading Markdown heading markers (#, ##, …) so
          // the popup shows readable prose, not raw "## Context" syntax.
          if (typeof ti.plan === "string" && ti.plan)
            return ti.plan.replace(/^#{1,6}\s+/gm, "");
          return "Plan ready for review";
      }
      // Unknown tool: prefer a readable field before raw JSON (last resort).
      for (const k of ["file_path", "path", "command", "url", "query", "pattern", "prompt", "description"]) {
        if (typeof ti[k] === "string" && ti[k])
          return k.endsWith("path") ? relPath(ti[k]) : ti[k];
      }
      return JSON.stringify(ti);
    };
    // Cap generously (not tight): the popup card clips to ~2 lines and adds its
    // own "…", so it must receive enough text to fill those lines and truncate
    // visibly at the real width — an 80-char cap cut long questions mid-thought
    // with no ellipsis (looked arbitrary). 200 is plenty for two lines.
    const toolInputShort = oneLine(summarize()).slice(0, 200);

    const kind = NO_DECISION_TOOLS.has(data.tool_name) ? "picker" : "permission";

    // Scenario A digit semantics: on a 2-option TUI prompt digit 2 means Deny,
    // on a 3-option one it means Always allow — the popup buttons must mirror
    // the real layout or a hotkey misroutes. permission_suggestions IS the rule
    // the TUI's 3rd option ("don't ask again") would persist, so its presence
    // implies the 3-option layout. AHK falls back to the 3-option layout when
    // this field is missing — there the worst mistake is Deny instead of
    // Always allow (safe direction), never the reverse.
    const hasSuggestions =
      Array.isArray(data.permission_suggestions) &&
      data.permission_suggestions.length > 0;

    const entry = {
      schema: 2,
      id,
      agent: "claude",
      timestamp: Date.now(),
      project_name: projectName,
      cwd,
      session_id: data.session_id || "",
      tool_name: data.tool_name || "",
      tool_input_short: toolInputShort,
      kind,
      options:
        kind === "permission"
          ? hasSuggestions
            ? ["Allow", "Always allow", "Deny"]
            : ["Allow", "Deny"]
          : [],
      claude_pid: process.ppid,
      // Liveness anchor for decision rows: this hook process IS the decision
      // channel, and it deletes its pending on every graceful exit — so a
      // pending whose hook is dead means CC killed the losing hook when the
      // user answered in the UI (seen live 2026-06-12). AHK drops such
      // orphans (row + file) instead of ghosting until wait_until.
      hook_pid: process.pid,
      host: buildHost(),
    };

    // Scenarios A + C: permission prompts on decision-capable hosts are
    // answered via hook decision (S8/S10). Declare the channel in the pending
    // so AHK knows where to write; wait_until lets AHK drop the row the
    // moment the hook gives up.
    const decisionWait =
      DECISION_HOSTS.has(entry.host.type) && kind === "permission";
    if (decisionWait) {
      entry.decision_file = path.join(PERM_DIR, "response-hook-" + id + ".txt");
      entry.wait_until = Date.now() + DECISION_WAIT_MS;
    }

    // A session interacts with pickers (AskUserQuestion / ExitPlanMode / slash
    // pickers) strictly one at a time, and they carry no decision channel — when
    // one is answered in the panel, PostToolUse may not fire, so its pending can
    // linger as a zombie popup row. Any new prompt in this session means the
    // previous picker is done: clear same-session picker pendings first, so a
    // re-asked question doesn't stack a second card. (Only pickers — permission
    // prompts can legitimately coexist within a session via parallel tool calls.)
    if (data.session_id) {
      try {
        for (const f of fs.readdirSync(PENDING_DIR)) {
          if (!f.endsWith(".json")) continue;
          const full = path.join(PENDING_DIR, f);
          try {
            const prev = JSON.parse(fs.readFileSync(full, "utf8"));
            if (prev.session_id === data.session_id && prev.kind === "picker")
              fs.unlinkSync(full);
          } catch {}
        }
      } catch {}
    }

    // Atomic write (tmp + rename) — extension's scanPendingDir marks files it
    // can't parse as permanently invalid; a half-written JSON would kill the
    // hook path for this prompt. The .tmp suffix keeps it out of *.json globs.
    const finalPath = path.join(PENDING_DIR, id + ".json");
    const tmpPath = finalPath + ".tmp";
    fs.writeFileSync(tmpPath, JSON.stringify(entry, null, 2), "utf8");
    fs.renameSync(tmpPath, finalPath);

    // Notification sound — SYNCHRONOUS (PlaySync via execSync). Async/detached
    // players get cut the instant the hook exits: on a vscode-terminal prompt the
    // hook exits within ~60ms, tearing down its hidden console (CREATE_NO_WINDOW)
    // and killing the child mid-beep — no sound in the integrated terminal, the
    // reported symptom. Blocking here keeps the hook alive until playback ends.
    // Placed AFTER the pending write so it never delays the popup/box (both shown
    // in parallel via the hook↔UI race). timeout caps a stuck player; any failure
    // is swallowed — sound must never break the hook. Muted by PRESS1_NO_SOUND=1
    // or the tray "Mute prompt sound" toggle (~/.press-1-mute); the env var also
    // keeps the offline test suite fast and silent.
    if (!process.env.PRESS1_NO_SOUND) {
      try {
        // Mute flag checked inside the try so a stat error can't break the hook,
        // and so USERPROFILE/IO stay untouched when sound is already off.
        if (!MUTE_FLAG || !fs.existsSync(MUTE_FLAG)) {
          // Forward slashes, not backslashes: execSync's shell varies (cmd vs a
          // POSIX sh), and sh eats "\M"/"\W" — the path collapses to "MediaWindows"
          // and SoundPlayer fails silently. PowerShell accepts forward slashes.
          const wav = SOUND_WAV.replace(/\\/g, "/");
          const wavExpr = /[/:]/.test(wav)
            ? "'" + wav + "'"                          // full/explicit path
            : "($env:WINDIR + '/Media/" + wav + "')";  // bare Media filename
          execSync(
            "powershell -NoProfile -Command \"(New-Object Media.SoundPlayer " + wavExpr + ").PlaySync()\"",
            { timeout: 4000, stdio: "ignore", windowsHide: true }
          );
        }
      } catch {}
    }

    // Pickers stay alive as a liveness beacon (see waitForPendingGone). Claude
    // Code shows the question without waiting for us, so this never delays it; it
    // only lets the popup row vanish the moment the question is resolved —
    // closing the cancel gap that teardown can't (cancel emits no hook event).
    if (kind === "picker") {
      waitForPendingGone(finalPath, DECISION_WAIT_MS);
      try { fs.unlinkSync(finalPath); } catch {}   // answered / timed-out: clear our own row
      process.exit(0);
    }

    if (decisionWait) {
      cleanupStaleDecisionFiles();
      const word = waitForDecision(entry.decision_file, finalPath, DECISION_WAIT_MS);
      // The pending's lifetime IS the answer window: delete it on the way out
      // so the AHK popup row vanishes in sync with the hook releasing the
      // prompt (answered or passed through to the TUI / native box).
      try { fs.unlinkSync(finalPath); } catch {}
      try { fs.unlinkSync(entry.decision_file); } catch {}
      const out = decisionToOutput(word, data);
      if (out) {
        process.stdout.write(JSON.stringify(out), () => process.exit(0));
        // Backstop: never outlive the write — Claude Code is blocked on us.
        setTimeout(() => process.exit(0), 1000);
        return;
      }
    }
  } catch {
    // hook must never break Claude Code
  }

  process.exit(0);
});
