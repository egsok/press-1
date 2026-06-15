// Offline tests for permission-request.js: host classification, decision
// channel (editor terminal/panel/WT/conhost, S10), 60-min window, early-exit on
// pending deletion, picker pass-through, editor_exe capture. Isolated TEMP per
// test. Run: node tests/hook.test.js
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const HOOK = path.join(__dirname, "..", "permission-request.js");
const BASE = path.join(require("os").tmpdir(), "press-1-tests", "hook");

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

function hostEnv(kind) {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.TERM_PROGRAM;
  delete env.WT_SESSION;
  delete env.PRESS1_DECISION_WAIT_MS;
  // The test runner may itself live in a VS Code terminal — clear the inherited
  // editor var so editor_exe is deterministic (set explicitly for vsterm).
  delete env.VSCODE_GIT_ASKPASS_NODE;
  if (kind === "wt") env.WT_SESSION = "guid-test";
  if (kind === "conhost") env.CLAUDE_CODE_ENTRYPOINT = "cli";
  if (kind === "panel") env.CLAUDE_CODE_ENTRYPOINT = "claude-vscode";
  if (kind === "vsterm") {
    env.TERM_PROGRAM = "vscode";
    env.VSCODE_INJECTION = "1";
    env.VSCODE_GIT_ASKPASS_NODE = "C:/Users/test/AppData/Local/Programs/cursor/Cursor.exe";
  }
  return env;
}

const PAYLOAD = {
  session_id: "sess-v54",
  tool_name: "Bash",
  tool_input: { command: "reg add HKCU\\Software\\CaV54Test /f" },
  cwd: "D:/dev/proj-a",
};
const SUGGESTIONS = [{ type: "addRules", rules: [{ toolName: "Bash" }], behavior: "allow", destination: "localSettings" }];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(cond, timeoutMs, stepMs = 100) {
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

// Spawn the hook, return { child, stdout(), exited() } plus helpers.
function runHookAsync(payload, env, tempDir) {
  // PRESS1_NO_SOUND: the hook now plays its notification sound synchronously
  // (so a fast-exiting vscode-terminal hook still beeps). Mute it in tests —
  // otherwise every spawn blocks ~1-2s on playback and 40 beeps fire.
  const e = { ...env, TEMP: tempDir, TMP: tempDir, PRESS1_NO_SOUND: "1" };
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
  // T1: WT host → decision channel declared; deny applied
  {
    const dir = freshTemp("t1");
    const h = runHookAsync(PAYLOAD, hostEnv("wt"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T1 WT pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T1 host.type=windows-terminal", j.host.type === "windows-terminal");
      check("T1 decision_file declared", typeof j.decision_file === "string" && j.decision_file.includes("response-hook-"));
      check("T1 wait_until in future", j.wait_until > Date.now() + 600000, `wait_until=${j.wait_until}`);
      check("T1 options 2-opt (no suggestions)", JSON.stringify(j.options) === JSON.stringify(["Allow", "Deny"]));
      check("T1 walk ran (ancestry)", j.host.walk_ms > 0 && Array.isArray(j.host.ancestry));
      check("T1 hook_pid recorded", Number.isInteger(j.hook_pid) && j.hook_pid > 0);
      writeDecision(j.decision_file, "deny");
      const r = await h.waitExit(5000);
      check("T1 hook exited after decision", r !== "timeout");
      const out = h.stdout();
      let dec = null;
      try { dec = JSON.parse(out).hookSpecificOutput.decision; } catch {}
      check("T1 stdout deny decision", dec && dec.behavior === "deny" && /Denied by user/.test(dec.message), out.slice(0, 120));
      check("T1 pending deleted on exit", pendingFiles(dir).length === 0);
      check("T1 decision file deleted", !fs.existsSync(j.decision_file));
    } else { h.child.kill(); }
  }

  // T2: conhost host + suggestions → 3 options; plain allow (no updatedPermissions)
  {
    const dir = freshTemp("t2");
    const h = runHookAsync({ ...PAYLOAD, permission_suggestions: SUGGESTIONS }, hostEnv("conhost"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T2 conhost pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T2 host.type=conhost", j.host.type === "conhost");
      check("T2 decision_file declared", !!j.decision_file);
      check("T2 options 3-opt (suggestions)", j.options.length === 3);
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T2 allow without updatedPermissions", dec && dec.behavior === "allow" && !dec.updatedPermissions);
    } else { h.child.kill(); }
  }

  // T3: WT + always → allow with echoed suggestions
  {
    const dir = freshTemp("t3");
    const h = runHookAsync({ ...PAYLOAD, permission_suggestions: SUGGESTIONS }, hostEnv("wt"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T3 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      writeDecision(j.decision_file, "always");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T3 always → allow + suggestions echo",
        dec && dec.behavior === "allow" && JSON.stringify(dec.updatedPermissions) === JSON.stringify(SUGGESTIONS));
    } else { h.child.kill(); }
  }

  // T4: panel regression — decision channel still works, no walk
  {
    const dir = freshTemp("t4");
    const h = runHookAsync(PAYLOAD, hostEnv("panel"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 5000);
    check("T4 panel pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T4 host.type=vscode-extension", j.host.type === "vscode-extension");
      check("T4 no walk for panel", j.host.walk_ms === 0);
      check("T4 decision_file declared", !!j.decision_file);
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T4 panel allow applied", dec && dec.behavior === "allow");
    } else { h.child.kill(); }
  }

  // T5: vscode-terminal is a DECISION host now — the companion extension was
  // dropped and scenario B unified onto the hook-decision channel. It declares
  // the channel, captures editor_exe for picker focus, skips the ancestry walk,
  // and applies the decision — same as the panel (was: instant exit, no
  // decision_file, pending left for the extension).
  {
    const dir = freshTemp("t5");
    const h = runHookAsync(PAYLOAD, hostEnv("vsterm"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 5000);
    check("T5 vsterm pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T5 host.type=vscode-terminal", j.host.type === "vscode-terminal");
      check("T5 decision_file declared", typeof j.decision_file === "string" && j.decision_file.includes("response-hook-"));
      check("T5 editor_exe captured", j.host.editor_exe === "Cursor.exe", `got=${j.host.editor_exe}`);
      check("T5 no walk for vscode-terminal", j.host.walk_ms === 0);
      writeDecision(j.decision_file, "allow");
      await h.waitExit(5000);
      let dec = null;
      try { dec = JSON.parse(h.stdout()).hookSpecificOutput.decision; } catch {}
      check("T5 vsterm allow applied", dec && dec.behavior === "allow");
    } else { h.child.kill(); }
  }

  // T6: early-exit — deleting the pending releases the waiting hook (pass)
  {
    const dir = freshTemp("t6");
    const env = { ...hostEnv("wt"), PRESS1_DECISION_WAIT_MS: "30000" };
    const h = runHookAsync(PAYLOAD, env, dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T6 pending written", !!pf);
    if (pf) {
      await sleep(500);
      fs.unlinkSync(pf);
      const t0 = Date.now();
      const r = await h.waitExit(4000);
      check("T6 hook early-exits on teardown", r !== "timeout" && Date.now() - t0 < 3000, `${Date.now() - t0}ms`);
      check("T6 no stdout (pass-through)", h.stdout().trim() === "");
    } else { h.child.kill(); }
  }

  // T7: timeout — no decision, hook exits silently, pending removed on way out
  {
    const dir = freshTemp("t7");
    const env = { ...hostEnv("wt"), PRESS1_DECISION_WAIT_MS: "1500" };
    const h = runHookAsync(PAYLOAD, env, dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T7 pending written", !!pf);
    const r = await h.waitExit(6000);
    check("T7 hook exits on timeout", r !== "timeout");
    check("T7 no stdout on timeout", h.stdout().trim() === "");
    check("T7 pending deleted on timeout", pendingFiles(dir).length === 0);
  }

  // T8: picker BLOCKS as a liveness beacon (2026-06-14) — pending stays, the hook
  // stays ALIVE while the question is open, and it releases the instant the
  // pending is deleted (≈ teardown on answer). No decision_file (it can't answer a
  // question, only hold the row); hook_pid anchors AHK's dead-hook orphan drop.
  {
    const dir = freshTemp("t8");
    const h = runHookAsync({ ...PAYLOAD, tool_name: "AskUserQuestion", tool_input: { question: "?" } }, hostEnv("wt"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T8 picker pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T8 kind=picker, no decision_file", j.kind === "picker" && j.decision_file === undefined);
      check("T8 picker carries hook_pid (beacon liveness anchor)", Number.isInteger(j.hook_pid) && j.hook_pid > 0);
    }
    check("T8 picker hook blocks (doesn't exit immediately)", (await h.waitExit(800)) === "timeout");
    check("T8 pending persists while blocking", pendingFiles(dir).length === 1);
    if (pf) try { fs.unlinkSync(pf); } catch {}    // ≈ teardown deleting it on answer
    check("T8 beacon releases when pending deleted", (await h.waitExit(5000)) !== "timeout");
  }

  // T9: default window ≈ 60 min when env unset
  {
    const dir = freshTemp("t9");
    const h = runHookAsync(PAYLOAD, hostEnv("wt"), dir);
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T9 pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const win = j.wait_until - j.timestamp;
      check("T9 default window ~3600s", win >= 3590000 && win <= 3610000, `window=${win}ms`);
      writeDecision(j.decision_file, "pass");
      const r = await h.waitExit(5000);
      check("T9 pass releases hook, no output", r !== "timeout" && h.stdout().trim() === "");
    } else { h.child.kill(); }
  }

  // T10: same-session picker cleanup — a re-asked question must not stack a
  // second popup card (AskUserQuestion answers may not fire PostToolUse, so the
  // prior picker pending lingers). New prompt in the session clears prior pickers.
  {
    const dir = freshTemp("t10");
    const kids = [];
    const picker = (sid) => ({ ...PAYLOAD, session_id: sid, tool_name: "AskUserQuestion", tool_input: { question: "pick?" } });
    // Pickers now BLOCK (liveness beacon), so don't waitExit — the pending is
    // written before the block, so let it settle, then reap the blocked hooks.
    const firePicker = async (sid) => {
      const h = runHookAsync(picker(sid), hostEnv("panel"), dir);
      kids.push(h.child);
      await sleep(500);
    };

    await firePicker("sess-A");
    check("T10 first picker written", pendingFiles(dir).length === 1);

    await firePicker("sess-A");
    check("T10 re-asked same-session picker doesn't stack", pendingFiles(dir).length === 1,
      `got ${pendingFiles(dir).length}`);

    await firePicker("sess-B");
    check("T10 different-session picker preserved", pendingFiles(dir).length === 2,
      `got ${pendingFiles(dir).length}`);

    // a same-session PERMISSION pending must survive a new picker write
    // (permission prompts can coexist via parallel tool calls — only pickers clear).
    // vsterm permission now BLOCKS on the decision channel (companion extension
    // dropped), so capture the handle and reap it — don't waitExit.
    const perm = { ...PAYLOAD, session_id: "sess-B", tool_name: "Bash", tool_input: { command: "ls" } };
    const permHook = runHookAsync(perm, hostEnv("vsterm"), dir);
    kids.push(permHook.child);
    await sleep(500);   // let it write its pending (it then blocks on the channel)
    await firePicker("sess-B");
    const kinds = pendingFiles(dir).map((f) => JSON.parse(fs.readFileSync(f, "utf8")));
    check("T10 picker write keeps same-session permission",
      kinds.some((j) => j.session_id === "sess-B" && j.kind === "permission"),
      `kinds=${kinds.map((j) => j.session_id + ":" + j.kind).join(",")}`);

    for (const k of kids) try { k.kill(); } catch {}   // reap the blocked beacon hooks
  }

  // T13: tool_input_short is a human-readable summary, not the raw tool_input
  // JSON. The native box reads "Allow write to <path>?" — the popup must read
  // "Write(<path>)", never "Write({"file_path":...,"content":...)" truncated
  // mid-value (the live regression that motivated this).
  {
    const dir = freshTemp("t13");
    // vsterm permission now blocks on the decision channel, so wait for the
    // pending to land (not for exit) and reap the blocked hooks at the end.
    const kids = [];
    const run = async (tn, ti) => {
      const h = runHookAsync(
        { ...PAYLOAD, session_id: "T13-" + tn, tool_name: tn, tool_input: ti },
        hostEnv("vsterm"),
        dir
      );
      kids.push(h.child);
      await waitFor(() => pendingFiles(dir).some((f) => {
        try { return JSON.parse(fs.readFileSync(f, "utf8")).tool_name === tn; } catch { return false; }
      }), 8000);
    };
    await run("Write", {
      file_path: "D:/dev/proj-a/новый_файл.txt",
      content: "длинное содержимое файла, не должно попасть в строку попапа",
    });
    await run("Edit", {
      file_path: "D:/dev/proj-a/src/components/AppShell.tsx",
      old_string: "a",
      new_string: "b",
    });
    await run("Glob", { pattern: "**/*.ts", path: "D:/dev/proj-a/src" });
    await run("Read", { file_path: "C:/other/outside.log" });
    await run("Bash", { command: "echo " + "x".repeat(400) });   // overlong → cap
    const byTool = {};
    for (const f of pendingFiles(dir)) {
      const j = JSON.parse(fs.readFileSync(f, "utf8"));
      byTool[j.tool_name] = j.tool_input_short;
    }
    for (const k of kids) try { k.kill(); } catch {}   // reap the blocked hooks
    check("T13 Write → project-relative filename", byTool.Write === "новый_файл.txt", `got=${byTool.Write}`);
    check("T13 Write drops the content/JSON blob", !/content|[{}]/.test(byTool.Write || ""), `got=${byTool.Write}`);
    check("T13 Edit → relative nested path", byTool.Edit === "src/components/AppShell.tsx", `got=${byTool.Edit}`);
    check("T13 Glob → pattern + path", byTool.Glob === "**/*.ts in src", `got=${byTool.Glob}`);
    check("T13 Read outside cwd → full path", byTool.Read === "C:/other/outside.log", `got=${byTool.Read}`);
    check("T13 overlong command capped at 200 (popup adds the …)", (byTool.Bash || "").length === 200, `len=${(byTool.Bash || "").length}`);
  }

  // T14: ExitPlanMode → readable label, not a raw {"allowedPrompts":...} blob
  // (live regression: the plan-approval popup dumped tool_input JSON). It is also
  // a picker (NO_DECISION_TOOLS), so it BLOCKS as a beacon like AskUserQuestion —
  // this extends picker coverage to ExitPlanMode tool-agnostically (Task 4b).
  {
    const dir = freshTemp("t14");
    const h = runHookAsync(
      { ...PAYLOAD, tool_name: "ExitPlanMode", tool_input: { allowedPrompts: [{ tool: "Bash", prompt: "run tests" }] } },
      hostEnv("panel"),
      dir
    );
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T14 ExitPlanMode pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      check("T14 ExitPlanMode → clean label", j.tool_input_short === "Plan ready for review", `got=${j.tool_input_short}`);
      check("T14 ExitPlanMode drops the allowedPrompts JSON blob", !/allowedPrompts|[{}]/.test(j.tool_input_short || ""), `got=${j.tool_input_short}`);
      check("T14 ExitPlanMode classified as picker (beacon parity)", j.kind === "picker", `kind=${j.kind}`);
    }
    h.child.kill();   // reap the blocked beacon hook
  }

  // T15: ExitPlanMode WITH plan text → readable prose, Markdown heading markers
  // (#, ##, …) stripped. Live: some CC versions pass the plan markdown in
  // ti.plan and the popup showed raw "## Context" syntax. The label must be the
  // plan text with heading markers gone (not the static no-plan fallback).
  {
    const dir = freshTemp("t15");
    const h = runHookAsync(
      { ...PAYLOAD, tool_name: "ExitPlanMode", tool_input: { plan: "# План сессии\n\n## Context\n\nDetails here" } },
      hostEnv("panel"),
      dir
    );
    const pf = await waitFor(() => pendingFiles(dir)[0], 8000);
    check("T15 ExitPlanMode(plan) pending written", !!pf);
    if (pf) {
      const j = JSON.parse(fs.readFileSync(pf, "utf8"));
      const s = j.tool_input_short || "";
      check("T15 plan text used (not the static no-plan label)", s.includes("План сессии") && s.includes("Context"), `got=${s}`);
      check("T15 leading/heading '#'/'##' markers stripped", !/^#{1,6}\s/m.test(s), `got=${JSON.stringify(s)}`);
    }
    h.child.kill();   // reap the blocked beacon hook
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}

main();
