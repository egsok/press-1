// Тесты merge-hooks.js — изолированный TEMP, env-переопределения PRESS1_SETTINGS_PATH/PRESS1_HOOKS_DIR. Run: node tests/merge-hooks.test.js
const fs = require('fs'), path = require('path'), os = require('os');
const { spawnSync } = require('child_process');

const MERGE = path.join(__dirname, '..', 'merge-hooks.js');
const ROOT = path.join(os.tmpdir(), 'press-1-tests', 'merge');
const HOOKS_DIR = 'C:/Users/test/.claude/hooks';
const CMD_PERM = `node "${HOOKS_DIR}/permission-request.js"`;
const CMD_TD = `node "${HOOKS_DIR}/session-teardown.js"`;

fs.rmSync(ROOT, { recursive: true, force: true });
fs.mkdirSync(ROOT, { recursive: true });

let pass = 0, fail = 0;
const check = (name, cond) => { cond ? pass++ : fail++; console.log((cond ? 'PASS' : 'FAIL') + '  ' + name); };

function caseDir(name, content) {
  const dir = path.join(ROOT, name);
  fs.mkdirSync(dir, { recursive: true });
  if (content !== undefined) fs.writeFileSync(path.join(dir, 'settings.json'), content);
  return dir;
}
const run = (dir) => spawnSync('node', [MERGE], {
  env: { ...process.env, PRESS1_SETTINGS_PATH: path.join(dir, 'settings.json'), PRESS1_HOOKS_DIR: HOOKS_DIR },
  encoding: 'utf8',
});
const readRaw = (dir) => fs.readFileSync(path.join(dir, 'settings.json'), 'utf8');
const readJ = (dir) => JSON.parse(readRaw(dir));

// T1: чистая машина — settings.json нет
{
  const d = caseDir('t1');
  const r = run(d);
  const s = readJ(d);
  check('T1 exit 0', r.status === 0);
  check('T1 PermissionRequest добавлен', s.hooks.PermissionRequest?.[0]?.hooks?.[0]?.command === CMD_PERM);
  check('T1 PermissionRequest timeout 3660', s.hooks.PermissionRequest?.[0]?.hooks?.[0]?.timeout === 3660);
  check('T1 PostToolUse добавлен', s.hooks.PostToolUse?.[0]?.hooks?.[0]?.command === CMD_TD);
  check('T1 Stop добавлен', s.hooks.Stop?.[0]?.hooks?.[0]?.timeout === 5);
}

// T2: чужие хуки и настройки сохраняются
{
  const d = caseDir('t2', JSON.stringify({
    model: 'opus',
    permissions: { allow: ['Bash(git*)'] },
    hooks: {
      PostToolUse: [{ matcher: 'Edit|Write', hooks: [{ type: 'command', command: 'node "C:/foo/gsd-hook.js"' }] }],
      Stop: [{ hooks: [{ type: 'command', command: 'powershell -File C:/foo/gsd-stop.ps1' }] }],
    },
  }, null, 2));
  const r = run(d);
  const s = readJ(d);
  check('T2 exit 0', r.status === 0);
  check('T2 model сохранён', s.model === 'opus');
  check('T2 permissions сохранены', s.permissions.allow[0] === 'Bash(git*)');
  check('T2 чужой PostToolUse не тронут (matcher)', s.hooks.PostToolUse[0].matcher === 'Edit|Write'
    && s.hooks.PostToolUse[0].hooks[0].command.includes('gsd-hook.js'));
  check('T2 наш PostToolUse добавлен вторым', s.hooks.PostToolUse[1]?.hooks?.[0]?.command === CMD_TD);
  check('T2 чужой Stop не тронут', s.hooks.Stop[0].hooks[0].command.includes('gsd-stop.ps1'));
  check('T2 наш Stop добавлен', s.hooks.Stop[1]?.hooks?.[0]?.command === CMD_TD);
  check('T2 бэкап создан', fs.existsSync(path.join(d, 'settings.json.bak-press-1')));

  // T3: идемпотентность — второй прогон ничего не меняет
  const before = readRaw(d);
  const r2 = run(d);
  check('T3 второй прогон exit 0', r2.status === 0);
  check('T3 «изменений нет»', r2.stdout.includes('изменений нет'));
  check('T3 файл байт-в-байт', readRaw(d) === before);
}

// T4: апгрейд существующей записи (старый путь + реликтовый timeout)
{
  const d = caseDir('t4', JSON.stringify({
    hooks: {
      PermissionRequest: [{ hooks: [{ type: 'command', command: 'node "C:/Users/Old Name/.claude/hooks/permission-request.js"', timeout: 130 }] }],
    },
  }));
  const r = run(d);
  const s = readJ(d);
  check('T4 exit 0', r.status === 0);
  check('T4 command обновлён', s.hooks.PermissionRequest[0].hooks[0].command === CMD_PERM);
  check('T4 timeout поднят до 3660', s.hooks.PermissionRequest[0].hooks[0].timeout === 3660);
  check('T4 дубликат не создан', s.hooks.PermissionRequest.length === 1);
}

// T5: невалидный JSON — файл не тронут, exit 1
{
  const d = caseDir('t5', '{ broken json');
  const r = run(d);
  check('T5 exit 1', r.status === 1);
  check('T5 файл не тронут', readRaw(d) === '{ broken json');
  check('T5 бэкап не создан', !fs.existsSync(path.join(d, 'settings.json.bak-press-1')));
}

// T6: кастомный timeout >= 3660 уважается
{
  const d = caseDir('t6', JSON.stringify({
    hooks: { PermissionRequest: [{ hooks: [{ type: 'command', command: CMD_PERM, timeout: 4000 }] }] },
  }));
  const r = run(d);
  const s = readJ(d);
  check('T6 exit 0', r.status === 0);
  check('T6 timeout 4000 сохранён', s.hooks.PermissionRequest[0].hooks[0].timeout === 4000);
}

// T7: hooks.<event> не массив — fail loud, файл не тронут
{
  const raw = JSON.stringify({ hooks: { PermissionRequest: { bad: true } } });
  const d = caseDir('t7', raw);
  const r = run(d);
  check('T7 exit 1', r.status === 1);
  check('T7 файл не тронут', readRaw(d) === raw);
}

console.log(`\n${pass}/${pass + fail} passed${fail ? ' — FAILURES!' : ''}`);
process.exit(fail ? 1 : 0);
