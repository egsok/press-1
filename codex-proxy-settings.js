#!/usr/bin/env node
// press-1 — codex-proxy-settings: JSONC-safe editor for VS Code's user
// settings.json, used by enable/disable-codex-proxy.ps1 to point (and unpoint)
// `chatgpt.cliExecutable` at the deployed codex-mitm wrapper.
// Design: docs/DESIGN-CODEX-PROXY.md §2, §6.
//
// settings.json is JSONC (line/block comments, trailing commas allowed). We must
// NOT parse-and-reserialize it — that would drop the user's comments/formatting.
// Instead we do a byte-exact TEXT SPLICE for just the one property we manage, and
// only after a JSONC-tolerant sanity parse of the result confirms it's still
// valid do we write (atomically, tmp+rename). A splice that would corrupt the
// file is refused, original untouched.
//
// CLI:
//   node codex-proxy-settings.js enable <exePath>
//   node codex-proxy-settings.js disable
//
// Env override (tests): PRESS1_VSCODE_SETTINGS — path to settings.json.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");

const MANAGED_KEY = "chatgpt.cliExecutable";
const WSL_KEY = "chatgpt.runCodexInWindowsSubsystemForLinux";

const settingsPath = process.env.PRESS1_VSCODE_SETTINGS
  || path.join(
       process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"),
       "Code", "User", "settings.json"
     );

// ---- pure helpers (exported for tests) -------------------------------------

// Strip JSONC line/block comments, string-aware (never inside a "..." literal).
function stripComments(text) {
  let out = "", inStr = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      out += c;
      if (c === "\\") { if (i + 1 < text.length) { out += text[i + 1]; i++; } continue; }
      if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === "/" && text[i + 1] === "/") { i += 2; while (i < text.length && text[i] !== "\n") i++; out += "\n"; continue; }
    if (c === "/" && text[i + 1] === "*") { i += 2; while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i++; continue; }
    out += c;
  }
  return out;
}

// Remove trailing commas ( , before } or ] ), string-aware.
function stripTrailingCommas(text) {
  let out = "", inStr = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      out += c;
      if (c === "\\") { if (i + 1 < text.length) { out += text[i + 1]; i++; } continue; }
      if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === ",") {
      let j = i + 1;
      while (j < text.length && /\s/.test(text[j])) j++;
      if (j < text.length && (text[j] === "}" || text[j] === "]")) continue; // drop it
    }
    out += c;
  }
  return out;
}

// JSONC-tolerant sanity parse: strip comments + trailing commas, then JSON.parse.
// Returns the parsed value; throws on genuinely invalid JSON.
function jsoncSanityParse(text) {
  return JSON.parse(stripTrailingCommas(stripComments(text)));
}

// Index of the last non-whitespace, non-comment char in text[0..limit), scanning
// string- and comment-aware. -1 if none.
function lastSignificantBefore(text, limit) {
  let inStr = false, lastSig = -1;
  for (let i = 0; i < limit; i++) {
    const c = text[i];
    if (inStr) {
      if (c === "\\") { i++; lastSig = i < limit ? i : lastSig; continue; }
      if (c === '"') inStr = false;
      lastSig = i;
      continue;
    }
    if (c === '"') { inStr = true; lastSig = i; continue; }
    if (c === "/" && text[i + 1] === "/") { i += 2; while (i < limit && text[i] !== "\n") i++; continue; }
    if (c === "/" && text[i + 1] === "*") { i += 2; while (i < limit && !(text[i] === "*" && text[i + 1] === "/")) i++; i++; continue; }
    if (/\s/.test(c)) continue;
    lastSig = i;
  }
  return lastSig;
}

// Regex for the managed property (key + colon + value). The value alternative
// matches a JSON string OR a bareword (null/true/number) so any prior value the
// user may have hand-set is handled.
const PROP_RE = new RegExp(
  '("' + MANAGED_KEY.replace(/\./g, "\\.") + '"\\s*:\\s*)("(?:[^"\\\\]|\\\\.)*"|[^,}\\s]+)'
);

// Set chatgpt.cliExecutable to exePath by text splice, preserving the rest
// byte-exact. Idempotent when the key is already present (replaces just its
// value). Throws only if the text has no object closing brace.
function spliceEnable(text, exePath) {
  const value = JSON.stringify(exePath); // quoted + backslash-escaped
  if (PROP_RE.test(text)) {
    return text.replace(PROP_RE, (m, head) => head + value);
  }
  // Insert before the final closing brace, after the last significant char.
  const closeIdx = lastSignificantBefore(text, text.length);
  if (closeIdx < 0 || text[closeIdx] !== "}") {
    throw new Error("settings.json: no object closing brace found — refusing to edit");
  }
  const k = lastSignificantBefore(text, closeIdx);
  const lastChar = k >= 0 ? text[k] : "{";
  const sep = (lastChar === "," || lastChar === "{") ? "" : ",";
  const NL = text.includes("\r\n") ? "\r\n" : "\n";
  let indent = "  ";
  const im = text.match(/\n([ \t]+)"/);
  if (im) indent = im[1];
  const insertAt = k >= 0 ? k + 1 : 0;
  const prop = sep + NL + indent + '"' + MANAGED_KEY + '": ' + value;
  return text.slice(0, insertAt) + prop + text.slice(insertAt);
}

// Remove the managed property (and the comma it owns) by text splice. If the key
// is absent, returns text unchanged.
function spliceDisable(text) {
  const m = PROP_RE.exec(text);
  if (!m) return text;
  const keyStart = m.index;
  const valEnd = m.index + m[0].length;

  // Owns a trailing comma? -> whole property line goes.
  let t = valEnd;
  while (t < text.length && (text[t] === " " || text[t] === "\t")) t++;
  if (text[t] === ",") {
    let removeStart = keyStart;
    while (removeStart > 0 && (text[removeStart - 1] === " " || text[removeStart - 1] === "\t")) removeStart--;
    let removeEnd = t + 1;
    if (text[removeEnd] === "\r") removeEnd++;
    if (text[removeEnd] === "\n") removeEnd++;
    return text.slice(0, removeStart) + text.slice(removeEnd);
  }

  // No trailing comma (last or only property). Own the preceding comma if any.
  let p = keyStart - 1;
  while (p >= 0 && /\s/.test(text[p])) p--;
  if (p >= 0 && text[p] === ",") {
    // Remove from the preceding comma through the value, keeping the newline +
    // closing brace that follow byte-exact.
    return text.slice(0, p) + text.slice(valEnd);
  }
  // Only property: remove its whole line (leading indent + trailing newline).
  let removeStart = keyStart;
  while (removeStart > 0 && (text[removeStart - 1] === " " || text[removeStart - 1] === "\t")) removeStart--;
  let removeEnd = valEnd;
  if (text[removeEnd] === "\r") removeEnd++;
  if (text[removeEnd] === "\n") removeEnd++;
  return text.slice(0, removeStart) + text.slice(removeEnd);
}

// ---- CLI -------------------------------------------------------------------

function fail(msg) {
  console.error(`[codex-proxy-settings] ${msg}`);
  process.exit(1);
}

function atomicWrite(p, content) {
  const tmp = p + ".tmp-codex-proxy";
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, p);
}

function backupOnce(p) {
  const bak = p + ".press1-bak";
  if (!fs.existsSync(bak)) fs.copyFileSync(p, bak);
}

function cliEnable(exePath) {
  if (!exePath) fail("usage: node codex-proxy-settings.js enable <exePath>");
  if (!fs.existsSync(settingsPath)) fail(`settings.json не найден: ${settingsPath}`);

  let orig;
  try { orig = fs.readFileSync(settingsPath, "utf8"); }
  catch (e) { fail(`не удалось прочитать ${settingsPath}: ${e.message}`); }

  // Parse the ORIGINAL first: needed for the WSL guard, and a file we cannot
  // parse is one we must not splice.
  let parsed;
  try { parsed = jsoncSanityParse(orig); }
  catch (e) { fail(`${settingsPath} содержит невалидный JSONC (${e.message}) — не редактирую.`); }
  if (parsed && typeof parsed === "object" && parsed[WSL_KEY] === true) {
    console.error(`[codex-proxy-settings] "${WSL_KEY}" = true — панель работает через WSL, а обёртка codex-mitm только для Windows (design §6). Не включаю.`);
    console.error("[codex-proxy-settings] Отключи WSL-режим в настройках Codex, затем повтори enable.");
    process.exit(2);
  }

  let next;
  try { next = spliceEnable(orig, exePath); }
  catch (e) { fail(`splice не удался: ${e.message}`); }

  try { jsoncSanityParse(next); }
  catch (e) { fail(`результат правки — невалидный JSONC (${e.message}); settings.json не тронут.`); }

  backupOnce(settingsPath);       // write-once, only on a real successful edit
  atomicWrite(settingsPath, next);
  console.log(`[codex-proxy-settings] "${MANAGED_KEY}" -> ${exePath}`);
  console.log(`[codex-proxy-settings] бэкап: ${path.basename(settingsPath)}.press1-bak (write-once)`);
}

function cliDisable() {
  if (!fs.existsSync(settingsPath)) {
    console.log(`[codex-proxy-settings] ${settingsPath} нет — нечего отключать.`);
    return;
  }
  let orig;
  try { orig = fs.readFileSync(settingsPath, "utf8"); }
  catch (e) { fail(`не удалось прочитать ${settingsPath}: ${e.message}`); }

  let next;
  try { next = spliceDisable(orig); }
  catch (e) { fail(`splice не удался: ${e.message}`); }

  if (next === orig) {
    console.log(`[codex-proxy-settings] "${MANAGED_KEY}" не задан — изменений нет.`);
    return;
  }
  try { jsoncSanityParse(next); }
  catch (e) { fail(`результат правки — невалидный JSONC (${e.message}); settings.json не тронут.`); }

  atomicWrite(settingsPath, next);
  console.log(`[codex-proxy-settings] "${MANAGED_KEY}" удалён из ${path.basename(settingsPath)}.`);
}

if (require.main === module) {
  const cmd = process.argv[2];
  const arg = process.argv[3];
  if (cmd === "enable") cliEnable(arg);
  else if (cmd === "disable") cliDisable();
  else {
    console.error("usage: node codex-proxy-settings.js enable <exePath> | disable");
    process.exit(1);
  }
}

module.exports = { spliceEnable, spliceDisable, jsoncSanityParse };
