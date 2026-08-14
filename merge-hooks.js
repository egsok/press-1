#!/usr/bin/env node
// press-1 — безопасный merge хуков в ~/.claude/settings.json.
// Добавляет/обновляет ТОЛЬКО свои записи (узнаёт их по имени файла скрипта в command),
// чужие хуки и прочие настройки не трогает. Запускается из install.ps1.
// Exit 1 = файл не тронут, хуки добавить вручную (см. README).
//
// Env-переопределения (для тестов): PRESS1_SETTINGS_PATH, PRESS1_HOOKS_DIR.

const fs = require('fs');
const path = require('path');
const os = require('os');

const settingsPath = process.env.PRESS1_SETTINGS_PATH
  || path.join(os.homedir(), '.claude', 'settings.json');
const hooksDir = process.env.PRESS1_HOOKS_DIR
  || path.join(os.homedir(), '.claude', 'hooks');

const cmdFor = (file) => `node "${path.join(hooksDir, file).replace(/\\/g, '/')}"`;

// timeout PermissionRequest load-bearing: должен быть БОЛЬШЕ окна ожидания хука
// (3600 с, PRESS1_DECISION_WAIT_MS) — иначе CC обрубает хук и decision теряется (см. README).
const WANTED = [
  { event: 'PermissionRequest', file: 'permission-request.js', timeout: 3660, enforceMin: true },
  { event: 'PostToolUse',       file: 'session-teardown.js',   timeout: 5,   enforceMin: false },
  { event: 'Stop',              file: 'session-teardown.js',   timeout: 5,   enforceMin: false },
];

function fail(msg) {
  console.error(`[merge-hooks] ${msg}`);
  console.error('[merge-hooks] settings.json не тронут. Добавь хуки вручную — см. README.');
  process.exit(1);
}

let settings = {};
if (fs.existsSync(settingsPath)) {
  let raw;
  try { raw = fs.readFileSync(settingsPath, 'utf8'); }
  catch (e) { fail(`не удалось прочитать ${settingsPath}: ${e.message}`); }
  try { settings = JSON.parse(raw); }
  catch (e) { fail(`${settingsPath} содержит невалидный JSON: ${e.message}`); }
  if (typeof settings !== 'object' || settings === null || Array.isArray(settings)) {
    fail('корень settings.json — не объект.');
  }
}

if (settings.hooks == null) settings.hooks = {};
if (typeof settings.hooks !== 'object' || Array.isArray(settings.hooks)) {
  fail('поле "hooks" в settings.json — не объект.');
}

let changed = false;

for (const w of WANTED) {
  if (settings.hooks[w.event] == null) settings.hooks[w.event] = [];
  const groups = settings.hooks[w.event];
  if (!Array.isArray(groups)) fail(`hooks.${w.event} — не массив.`);

  const desired = cmdFor(w.file);
  let found = false;

  for (const group of groups) {
    if (!group || !Array.isArray(group.hooks)) continue;
    for (const h of group.hooks) {
      if (!h || typeof h.command !== 'string' || !h.command.includes(w.file)) continue;
      found = true;
      let action = 'ok';
      if (h.command !== desired) { h.command = desired; action = 'updated'; }
      if (h.type !== 'command') { h.type = 'command'; action = 'updated'; }
      if (w.enforceMin
        ? !(typeof h.timeout === 'number' && h.timeout >= w.timeout)
        : typeof h.timeout !== 'number') {
        h.timeout = w.timeout; action = 'updated';
      }
      if (action === 'updated') changed = true;
      console.log(`[merge-hooks] ${w.event}: ${action}`);
    }
  }

  if (!found) {
    groups.push({ hooks: [{ type: 'command', command: desired, timeout: w.timeout }] });
    changed = true;
    console.log(`[merge-hooks] ${w.event}: added`);
  }
}

if (changed) {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  if (fs.existsSync(settingsPath)) {
    fs.copyFileSync(settingsPath, settingsPath + '.bak-press-1');
  }
  const tmp = settingsPath + '.tmp-press-1';
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n');
  fs.renameSync(tmp, settingsPath);
  console.log(`[merge-hooks] записано: ${settingsPath} (бэкап: .bak-press-1)`);
} else {
  console.log('[merge-hooks] изменений нет.');
}
