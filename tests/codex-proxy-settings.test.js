// Тесты codex-proxy-settings.js — изолированный TEMP, env-переопределение
// PRESS1_VSCODE_SETTINGS. Юнит-тесты чистых splice/validate-функций + CLI через
// песочницу settings.json. Run: node tests/codex-proxy-settings.test.js
const fs = require("fs"), path = require("path"), os = require("os");
const { spawnSync } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "codex-proxy-settings.js");
const ROOT = path.join(os.tmpdir(), "press-1-tests", "proxy-settings");
const { spliceEnable, spliceDisable, jsoncSanityParse } = require(SCRIPT);

fs.rmSync(ROOT, { recursive: true, force: true });
fs.mkdirSync(ROOT, { recursive: true });

let pass = 0, fail = 0;
const check = (name, cond) => { cond ? pass++ : fail++; console.log((cond ? "PASS" : "FAIL") + "  " + name); };

const EXE = "C:\\Users\\test\\scripts\\codex-mitm.exe";

// longest common prefix / suffix — proves a splice only INSERTED or only DELETED
// a contiguous run (everything outside is byte-exact) when prefix+suffix covers
// the shorter string.
const cpre = (a, b) => { let i = 0; while (i < a.length && i < b.length && a[i] === b[i]) i++; return i; };
const csuf = (a, b) => { let i = 0; while (i < a.length && i < b.length && a[a.length - 1 - i] === b[b.length - 1 - i]) i++; return i; };

function caseDir(name, content) {
  const dir = path.join(ROOT, name);
  fs.mkdirSync(dir, { recursive: true });
  if (content !== undefined) fs.writeFileSync(path.join(dir, "settings.json"), content);
  return dir;
}
const spath = (dir) => path.join(dir, "settings.json");
const bakPath = (dir) => path.join(dir, "settings.json.press1-bak");
const readRaw = (dir) => fs.readFileSync(spath(dir), "utf8");
const run = (dir, ...cliArgs) => spawnSync("node", [SCRIPT, ...cliArgs], {
  env: { ...process.env, PRESS1_VSCODE_SETTINGS: spath(dir) },
  encoding: "utf8",
});

// ============================ UNIT: pure functions ==========================

// U1: enable into plain JSON — key added, valid, value correct.
{
  const src = '{\n  "editor.fontSize": 14\n}\n';
  const out = spliceEnable(src, EXE);
  const parsed = jsoncSanityParse(out);
  check("U1 key added", parsed["chatgpt.cliExecutable"] === EXE);
  check("U1 valid JSONC", typeof parsed === "object");
  check("U1 existing key preserved", parsed["editor.fontSize"] === 14);
  check("U1 byte-exact outside splice (insert only)", cpre(src, out) + csuf(src, out) >= src.length);
}

// U2: enable preserves comments + a trailing comma byte-exact outside the splice.
{
  const src = [
    "{",
    "  // top comment",
    '  "editor.fontSize": 14,',
    "  /* block",
    "     comment */",
    '  "files.autoSave": "off",', // NOTE: trailing comma on the last property
    "}",
    "",
  ].join("\n");
  const out = spliceEnable(src, EXE);
  const parsed = jsoncSanityParse(out);
  check("U2 key added", parsed["chatgpt.cliExecutable"] === EXE);
  check("U2 line comment intact", out.includes("// top comment"));
  check("U2 block comment intact", out.includes("/* block") && out.includes("comment */"));
  check("U2 sibling props intact", parsed["editor.fontSize"] === 14 && parsed["files.autoSave"] === "off");
  check("U2 byte-exact outside splice", cpre(src, out) + csuf(src, out) >= src.length);
  check("U2 result valid (trailing comma tolerated)", parsed["chatgpt.cliExecutable"] === EXE);
}

// U3: re-enable idempotent — value replaced in place, no duplicate key.
{
  const src = '{\n  "chatgpt.cliExecutable": "C:\\\\old\\\\codex-mitm.exe",\n  "a": 1\n}\n';
  const once = spliceEnable(src, EXE);
  const twice = spliceEnable(once, EXE);
  const parsed = jsoncSanityParse(once);
  check("U3 value replaced", parsed["chatgpt.cliExecutable"] === EXE);
  check("U3 no duplicate key", (once.match(/chatgpt\.cliExecutable/g) || []).length === 1);
  check("U3 re-enable is a no-op on identical value", once === twice);
  check("U3 sibling intact", parsed["a"] === 1);
}

// U4: enable into empty object.
{
  const out = spliceEnable("{}", EXE);
  check("U4 empty object -> key added", jsoncSanityParse(out)["chatgpt.cliExecutable"] === EXE);
}

// U5: disable removes key + owned comma, valid, comments intact, byte-exact outside.
{
  const src = [
    "{",
    "  // editor",
    '  "editor.fontSize": 14,',
    '  "chatgpt.cliExecutable": "C:\\\\x\\\\codex-mitm.exe",',
    "  /* proxy */",
    '  "files.autoSave": "off"',
    "}",
    "",
  ].join("\n");
  const out = spliceDisable(src);
  const parsed = jsoncSanityParse(out);
  check("U5 key removed", !("chatgpt.cliExecutable" in parsed));
  check("U5 no leftover key text", !out.includes("cliExecutable"));
  check("U5 siblings intact", parsed["editor.fontSize"] === 14 && parsed["files.autoSave"] === "off");
  check("U5 comments intact", out.includes("// editor") && out.includes("/* proxy */"));
  check("U5 result valid", typeof parsed === "object");
  check("U5 byte-exact outside splice (delete only)", cpre(src, out) + csuf(src, out) >= out.length);
}

// U6: disable when the property is the LAST one (owns the preceding comma).
{
  const src = '{\n  "a": 1,\n  "chatgpt.cliExecutable": "C:\\\\x\\\\codex-mitm.exe"\n}\n';
  const out = spliceDisable(src);
  const parsed = jsoncSanityParse(out);
  check("U6 key removed (last prop)", !("chatgpt.cliExecutable" in parsed));
  check("U6 sibling intact + valid", parsed["a"] === 1);
}

// U7: disable when the property is the ONLY one -> empty object, valid.
{
  const src = '{\n  "chatgpt.cliExecutable": "C:\\\\x\\\\codex-mitm.exe"\n}\n';
  const out = spliceDisable(src);
  check("U7 only prop -> valid empty object", Object.keys(jsoncSanityParse(out)).length === 0);
}

// U8: disable when key absent -> text unchanged.
{
  const src = '{\n  "a": 1\n}\n';
  check("U8 absent key -> unchanged", spliceDisable(src) === src);
}

// U9: enable then disable round-trips to the original (no trailing comma case).
{
  const src = '{\n  "a": 1,\n  "b": 2\n}\n';
  const round = spliceDisable(spliceEnable(src, EXE));
  check("U9 enable+disable round-trips byte-exact", round === src);
}

// U10: validator rejects genuinely broken JSON.
{
  let threw = false;
  try { jsoncSanityParse('{ "a": }'); } catch { threw = true; }
  check("U10 sanity parse throws on broken JSON", threw);
}

// U11: validator tolerates comments + trailing commas.
{
  const parsed = jsoncSanityParse('{ /* c */ "a": 1, "b": 2, } // tail\n');
  check("U11 sanity parse tolerates JSONC", parsed.a === 1 && parsed.b === 2);
}

// ================================ CLI cases =================================

// C1: enable into plain JSON via CLI — exit 0, key added, backup created once.
{
  const d = caseDir("c1", '{\n  "a": 1\n}\n');
  const r = run(d, "enable", EXE);
  check("C1 exit 0", r.status === 0);
  check("C1 key added", jsoncSanityParse(readRaw(d))["chatgpt.cliExecutable"] === EXE);
  check("C1 backup created", fs.existsSync(bakPath(d)));
  check("C1 backup == original", fs.readFileSync(bakPath(d), "utf8") === '{\n  "a": 1\n}\n');
}

// C2: re-enable — backup NOT overwritten, no duplicate key.
{
  const d = caseDir("c2", '{\n  "a": 1\n}\n');
  run(d, "enable", "C:\\first\\codex-mitm.exe");
  const bakAfterFirst = fs.readFileSync(bakPath(d), "utf8");
  const r2 = run(d, "enable", EXE);
  check("C2 re-enable exit 0", r2.status === 0);
  check("C2 backup unchanged (write-once)", fs.readFileSync(bakPath(d), "utf8") === bakAfterFirst);
  check("C2 value repointed", jsoncSanityParse(readRaw(d))["chatgpt.cliExecutable"] === EXE);
  check("C2 no duplicate key", (readRaw(d).match(/chatgpt\.cliExecutable/g) || []).length === 1);
}

// C3: disable via CLI — key removed, still valid, comments intact.
{
  const d = caseDir("c3", [
    "{",
    "  // keep me",
    '  "a": 1,',
    '  "chatgpt.cliExecutable": "C:\\\\x\\\\codex-mitm.exe",',
    '  "b": 2',
    "}",
    "",
  ].join("\n"));
  const r = run(d, "disable");
  check("C3 exit 0", r.status === 0);
  check("C3 key removed", !("chatgpt.cliExecutable" in jsoncSanityParse(readRaw(d))));
  check("C3 comment intact", readRaw(d).includes("// keep me"));
  check("C3 siblings intact", jsoncSanityParse(readRaw(d)).a === 1 && jsoncSanityParse(readRaw(d)).b === 2);
}

// C4: disable when key absent — quiet success, file unchanged, no backup.
{
  const src = '{\n  "a": 1\n}\n';
  const d = caseDir("c4", src);
  const r = run(d, "disable");
  check("C4 exit 0", r.status === 0);
  check("C4 file unchanged", readRaw(d) === src);
  check("C4 no backup written by disable", !fs.existsSync(bakPath(d)));
}

// C5: enable refuses on WSL flag = true -> exit 2, file untouched, no backup.
{
  const src = '{\n  "chatgpt.runCodexInWindowsSubsystemForLinux": true\n}\n';
  const d = caseDir("c5", src);
  const r = run(d, "enable", EXE);
  check("C5 exit 2 (WSL refusal)", r.status === 2);
  check("C5 file untouched", readRaw(d) === src);
  check("C5 no backup", !fs.existsSync(bakPath(d)));
}

// C6: corrupt original -> exit 1, file untouched, no backup, no write.
{
  const src = '{\n  "a": \n}\n';
  const d = caseDir("c6", src);
  const r = run(d, "enable", EXE);
  check("C6 exit 1 (corrupt original)", r.status === 1);
  check("C6 file untouched", readRaw(d) === src);
  check("C6 no backup", !fs.existsSync(bakPath(d)));
}

// C7: missing settings.json -> loud exit 1.
{
  const d = caseDir("c7"); // no file written
  const r = run(d, "enable", EXE);
  check("C7 exit 1 (missing file)", r.status === 1);
  check("C7 loud stderr", /не найден/.test(r.stderr));
  check("C7 file still absent", !fs.existsSync(spath(d)));
}

console.log(`\n${pass}/${pass + fail} passed${fail ? " — FAILURES!" : ""}`);
process.exit(fail ? 1 : 0);
