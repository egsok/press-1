const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync } = require("child_process");
// Experimental exact same-turn auto-review detector (transcript probe). Lives
// in its own module so the whole unstable-format parser can be replaced/deleted
// as a unit when upstream ships an official reviewer field (openai/codex#23465).
const { shouldPassCodexAutoReview } = require("./codex-reviewer.js");

// press-1 — OpenAI Codex CLI PermissionRequest hook (scenario A/B/C).
// Sibling of permission-request.js (the Claude hook); same decision channel,
// same pending/decision-file protocol, same fail-safe discipline (ANY error →
// exit 0 empty → Codex shows its native prompt). Deployed to ~/.codex/hooks/
// and registered in ~/.codex/hooks.json (wrapper schema) by merge-codex-hooks.js.
//
// Key differences from the Claude hook (all proven in docs/RESEARCH-CODEX.md
// §16–17, empirically on Codex 0.137/0.140/0.141):
//  - Codex has NO Promise.race: the hook is a blocking pre-prompt gate, so the
//    native prompt is invisible while we wait → the wait window is SHORT, and
//    the default mode is a two-phase HYBRID (Stage 2d): a short decision window,
//    then the pending is rewritten to native_control and the hook exits — the
//    native prompt appears while the popup row lives on as a remote.
//  - Codex rejects decision.updatedPermissions → "Always allow" persists via the
//    rules file ~/.codex/rules/default.rules instead (Starlark prefix_rule).
//  - No permission_suggestions in the payload → the popup is always 3-button.
//  - No CLAUDE_CODE_ENTRYPOINT → host fingerprint reads terminal/editor env only.

const PERM_DIR = path.join(
  process.env.TEMP || path.join(process.env.USERPROFILE, "AppData", "Local", "Temp"),
  "press-1"
);
const PENDING_DIR = path.join(PERM_DIR, "pending");

// Notification sound — same contract as the Claude hook (see permission-request.js).
const SOUND_WAV = process.env.PRESS1_SOUND || "ding.wav";
const MUTE_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-mute")
  : "";

// Per-agent kill switch. The tray submenu writes/removes ~/.press-1-off-codex;
// when present, press-1 gets out of the way entirely for Codex (early exit
// before any pending/sound → Codex's native prompt shows, no popup).
const OFF_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-off-codex")
  : "";

// Native-control flag file — with the hybrid model (Stage 2d) this opt-in means
// "skip phase 1 entirely" for the panel (the original spike behavior); see
// codexMode() for the full mode matrix.
const NATIVE_CONTROL_FLAG = process.env.USERPROFILE
  ? path.join(process.env.USERPROFILE, ".press-1-codex-native-control")
  : "";

// Always-allow rules file. Codex's TUI "don't ask again" writes prefix_rule()
// lines here; press-1 mirrors that. Env-overridable for the offline test suite.
const RULES_FILE = process.env.PRESS1_CODEX_RULES_PATH
  || path.join(process.env.USERPROFILE || os.homedir(), ".codex", "rules", "default.rules");

// Blocking-gate wait windows (hybrid two-phase, Stage 2d). While the hook waits,
// the native Codex prompt is held back (no race — Obs 1: the panel still renders
// "Running …" during the hold, so the invisibility is soft; Esc releases sooner).
//  - HYBRID_WAIT_MS: phase-1 window of the default hybrid mode — SHORT, because
//    on timeout the pending is rewritten to native_control (phase 2) and the
//    popup row lives on; the native prompt should appear quickly.
//  - DECISION_WAIT_MS: the decision-only window (PRESS1_CODEX_NATIVE_CONTROL=0,
//    and always for conhost) — there is no phase 2 there, the window is the
//    hotkey's only channel, so it stays at the pre-hybrid 60 s.
// CLAMP invariant: the rewrite/exit must happen BEFORE the 70 s hooks.json
// kill-timeout, and the hook can spend up to ~3 s in the WT ancestry walk plus
// up to ~4 s in the synchronous sound. clamp = 70000 − 4000 (sound) − 3000
// (walk) − 3000 (margin) = 60000.
const SOUND_BUDGET_MS = 4000; // = the sound execSync timeout below
const WINDOW_CLAMP_MS = 60000;
const DECISION_WAIT_MS = Math.min(
  parseInt(process.env.PRESS1_CODEX_WAIT_MS, 10) || 60000,
  WINDOW_CLAMP_MS
);
const HYBRID_WAIT_MS = Math.min(
  parseInt(process.env.PRESS1_CODEX_HYBRID_WAIT_MS, 10) || 15000,
  WINDOW_CLAMP_MS
);
const NATIVE_CONTROL_WAIT_MS = Math.min(
  parseInt(process.env.PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS, 10) || 300000,
  3600000
);
const POLL_MS = 100;

function flagExists(file) {
  try { return !!(file && fs.existsSync(file)); } catch { return false; }
}

// Mode of the Codex permission flow — the single source of truth (Stage 2d).
//   "hybrid"   (default) — phase 1: block on the decision file for HYBRID_WAIT_MS;
//              on timeout REWRITE the pending to native_control and exit empty →
//              Codex renders its native prompt while the popup row lives on as a
//              remote (phase 2).
//   "decision" (PRESS1_CODEX_NATIVE_CONTROL=0, and ALWAYS for conhost) — phase 1
//              only, window DECISION_WAIT_MS; timeout deletes the pending (the
//              pre-hybrid behavior). conhost never gets phase 2: the hook collects
//              no window data for it (no walk), so its phase-2 row would be a
//              dead remote nobody can focus.
//   "native"   (=1 / flag file, panel ONLY) — skip phase 1 entirely (the original
//              spike behavior). On non-panel hosts the opt-in degrades to hybrid:
//              they have no digit delivery, so skipping phase 1 would remove
//              their only answer channel.
function codexMode(hostType) {
  if (hostType === "conhost") return "decision";
  if (process.env.PRESS1_CODEX_NATIVE_CONTROL === "0") return "decision";
  const optIn = process.env.PRESS1_CODEX_NATIVE_CONTROL === "1" || flagExists(NATIVE_CONTROL_FLAG);
  if (optIn && hostType === "vscode-extension") return "native";
  return "hybrid";
}

// Codex host fingerprint from env. No CLAUDE_CODE_ENTRYPOINT exists for Codex,
// so this is weaker than the Claude classifier (the panel/conhost boundary
// rests on VSCODE_PID — a hypothesis to confirm on the live smoke). The
// fallback is conhost (a routed standalone host), never "unknown".
//  - TERM_PROGRAM=vscode beats WT_SESSION (VS Code launched from WT leaks it).
function classifyHost(env) {
  if (env.TERM_PROGRAM === "vscode") return "vscode-terminal";
  if (env.WT_SESSION) return "windows-terminal";
  if (env.VSCODE_PID && !env.TERM_PROGRAM && !env.WT_SESSION) return "vscode-extension";
  return "conhost";
}

// Ancestry walk (S2): one CIM snapshot + in-memory walk, ~1.0–1.2 s. Identical
// to the Claude hook's walk. Returns null on any failure.
function walkAncestry() {
  const ps = [
    "$m=@{}",
    "Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name | ForEach-Object { $m[[int]$_.ProcessId] = @([int]$_.ParentProcessId, $_.Name) }",
    "$stop=@('explorer.exe','services.exe','svchost.exe','wininit.exe','winlogon.exe')",
    "$p=[int]$env:PRESS1_WALK_PID",
    "$out=@()",
    "for($i=0; $i -lt 12 -and $m.ContainsKey($p); $i++){ $e=$m[$p]; if($stop -contains $e[1]){ break }; $out += ('{0}:{1}' -f $p, $e[1]); $p = $e[0] }",
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
    title: "",
  };
}

function buildHost() {
  const env = process.env;
  const host = {
    type: classifyHost(env),
    entrypoint: "",
    term_program: env.TERM_PROGRAM || "",
    wt_session: env.WT_SESSION || "",
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

  // 2a gate: walk ONLY for definite Windows Terminal (WT_SESSION present). A
  // misclassified panel landing in conhost then costs no walk — no latency on
  // the blocking gate, only a cosmetic badge. conhost/WT focus + walk are wired
  // in 2b when A/B focus ships; for now the decision channel needs no window.
  if (host.type === "windows-terminal") {
    const t0 = Date.now();
    try {
      const w = walkAncestry();
      if (w) Object.assign(host, w);
    } catch {}
    host.walk_ms = Date.now() - t0;
  }
  return host;
}

// Synchronous bounded wait for the AHK-written decision word — identical to the
// Claude hook. The hook MUST stay alive while waiting (its exit is what releases
// Codex to show the native prompt). Decision read FIRST so a word written in the
// same tick as a teardown still wins (the safe direction: a real user answer).
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

// Quote-aware tokenizer: split a command into argv the way the Codex TUI does
// for its "don't ask again for commands that start with <X>" rule. Single/double
// quotes group tokens (and are stripped); whitespace separates. For
// `node -e "console.log('x')"` → ["node","-e","console.log('x')"].
function tokenizeCommand(cmd) {
  const tokens = [];
  let cur = "", inS = false, inD = false, has = false;
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (inS) {
      if (c === "'") inS = false; else { cur += c; }
      has = true;
    } else if (inD) {
      if (c === '"') inD = false; else { cur += c; }
      has = true;
    } else if (c === "'") { inS = true; has = true; }
    else if (c === '"') { inD = true; has = true; }
    else if (/\s/.test(c)) { if (has) { tokens.push(cur); cur = ""; has = false; } }
    else { cur += c; has = true; }
  }
  if (has) tokens.push(cur);
  return tokens;
}

// Build the Starlark prefix_rule line for a full-command (TUI-default) scope.
// Escape each token for a Starlark double-quoted string: backslash, quote, newline.
function buildPrefixRule(tokens) {
  const pattern = tokens
    .map((t) => '"' + t.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"')
    .join(", ");
  return 'prefix_rule(pattern=[' + pattern + '], decision="allow")';
}

// "Always allow" side-effect: append a full-command prefix_rule to default.rules,
// mirroring what the Codex TUI writes. Best-effort and isolated — the caller
// emits the allow decision regardless of whether this succeeds (the user pressed
// "always" = they want THIS command allowed NOW; persistence is a bonus).
//  - empty/missing command (non-Bash tool, apply_patch) → write no rule.
//  - exact-line dedup (cheap string match — two differently-tokenized rules are
//    genuinely different rules to Codex, so exact-string is the right grain).
//  - read-all → splice → tmp+rename = atomic; Codex never sees a torn file.
// Known limitation: commands Codex internally pwsh-wraps (shell operators/pipes)
// evaluate as ["pwsh.exe","-Command",…]; an unwrapped-token rule won't match them
// → a benign no-op (re-prompted next time). Simple direct-exec commands match.
function appendAlwaysRule(command) {
  if (typeof command !== "string" || !command.trim()) return;
  const tokens = tokenizeCommand(command);
  if (tokens.length === 0) return;
  const line = buildPrefixRule(tokens);
  fs.mkdirSync(path.dirname(RULES_FILE), { recursive: true });
  let existing = "";
  try { existing = fs.readFileSync(RULES_FILE, "utf8"); } catch {}
  if (existing.split(/\r?\n/).some((l) => l.trim() === line)) return;  // already present
  const needsNL = existing.length > 0 && !/\n$/.test(existing);
  const out = existing + (needsNL ? "\n" : "") + line + "\n";
  const tmp = RULES_FILE + ".tmp-press-1";
  fs.writeFileSync(tmp, out, "utf8");
  fs.renameSync(tmp, RULES_FILE);
}

// Map the decision word to Codex hook stdout JSON.
//   allow / always → {behavior:"allow"}  (NO updatedPermissions — Codex rejects it;
//                    "always" persistence is handled by appendAlwaysRule in main flow)
//   deny           → {behavior:"deny", message}
//   pass / unknown / timeout → null = no output, native prompt takes over
function decisionToOutput(word) {
  if (word === "allow" || word === "always") {
    return {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "allow" },
      },
    };
  }
  if (word === "deny") {
    return {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "deny", message: "Denied by user via press-1 hotkey" },
      },
    };
  }
  return null;
}

// Atomic pending write (tmp + rename) — the `.tmp` suffix never matches the
// readers' *.json globs, so AHK can never observe a torn file.
function writePendingAtomic(file, obj) {
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), "utf8");
  fs.renameSync(tmp, file);
}

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

function hookAlive(pid) {
  if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (e) { return !!(e && e.code === "EPERM"); }
}

// Interrupt/Esc in the TUI fires neither PostToolUse nor Stop, so a new manual
// popup clears older same-session Codex rows before publishing its replacement.
// Scoped by hook liveness (same rule as session-teardown.js): interrupt-killed
// retries are dead corpses → deleted; a PARALLEL approval hook of the same
// thread is alive → its row must stay answerable (session_id is a ThreadId,
// concurrent approvals within one thread are real). native_control rows have
// no hook by design → cleaned as before. Do not call this from the silent
// exact-auto route: it must not mutate pending at all.
function cleanupCodexSessionPendings(sessionId) {
  if (!sessionId) return;
  try {
    for (const f of fs.readdirSync(PENDING_DIR)) {
      if (!f.endsWith(".json")) continue;
      const full = path.join(PENDING_DIR, f);
      try {
        const prev = JSON.parse(fs.readFileSync(full, "utf8"));
        if (prev.agent !== "codex" || prev.session_id !== sessionId) continue;
        if (prev.native_control === true || !hookAlive(prev.hook_pid))
          fs.unlinkSync(full);
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

    // Per-agent kill switch (~/.press-1-off-codex): exit 0 empty = native prompt,
    // no pending/popup/sound. Wrapped so a flag-check error fails toward SHOWING
    // the popup (a stray fs error must not silently disable press-1).
    if (flagExists(OFF_FLAG)) process.exit(0);

    // Proxy-channel mute (PRESS1_PROXY): the codex-mitm wrapper sets this in the
    // env of the app-server it spawns, so hook processes inherit it ONLY under a
    // live proxy (panel) — exit 0 empty (no pending/popup/sound), the proxy owns
    // that panel's approvals; terminal Codex CLI never inherits it and keeps the
    // hook channel. Self-healing: env exists only under a live wrapper → mute
    // vanishes the moment the proxy dies/is removed (no stale flag-file to clear).
    if (process.env.PRESS1_PROXY) process.exit(0);

    // Exact current-turn auto-review on any standard hook surface: pass through
    // before pending/sound so Codex can run its reviewer. Any uncertain signal
    // returns false and falls through unchanged to the existing popup path.
    if (shouldPassCodexAutoReview(data)) process.exit(0);

    fs.mkdirSync(PENDING_DIR, { recursive: true });

    const id = Date.now() + "-" + Math.random().toString(36).slice(2, 8);

    const oneLine = (s) => String(s).replace(/\s+/g, " ").trim();
    const cwd = data.cwd || process.cwd();
    const projectName = path.basename(cwd);
    const ti = data.tool_input;

    const relPath = (p) => {
      if (typeof p !== "string" || !p) return "";
      const c = String(cwd).replace(/[\\/]+$/, "");
      if (c && p.toLowerCase().startsWith(c.toLowerCase())) {
        const rest = p.slice(c.length).replace(/^[\\/]+/, "");
        if (rest) return rest;
      }
      return p;
    };
    // One-line readable summary for the popup card — same intent as the Claude
    // hook. Codex's payload uses tool_name "Bash" + tool_input.command (raw model
    // command), so the Bash case carries the common path.
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
        case "Glob":
        case "Grep":
          return (ti.pattern || "") + (ti.path ? " in " + relPath(ti.path) : "");
        case "WebFetch":
          return ti.url || "";
      }
      for (const k of ["file_path", "path", "command", "url", "query", "pattern", "prompt", "description"]) {
        if (typeof ti[k] === "string" && ti[k])
          return k.endsWith("path") ? relPath(ti[k]) : ti[k];
      }
      return JSON.stringify(ti);
    };
    const summary = summarize();
    const toolInputShort = oneLine(summary).slice(0, 200);
    // Full, NEWLINE-PRESERVING command for the popup's expand affordance (click /
    // Ctrl+Win+E) — NO oneLine collapse; the expanded card renders the real line
    // breaks. Capped wider (2000) than the collapsed line; the popup wraps/clips.
    const toolInputFull = String(summary).slice(0, 2000);

    // Codex has no AskUserQuestion/ExitPlanMode-style picker tools — every
    // PermissionRequest is an allow/deny/always box. Treat everything as
    // permission (confirm on smoke). No permission_suggestions exist → the popup
    // is always the 3-button layout, parity with Claude (button 2 = Always allow
    // via the rules file, not updatedPermissions).
    const host = buildHost();
    const mode = codexMode(host.type);
    const waitMs = mode === "hybrid" ? HYBRID_WAIT_MS : DECISION_WAIT_MS;
    // wait_until must survive the SYNCHRONOUS sound below (up to SOUND_BUDGET_MS
    // before waitForDecision even starts) — otherwise AHK's wait_until cutoff
    // would hide the row before the hook times out / rewrites (critical with the
    // short hybrid window). The phase-2 rewrite extends it again with the TTL.
    const entry = {
      schema: 2,
      id,
      agent: "codex",
      timestamp: Date.now(),
      project_name: projectName,
      cwd,
      session_id: data.session_id || "",
      tool_name: data.tool_name || "",
      tool_input_short: toolInputShort,
      tool_input_full: toolInputFull,
      kind: "permission",
      options: ["Allow", "Always allow", "Deny"],
      claude_pid: process.ppid,
      hook_pid: process.pid,
      host,
      wait_until:
        Date.now() + SOUND_BUDGET_MS + (mode === "native" ? NATIVE_CONTROL_WAIT_MS : waitMs),
    };
    if (mode === "native") {
      entry.native_control = true;
    } else {
      entry.decision_file = path.join(PERM_DIR, "response-hook-" + id + ".txt");
    }

    // Clear older attempts before publishing the new row, or retries stack
    // identical cards and FIFO can target a corpse (live smoke 2026-07-02).
    cleanupCodexSessionPendings(entry.session_id);

    const finalPath = path.join(PENDING_DIR, id + ".json");
    writePendingAtomic(finalPath, entry);

    // Notification sound — SYNCHRONOUS, AFTER the pending write, swallow-all (see
    // permission-request.js for the why). Budgeted into the 70 s outer timeout.
    if (!process.env.PRESS1_NO_SOUND) {
      try {
        if (!flagExists(MUTE_FLAG)) {
          const wav = SOUND_WAV.replace(/\\/g, "/");
          const wavExpr = /[/:]/.test(wav)
            ? "'" + wav + "'"
            : "($env:WINDIR + '/Media/" + wav + "')";
          execSync(
            "powershell -NoProfile -Command \"(New-Object Media.SoundPlayer " + wavExpr + ").PlaySync()\"",
            { timeout: 4000, stdio: "ignore", windowsHide: true }
          );
        }
      } catch {}
    }

    if (mode === "native") {
      process.exit(0);
    }

    cleanupStaleDecisionFiles();
    // Deadline is computed INSIDE waitForDecision from a fresh Date.now() — the
    // sound above already ate its budget, the window starts full from here.
    let word = waitForDecision(entry.decision_file, finalPath, waitMs);
    if (word === "" && mode === "hybrid" && fs.existsSync(finalPath)) {
      // Timed out with the pending still alive (an early-exit — teardown or the
      // AHK liveness gate — deletes it; that path must NOT resurrect the file).
      // One final decision re-read closes the "word landed on the last tick"
      // race before we hand the prompt over.
      try { word = fs.readFileSync(entry.decision_file, "utf8").trim().toLowerCase(); } catch {}
      if (word === "") {
        // Phase-2 handoff: atomically rewrite the SAME pending (same id → the
        // popup row morphs in place — no re-show after dismiss, no new sound)
        // into a native-control row, then exit empty so Codex renders its
        // native prompt. From here the row is a remote: AHK sends the digit
        // into the panel webview / focuses the terminal; cleanup = teardown on
        // approve, AHK delete on digit sent, TTL wait_until otherwise.
        try {
          const phase2 = Object.assign({}, entry, {
            native_control: true,
            wait_until: Date.now() + NATIVE_CONTROL_WAIT_MS,
          });
          delete phase2.decision_file;
          writePendingAtomic(finalPath, phase2);
          try { fs.unlinkSync(entry.decision_file); } catch {}
          process.exit(0);
        } catch {}
        // rewrite failed → fall through to the decision-only cleanup below
      }
    }
    // Delete the pending on the way out so the AHK popup row vanishes in sync
    // with the hook releasing the prompt (answered or passed through).
    try { fs.unlinkSync(finalPath); } catch {}
    try { fs.unlinkSync(entry.decision_file); } catch {}

    // "Always allow": append the rule SYNCHRONOUSLY, BEFORE emitting the allow
    // (decision 7 — sidesteps the "does Codex consume stdout on flush or exit?"
    // unknown). Isolated: a failed append can never block or corrupt the allow.
    if (word === "always") {
      try { appendAlwaysRule(ti && ti.command); } catch {}
    }

    const out = decisionToOutput(word);
    if (out) {
      process.stdout.write(JSON.stringify(out), () => process.exit(0));
      setTimeout(() => process.exit(0), 1000);  // backstop: never outlive the write
      return;
    }
  } catch {
    // hook must never break Codex
  }

  process.exit(0);
});
