// Offline tests for codex-permission-request.js: Codex host fingerprint,
// decision channel (panel/WT/vsterm/conhost — every host blocks on it), 3-button
// options, clamped wait window, always-allow → default.rules append (tokenize +
// escape + dedup), no updatedPermissions echo, fail-safe. Isolated TEMP per test.
// Run: node tests/codex-hook.test.js
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HOOK = path.join(__dirname, "..", "codex-permission-request.js");
const BASE = path.join(require("os").tmpdir(), "press-1-tests", "codex-hook");

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
    "PRESS1_CODEX_NATIVE_CONTROL", "PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS"]) delete env[k];
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

  console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
  process.exit(fail ? 1 : 0);
}

main();
