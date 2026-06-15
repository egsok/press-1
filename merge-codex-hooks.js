#!/usr/bin/env node
// press-1 — safe merge of the Codex hooks into ~/.codex/hooks.json + best-effort
// auto-trust. Two parts:
//   Part 1 (load-bearing, drives exit code): write our hook entries into the
//     WRAPPER schema {"hooks":{"PermissionRequest":[…]}}. Codex parses a
//     top-level (Claude-style) hooks.json to EMPTY silently, so the wrapper is
//     mandatory. Identifies its own entries by script filename; foreign keys
//     (incl. the user's dead top-level GSD events) are preserved and NOT
//     migrated — migrating would resurrect them after trust. Exit 1 = file
//     untouched, add hooks manually.
//   Part 2 (best-effort, never fails the exit code): trust our hooks by reading
//     their currentHash from `codex app-server` → `hooks/list` and writing
//     trusted_hash into ~/.codex/config.toml. Any failure → print the manual
//     `/hooks` fallback and exit 0 with Part 1 still applied.
//
// Env overrides (tests): CODEX_HOOKS_PATH, CODEX_HOOKS_DIR, CODEX_CONFIG_PATH,
// PRESS1_CODEX_SKIP_TRUST=1 (skip the app-server spawn entirely).

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn } = require("child_process");

const hooksPath = process.env.CODEX_HOOKS_PATH
  || path.join(os.homedir(), ".codex", "hooks.json");
const hooksDir = process.env.CODEX_HOOKS_DIR
  || path.join(os.homedir(), ".codex", "hooks");
const configPath = process.env.CODEX_CONFIG_PATH
  || path.join(os.homedir(), ".codex", "config.toml");

const cmdFor = (file) => `node "${path.join(hooksDir, file).replace(/\\/g, "/")}"`;

// Our scripts (own-entry identity, in command + in hooks/list matching).
const OUR_FILES = ["codex-permission-request.js", "session-teardown.js"];

// Codex PermissionRequest timeout is SMALL by design (NOT Claude's 3660): it is
// the kill-deadline Codex enforces on the hook process, and the hook is a
// blocking gate (no race) — a hung hook must die fast so pass-through restores
// the native prompt. 70 s > wait window (60 s default / 65 s clamp) + sound
// (~4 s). set-exact (the entry is created with this value; not enforce-min,
// which only raises) — and the merge below now OVERWRITES a differing value so a
// machine that already carries the old timeout:30 (Stage 2a installs) is bumped.
// statusMessage: shown by the Codex TUI while the hook runs — makes the hybrid
// phase-1 hold legible ("why is nothing happening") instead of a silent pause.
// Panel rendering unconfirmed; harmless there. set-exact like timeout.
const WANTED = [
  { event: "PermissionRequest", file: "codex-permission-request.js", timeout: 70, enforceMin: false,
    statusMessage: "press-1: hotkey Ctrl+Win+1/2/3 (Esc in popup = show this prompt)" },
  { event: "Stop",             file: "session-teardown.js",         timeout: 5,  enforceMin: false },
  { event: "PostToolUse",      file: "session-teardown.js",         timeout: 5,  enforceMin: false },
];

function fail(msg) {
  console.error(`[merge-codex-hooks] ${msg}`);
  console.error("[merge-codex-hooks] ~/.codex/hooks.json не тронут. Добавь хуки вручную — см. README.");
  process.exit(1);
}

// ---- Part 1: wrapper-schema merge ------------------------------------------

function mergeHooksFile() {
  let root = {};
  if (fs.existsSync(hooksPath)) {
    let raw;
    try { raw = fs.readFileSync(hooksPath, "utf8"); }
    catch (e) { fail(`не удалось прочитать ${hooksPath}: ${e.message}`); }
    try { root = JSON.parse(raw); }
    catch (e) { fail(`${hooksPath} содержит невалидный JSON: ${e.message}`); }
    if (typeof root !== "object" || root === null || Array.isArray(root)) {
      fail("корень hooks.json — не объект.");
    }
  }

  // Wrapper: our entries live under root.hooks.<Event>, NEVER at root.<Event>.
  if (root.hooks == null) root.hooks = {};
  if (typeof root.hooks !== "object" || Array.isArray(root.hooks)) {
    fail('поле "hooks" в hooks.json — не объект.');
  }

  let changed = false;

  // CRITICAL (found on the live smoke 2026-06-18): Codex's HooksFile deserializer
  // uses serde deny_unknown_fields — ANY top-level key other than "hooks" makes
  // the ENTIRE file fail to parse ("unknown field `SubagentStart`, expected
  // `hooks`"), taking OUR hooks down with it (hooks: 0). The research's "leave
  // foreign top-level keys, inert" was wrong: a dead Claude-style top-level key
  // (e.g. GSD's SubagentStart/Stop/PostToolUse, written in the wrong schema)
  // doesn't sit inert beside the wrapper, it BREAKS it. So we MUST remove every
  // non-"hooks" top-level key. They were ALREADY inactive (wrong schema, never
  // loaded), so nothing functional is lost — but we save them write-once to a
  // sidecar so the user can recover them, then strip them from the live file.
  // (This is removal, NOT migration: they stay dead, never become live hooks.)
  const foreignTop = Object.keys(root).filter((k) => k !== "hooks");
  if (foreignTop.length) {
    const sidecar = hooksPath + ".disabled-by-press-1";
    if (!fs.existsSync(sidecar)) {
      const saved = {};
      for (const k of foreignTop) saved[k] = root[k];
      try { fs.writeFileSync(sidecar, JSON.stringify(saved, null, 2) + "\n"); } catch {}
    }
    for (const k of foreignTop) delete root[k];
    changed = true;
    console.error(
      `[merge-codex-hooks] removed inactive top-level keys [${foreignTop.join(", ")}] — Codex's wrapper schema rejects unknown top-level fields and they would break the whole file. They were already inactive (wrong schema); saved to ${path.basename(sidecar)}.`
    );
  }
  for (const w of WANTED) {
    if (root.hooks[w.event] == null) root.hooks[w.event] = [];
    const groups = root.hooks[w.event];
    if (!Array.isArray(groups)) fail(`hooks.${w.event} — не массив.`);

    const desired = cmdFor(w.file);
    let found = false;

    for (const group of groups) {
      if (!group || !Array.isArray(group.hooks)) continue;
      for (const h of group.hooks) {
        if (!h || typeof h.command !== "string" || !h.command.includes(w.file)) continue;
        found = true;
        let action = "ok";
        if (h.command !== desired) { h.command = desired; action = "updated"; }
        if (h.type !== "command") { h.type = "command"; action = "updated"; }
        // enforceMin: raise only if below the floor. Otherwise SET-EXACT: write
        // whenever the value differs (load-bearing — found Codex iter1). The old
        // "write only if not a number" left an already-installed timeout:30 stuck
        // at 30 forever, so the 60 s window would silently break on every machine
        // that already had the Stage 2a hook (this one included): Codex would kill
        // the hook at 30 s, mid-wait.
        if (w.enforceMin
          ? !(typeof h.timeout === "number" && h.timeout >= w.timeout)
          : h.timeout !== w.timeout) {
          h.timeout = w.timeout; action = "updated";
        }
        // statusMessage: set-exact, same lesson as timeout — an already-installed
        // entry without the new field must be updated, not left as-is.
        if (w.statusMessage !== undefined && h.statusMessage !== w.statusMessage) {
          h.statusMessage = w.statusMessage; action = "updated";
        }
        if (action === "updated") changed = true;
        console.log(`[merge-codex-hooks] ${w.event}: ${action}`);
      }
    }

    if (!found) {
      const entry = { type: "command", command: desired, timeout: w.timeout };
      if (w.statusMessage !== undefined) entry.statusMessage = w.statusMessage;
      groups.push({ hooks: [entry] });
      changed = true;
      console.log(`[merge-codex-hooks] ${w.event}: added`);
    }
  }

  if (changed) {
    fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
    if (fs.existsSync(hooksPath)) {
      fs.copyFileSync(hooksPath, hooksPath + ".bak-codex-press-1");
    }
    const tmp = hooksPath + ".tmp-codex-press-1";
    fs.writeFileSync(tmp, JSON.stringify(root, null, 2) + "\n");
    fs.renameSync(tmp, hooksPath);
    console.log(`[merge-codex-hooks] записано: ${hooksPath} (бэкап: .bak-codex-press-1)`);
  } else {
    console.log("[merge-codex-hooks] hooks.json: изменений нет.");
  }
}

// ---- Part 2 helpers: config.toml trust upsert (pure, exported for tests) ----

// Insert or update the trusted_hash for one hook key in a config.toml string.
// Returns { cfg, changed, skipped }. Targeted (NOT strip-to-EOF) so later
// sections ([windows]/[projects]/[agents]) are never clobbered.
//  - key-quote guard: a TOML literal (single-quoted) key cannot contain a single
//    quote; such a key is skipped (caller prints the manual fallback).
//  - blind EOF append when the table is absent (valid TOML — table identity is by
//    header, not position). Replace the trusted_hash line in place when present.
function upsertTrust(cfg, key, hash) {
  if (typeof key !== "string" || key.includes("'")) {
    return { cfg, changed: false, skipped: true };
  }
  const header = `[hooks.state.'${key}']`;
  const idx = cfg.indexOf(header);
  if (idx === -1) {
    const needsNL = cfg.length > 0 && !cfg.endsWith("\n");
    return {
      cfg: cfg + (needsNL ? "\n" : "") + `\n${header}\ntrusted_hash = "${hash}"\n`,
      changed: true, skipped: false,
    };
  }
  // Operate only within this table's body (header → next "\n[" or EOF).
  const bodyStart = idx + header.length;
  const rel = cfg.slice(bodyStart).search(/\n\[/);
  const bodyEnd = rel === -1 ? cfg.length : bodyStart + rel;
  const body = cfg.slice(bodyStart, bodyEnd);
  const escHash = hash.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (new RegExp(`trusted_hash\\s*=\\s*"${escHash}"`).test(body)) {
    return { cfg, changed: false, skipped: false };  // already trusted, same hash
  }
  let newBody;
  if (/trusted_hash\s*=\s*"[^"]*"/.test(body)) {
    newBody = body.replace(/trusted_hash\s*=\s*"[^"]*"/, `trusted_hash = "${hash}"`);
  } else {
    newBody = `\ntrusted_hash = "${hash}"` + body;  // header present, value missing
  }
  return { cfg: cfg.slice(0, bodyStart) + newBody + cfg.slice(bodyEnd), changed: true, skipped: false };
}

// Is this a hooks/list entry one of ours? Match by source=user + filename in
// command (the discipline merge identifies own entries by) — robust against
// foreign hooks that share our event/path.
function isOurHook(h) {
  return h && h.source === "user" && h.handlerType === "command"
    && typeof h.command === "string"
    && OUR_FILES.some((f) => h.command.includes(f));
}

// ---- Part 2: app-server handshake + trust write (best-effort) ----------------

// Run `codex app-server`, do the initialize→hooks/list handshake, return the
// flat list of hook entries (across all cwds). Proven recipe (spike rpc.mjs).
function appServerHooksList(timeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn("codex", ["app-server"], {
        shell: process.platform === "win32",  // resolve codex.cmd from PATH
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (e) {
      return resolve({ error: "spawn_failed: " + e.message, hooks: [] });
    }
    child.on("error", (e) => resolve({ error: "spawn_failed: " + e.message, hooks: [] }));

    let buf = "", stderr = "";
    const msgs = [];
    child.stdout.on("data", (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) { try { msgs.push(JSON.parse(line)); } catch {} }
      }
    });
    child.stderr.on("data", (d) => (stderr += d.toString()));

    const send = (o) => { try { child.stdin.write(JSON.stringify(o) + "\n"); } catch {} };
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "press1-codex-merge", version: "1.0.0" } } });

    const cwds = [os.homedir()];
    const t0 = Date.now();
    let sent2 = false;
    const iv = setInterval(() => {
      if (!sent2 && msgs.find((m) => m.id === 1)) {
        sent2 = true;
        send({ jsonrpc: "2.0", method: "initialized", params: {} });
        send({ jsonrpc: "2.0", id: 2, method: "hooks/list", params: { cwds } });
      }
      const r = msgs.find((m) => m.id === 2);
      if (r || Date.now() - t0 > timeoutMs) {
        clearInterval(iv);
        try { child.kill(); } catch {}
        if (!r) return resolve({ error: "timeout_or_no_response", hooks: [], stderr: stderr.slice(-400) });
        const data = (r.result && Array.isArray(r.result.data)) ? r.result.data : [];
        const hooks = [];
        for (const d of data) if (d && Array.isArray(d.hooks)) hooks.push(...d.hooks);
        resolve({ error: null, hooks });
      }
    }, 50);
  });
}

function manualFallback(why) {
  console.error(`[merge-codex-hooks] auto-trust skipped (${why}).`);
  console.error("[merge-codex-hooks] The Codex hook is INSTALLED but not yet TRUSTED. Run `codex`, then `/hooks`, and approve the press-1 entries.");
}

async function autoTrust() {
  if (process.env.PRESS1_CODEX_SKIP_TRUST) {
    console.log("[merge-codex-hooks] auto-trust skipped (PRESS1_CODEX_SKIP_TRUST).");
    return;
  }
  const listed = await appServerHooksList(15000);
  if (listed.error) return manualFallback(listed.error);

  // Dedup our hooks by key.
  const seen = new Map();
  for (const h of listed.hooks) {
    if (isOurHook(h) && h.key && h.currentHash && !seen.has(h.key)) {
      seen.set(h.key, h.currentHash);
    }
  }
  if (seen.size === 0) return manualFallback("our hooks not found in hooks/list");

  let cfg = "";
  try { if (fs.existsSync(configPath)) cfg = fs.readFileSync(configPath, "utf8"); } catch (e) {
    return manualFallback("config.toml unreadable: " + e.message);
  }

  let changed = false, skippedQuote = false;
  for (const [key, hash] of seen) {
    const r = upsertTrust(cfg, key, hash);
    if (r.skipped) { skippedQuote = true; continue; }
    cfg = r.cfg;
    changed = changed || r.changed;
  }
  if (skippedQuote) {
    console.error("[merge-codex-hooks] one or more hook paths contain a single quote — those entries were not auto-trusted (TOML literal-key limitation).");
  }

  if (changed) {
    try {
      if (fs.existsSync(configPath)) fs.copyFileSync(configPath, configPath + ".bak-codex-press-1");
      const tmp = configPath + ".tmp-codex-press-1";
      fs.writeFileSync(tmp, cfg);
      fs.renameSync(tmp, configPath);
      console.log(`[merge-codex-hooks] trusted ${seen.size} hook(s) in ${configPath} (бэкап: .bak-codex-press-1)`);
    } catch (e) {
      return manualFallback("config.toml write failed: " + e.message);
    }
  } else {
    console.log("[merge-codex-hooks] trust: уже актуально.");
  }

  // Verify (best-effort): re-list and confirm trustStatus flipped to trusted.
  try {
    const after = await appServerHooksList(15000);
    if (!after.error) {
      const ours = after.hooks.filter(isOurHook);
      const untrusted = ours.filter((h) => h.trustStatus !== "trusted" && h.trustStatus !== "managed");
      if (untrusted.length) {
        console.error(`[merge-codex-hooks] warning: ${untrusted.length} hook(s) still not trusted after write — fall back to /hooks if Codex prompts.`);
      } else if (ours.length) {
        console.log("[merge-codex-hooks] trust verified: all press-1 Codex hooks are trusted.");
      }
    }
  } catch {}
}

if (require.main === module) {
  mergeHooksFile();  // Part 1 — may process.exit(1) on failure (file untouched)
  autoTrust()        // Part 2 — best-effort, never fails the exit code
    .catch((e) => manualFallback("unexpected: " + (e && e.message)))
    .finally(() => process.exit(0));
}

module.exports = { upsertTrust, isOurHook, mergeHooksFile };
