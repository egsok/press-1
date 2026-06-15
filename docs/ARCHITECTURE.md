# Architecture — press-1

Актуально для: **v6.5 / Phase 8 + Codex Stage 2d (двухфазный гибрид) + экспериментальный прокси-канал панели (opt-in)** (companion-расширение дропнуто; **единый hook-decision канал** — один путь доставки для всех трёх сценариев: терминал редактора B, standalone A, панель C; **+ Codex CLI**: decision-канал = фаза 1 гибрида, по таймауту pending переписывается в native_control и попап живёт как «пульт» к нативному промпту — см. секцию ниже). Этот файл — контракт между компонентами. Обновляется только при изменении протокола.

## Компоненты

| Компонент | Файл | Роль |
|---|---|---|
| **Hook** | `permission-request.js` → `~\.claude\hooks\` | PermissionRequest hook Claude Code. Пишет pending-файл, играет звук. Для permission-промптов на decision-хостах (терминал редактора, панель, WT, conhost) блокирующе ждёт decision-файл до 60 мин с early-exit при исчезновении собственного pending. Никогда не ломает Claude Code (все ошибки проглатываются). |
| **Teardown hook** | `session-teardown.js` → `~\.claude\hooks\` | Один файл на два события: PostToolUse + Stop. Удаляет pending-файлы своей `session_id` — сигнал «промпт больше не ждёт» для случаев, где ответ дан прямо в TUI/нативном боксе. |
| **AHK-роутер** | `press-1.ahk` → `~\scripts\` | Резидентный. Глобальные хоткеи (F13–F24, Ctrl+Win+1-3), popup (auto-show 500ms), запись decision-файлов, фокусировка окон. Диспетчеризация по `kind × host`; permission на любом decision-хосте → decision-слово (Win32-доставка удалена, резолв окна остался только для фокуса пикеров). Исключение: opt-in `native_control` для Codex-панели отправляет цифру `1/2/3` в родной webview после fail-closed фокус-проверки. |

**Дроп companion-расширения (Phase 8).** Раньше сценарий B (терминал редактора) шёл через companion-расширение: скрейп вывода терминала (proposed API `terminalDataWriteEvent`), запись `prompts`-metadata, доставка через `terminal.sendText()`. В стабильных сборках форков VS Code (Cursor, Windsurf/Devin) этот proposed API **заблокирован** для sideloaded-расширений (доказано логами Extension Host). Расширение удалено целиком; терминал редактора (`vscode-terminal`, включая форки) переведён на тот же hook-decision канал, что A и C. Прежний протокол `prompts/*.json` и `response-*.txt` больше не существует.

## Пять стадий жизненного цикла × decision-канал (единый для B/A/C)

| Стадия | B: терминал редактора (VS Code / Cursor / Devin) | A: standalone terminal (WT/conhost) | C: панель расширения |
|---|---|---|---|
| **Детекция** (реальный промпт ждёт) | Hook pending (`host.type=vscode-terminal`); фантомов нет — hook фиреится только на реальные промпты (S1) | Hook pending (`host.type=windows-terminal\|conhost`); фантомов нет (S1). Liveness-gate: AHK скрывает И удаляет pending, чьё top-level окно/процесс умерли | Hook pending (`host.type=vscode-extension`); фантомов нет. В auto-режиме классификатор отвечает сам, hook молчит |
| **Идентификация** (какое окно) | **Не нужна для доставки** (decision-файл адресован hook-процессу по id). Для picker-фокуса — `editor_exe` (basename `VSCODE_GIT_ASKPASS_NODE`: `Code.exe`/`Cursor.exe`/`Devin.exe`) → окно нужного редактора по заголовку | **Не нужна для доставки.** Для liveness-gate и фокуса — `host` fingerprint (ancestry/top_level_pid/hwnd — gated walk для WT/conhost): глиф-скан окон exe → hwnd → PID-скан ancestry | Не нужна для доставки. Для picker-fallback — fuzzy-match заголовка окна по project_name (`FindVSCodeByName`) |
| **Презентация** | AHK popup, без бейджа; permission → кнопки по options-подсказке хука (2 или 3), picker → attention-строка | Тот же popup, бейдж «WT»/«console» | Тот же popup, бейдж «panel» |
| **Доставка** | `response-hook-<id>.txt` (слово allow/always/deny/pass) → hook возвращает `hookSpecificOutput.decision`, ядро CC применяет (S10). Фокус и клавиатура не используются; фоновый таб/свёрнутое окно работают. Picker: WinActivate окна редактора по `editor_exe` | `response-hook-<id>.txt` → `hookSpecificOutput.decision`. Picker: WinActivate терминала (глиф-скан/hwnd/PID) | `response-hook-<id>.txt` → `hookSpecificOutput.decision`. Picker: WinActivate + best-effort chord |
| **Очистка** | Hook удаляет pending+decision при выходе (ответ/pass/таймаут 60 мин); teardown (PostToolUse/Stop) и hook-liveness по `hook_pid` удаляют pending → hook early-exit; орфаны убитого хука — по `wait_until`+2 с и 90-мин backstop | Как B + liveness-gate (окно/процесс умерли → pending удалён) | Как B (нет liveness-gate — нет walk) |

**Охват терминала редактора (важно).** Hook фиреится на **permission + hook-пикеры (AskUserQuestion / ExitPlanMode)** — ровно это и покрывает попап. Scrape-only состояния, которые раньше ловило ТОЛЬКО расширение — slash-меню (`/model`/`/resume`/`/agents`/`/help`) и свободный ввод (`kind=text`, «ctrl-g to edit») — больше не всплывают в попапе и отвечаются прямо в TUI. Паритета «все промпты терминала» нет — by design.

## Codex CLI (Phase 6, Stage 2d — двухфазный гибрид на decision-канале)

Codex CLI скопировал систему хуков Claude почти дословно (snake_case payload, тот же `hookSpecificOutput.decision.behavior`, события `Stop`/`PostToolUse`). press-1 переиспользует **тот же файловый протокол** (`%TEMP%\press-1\pending` + `response-hook-*.txt`) и **те же AHK-роутер и popup** — pending'и Claude и Codex сосуществуют, различаются полем `agent` (`claude`|`codex`); session_id не коллизят.

| Компонент | Файл | Отличие от Claude |
|---|---|---|
| **Codex hook** | `codex-permission-request.js` → `~\.codex\hooks\` | `agent:"codex"`; **всегда 3 кнопки** (нет `permission_suggestions`); БЕЗ `updatedPermissions` (Codex его отвергает); **двухфазный гибрид** (см. ниже): окно фазы 1 `PRESS1_CODEX_HYBRID_WAIT_MS` (15 с дефолт) → rewrite pending в `native_control` → exit; decision-only-окно `PRESS1_CODEX_WAIT_MS` (60 с дефолт); **кламп обоих окон 60000** = `70000 (outer) − 4000 (звук) − 3000 (walk) − 3000 (запас)`; `wait_until` при записи несёт +4 с звукового бюджета; codex-`classifyHost` (нет `CLAUDE_CODE_ENTRYPOINT` → панель по `VSCODE_PID`, fallback `conhost`); walk только для WT |
| **Teardown** | `session-teardown.js` → `~\.codex\hooks\` | тот же файл, зарегистрирован на Codex `Stop`+`PostToolUse` |
| **Proxy-обёртка (opt-in, экспериментально)** | `codex-mitm.js` → SEA `.exe` в `~\scripts\` (сборка `enable-codex-proxy.ps1`) | stdio-MITM между расширением панели и бандл-бинарём `codex app-server` (подмена через `chatgpt.cliExecutable`). Прокси-канал панели: см. секцию ниже + [DESIGN-CODEX-PROXY.md](DESIGN-CODEX-PROXY.md) |
| **Merge/trust** | `merge-codex-hooks.js` | пишет `~\.codex\hooks.json` в **wrapper-схеме** `{"hooks":{…}}`; чужие top-level ключи **УДАЛЯЕТ** (Codex `HooksFile` = serde `deny_unknown_fields` → любой не-`hooks` ключ ломает ВЕСЬ файл, доказано на дыме — не «инертны»; сайдкар `.disabled-by-press-1` write-once, это удаление, НЕ миграция); PermissionRequest несёт `statusMessage` («press-1: hotkey …») — TUI показывает его во время фазы 1; **авто-trust** `trusted_hash` в `config.toml` через `codex app-server`/`hooks/list` (best-effort, фоллбэк — ручной `/hooks`) |

**Три отличия протокола Codex (доказаны эмпирически, RESEARCH-CODEX §16–17):**
1. **Блокирующий гейт, нет `Promise.race`.** Пока хук ждёт — нативный промпт Codex **невидим** (в TUI/панели), виден только popup press-1. Поэтому окно ограничено, а timeout хука в `hooks.json` — **70 с** (не Claude-3660): зависший хук обязан умереть за предсказуемое время, чтобы pass-through показал нативный промпт. Гибрид (ниже) снимает главный минус: попап больше не умирает на pass-through.
2. **«Always allow» — через rules-файл, не через хук.** На слове `always` хук возвращает allow И дописывает `prefix_rule(pattern=[<полные токены команды>], decision="allow")` в `~/.codex/rules/default.rules` (формат TUI-дефолта; live-reload без рестарта). Аппенд синхронный, до вывода allow, изолирован (ошибка не ломает allow). Лимит: pwsh-обёрнутые shell-команды — benign no-op.
3. **Trust.** Command-хуки Codex не исполняются без `trusted_hash` в `config.toml`. install авто-затрастит (matched по `source=user`+filename-в-command из `hooks/list`); ручной `/hooks` — фоллбэк.

**Двухфазный гибрид (Stage 2d, дефолт).** Источник истины по режимам — `codexMode(hostType)` в хуке:

| Конфигурация | Режим |
|---|---|
| дефолт | **hybrid**: фаза 1 — блокирующее ожидание decision-файла (15 с; ответ хоткеем без фокуса, иммунно к числу сессий; Esc = `pass` = мгновенный handoff); по таймауту хук **атомарно переписывает** свой pending (`native_control:true`, без `decision_file`, `wait_until` = TTL `PRESS1_CODEX_NATIVE_CONTROL_WAIT_MS`, дефолт 5 мин; тот же `id` → карточка морфится на месте, без ре-шоу и звука) и выходит `0` без stdout → нативный промпт появляется, строка попапа живёт «пультом» (фаза 2) |
| `PRESS1_CODEX_NATIVE_CONTROL=0` | **decision-only**: фаза 1 (окно 60 с), по таймауту pending удаляется — прежнее поведение |
| `=1` / флаг `~/.press-1-codex-native-control` | **native-only** для панели (фаза 1 пропускается — прежний спайк); на `vscode-terminal`/`windows-terminal` = hybrid; `conhost` всегда decision-only (нет walk → нет данных окна для фазы 2) |

**Фаза 2 по хостам (хук уже вышел, hook-liveness не применяется):** панель → fail-closed цифра в webview (`SendCodexNativeDecision`): guard единственности live-pending на target-окно (доставка НЕ row-addressed — 2+ промпта на окно → только фокус+tooltip), окно неактивно → gentle-активация БЕЗ отправки (второй хоткей или цифра руками); `windows-terminal` → фокус при ровно одном окне с титулом `[ ! ] Action Required` (`IsCodexActionTitle`/`PickCodexActionHwnd`) ЛИБО единственном окне терминала вообще (`ResolveCodexStandaloneTarget`), иначе tooltip без фокуса; `vscode-terminal` → gentle-фокус редактора по `editor_exe`+`project_name`; цифра в терминалы слепо НЕ шлётся (TUI принимает 1–3 first-class). Очистка: **отправка цифры pending НЕ удаляет** (дым CX4: цифра падает туда, где внутренний фокус webview — inline-поле фидбека съедает её текстом; оптимистичное удаление гасило попап при неотвеченном нативе) — владельцы очистки те же, что при ручном ответе в нативе: teardown по approve, TTL `wait_until` (standalone-ветка ТОЖЕ удаляет файл по TTL); нативный deny/cancel хук-событий не даёт → строка живёт до TTL (принято). Гонка перехода закрыта с двух концов: финальная перечитка decision-файла в хуке + `WriteHookDecision` перечитывает pending и отказывает, если тот уже `native_control`. Esc-подавление попапа — по подмножеству закрытых `prompt_id` (`AllDismissed`), не по точной сигнатуре: умирающие pass-строки не переоткрывают попап с выжившими native-строками.

**Бейдж.** `P1_HostBadge(agent, host)` для Codex даёт `codex·panel/term/WT/console`; бейдж — в answer-тост (`ShowTip`) и Focus-кнопку, НЕ на permission-карточку (host-pill снят с Phase 5.5). Focus-лейбл решается `IsPanelHost(host)`, не строкой бейджа.

## Экспериментальный прокси-канал Codex-панели (opt-in, выключен по умолчанию)

Включается `enable-codex-proxy.ps1` (сборка SEA `.exe` + `chatgpt.cliExecutable` → `~\scripts\codex-mitm.exe` с бэкапом settings.json), выключается `disable-codex-proxy.ps1`. Дизайн, решения и направления отказа — [DESIGN-CODEX-PROXY.md](DESIGN-CODEX-PROXY.md); гейты доказаны вживую (RESEARCH-CODEX §19). Контракт:

- **Обёртка** (`codex-mitm`): байт-точный релей stdio в обе стороны (relay-first — инжектор физически не может сломать транзит), динамический резолв свежайшего бандла `openai.chatgpt-*`, fail-loud exit 127 без бинаря, деградация в чистый pass-through при недоступном control-dir. На `requestApproval` публикует pending (атомарно), на `serverRequest/resolved` (ответил кто угодно) удаляет pending+decision; на exit подчищает свои файлы.
- **Протокол** `press1.codex.proxy/1`: pending `%TEMP%\press-1\proxy\<pid>-<requestId>.pending.json` (`command`/`cwd`/`reason`/`availableDecisions`/`proposedExecpolicyAmendment` + `threadId`/`turnId`/`itemId`/`requestId`, `agent:"codex"`, `channel:"proxy"`); decision `<pid>-<requestId>.decision.json` = `{"decision": "accept" | "cancel" | {acceptWithExecpolicyAmendment:{execpolicy_amendment:[…]}}}` (amendment — байт-точный эхо серверного предложения). Fail-closed адресация парой `(pid, requestId)`.
- **AHK**: читает proxy-дир тем же 200-мс refresh'ем; адаптер строит строку попапа (`project_name` = basename(cwd), `exec(<command>)`, кнопки из `availableDecisions`: 3 = Allow/Always/Deny, 2 = Allow/Deny), `WriteProxyDecision` пишет JSON атомарно; исчезновение pending = карточка снята (штатный reconcile). Focus-роутинга у proxy-строк нет (Esc = локальный dismiss, ответ руками в панели остаётся доступен — passthrough). Бейдж `codex·proxy`.
- **Арбитраж каналов**: обёртка выставляет `PRESS1_PROXY=1` дочернему app-server **только при живом control-dir**; hook-процессы наследуют → `codex-permission-request.js` молча выходит (дубль карточек исключён). Codex CLI в терминале переменную не видит — hook-канал для него живёт. Самовосстановление: прокси мёртв/выпилен → env нет → hook-канал панели возвращается сам.
- **Семантика Deny**: в панельных `availableDecisions` нет `decline` — Deny = `cancel` = обрыв тёрна (Esc-семантика), команда не выполняется. Нативная «No + фидбек» — только руками в карточке.

## Файловый протокол (`%TEMP%\press-1\`)

```
press-1/
├── pending/<timestamp>-<rand>.json     ← hook (один файл на permission request / picker)
├── response-hook-<id>.txt              ← AHK (decision-слово; hook поллит 100 мс и удаляет; отсутствует в Codex native-control)
└── proxy/                              ← opt-in прокси-канал Codex-панели (схема press1.codex.proxy/1, см. секцию выше)
    ├── <pid>-<requestId>.pending.json  ← codex-mitm (approval, атомарно; удаляется на resolved/exit)
    └── <pid>-<requestId>.decision.json ← AHK ({"decision":…}; обёртка поллит 80 мс, удаляет оба на resolved)
```

Все записи JSON — атомарные (tmp + rename; `.tmp` не попадает в `*.json`-глобы читателей). Decision-файл пишется AHK атомарно (tmp + move) — хук читает слово целиком.

### pending/*.json — schema v2 (текущая)

```json
{
  "schema": 2,
  "id": "1718904234567-abc123",
  "agent": "claude",
  "timestamp": 1718904234567,
  "project_name": "press-1",             // basename(cwd)
  "cwd": "D:/dev/press-1",
  "session_id": "...",
  "tool_name": "Bash",
  "tool_input_short": "npm test",        // первые 200 символов, одна строка
  "kind": "permission | picker",         // picker = AskUserQuestion/ExitPlanMode (NO_DECISION_TOOLS)
  "options": ["Allow", "Always allow", "Deny"],  // подсказка раскладки TUI; 3 опции ⇔ permission_suggestions непуст; [] для picker
  "decision_file": "C:\\...\\press-1\\response-hook-<id>.txt",  // permission × decision-хост
  "native_control": false,               // true = фаза 2 Codex-гибрида (хук переписал pending по таймауту окна и вышел) либо panel-only native-only режим; нет decision_file, AHK — «пульт» (панель: цифра в webview; терминалы: фокус)
  "wait_until": 1718904244567,           // дедлайн ожидания хука (ms epoch); permission × decision-хост
  "claude_pid": 12345,                   // process.ppid хука (эфемерный, legacy tiebreaker)
  "hook_pid": 6444,                      // PID самого хука = liveness-якорь decision-канала (см. риск 4)
  "host": {
    "type": "vscode-terminal | vscode-extension | windows-terminal | conhost | unknown",
    "entrypoint": "claude-vscode | cli | пусто",   // env CLAUDE_CODE_ENTRYPOINT
    "term_program": "vscode | пусто",              // env TERM_PROGRAM
    "wt_session": "guid | пусто",                  // env WT_SESSION
    "editor_exe": "Code.exe | Cursor.exe | Devin.exe | пусто",  // basename VSCODE_GIT_ASKPASS_NODE; фокус пикера терминала редактора
    "ancestry": [{ "pid": 50164, "exe": "bash.exe" }],  // от хука вверх, до explorer/services
    "top_level_pid": 41536,
    "top_level_exe": "WindowsTerminal.exe",
    "hwnd": 1379892,                     // первое окно по цепочке СВЕРХУ ВНИЗ (conhost: окно атрибутировано клиенту cmd.exe); 0 если нет
    "title": "",                         // зарезервировано; захват удалён (хук живёт в скрытой консоли враппера)
    "walk_ms": 1158                      // 0 = walk не запускался
  }
}
```

**Классификация host.type — порядок проверок load-bearing:** `entrypoint=claude-vscode` → `vscode-extension`; иначе `term_program=vscode` → `vscode-terminal`; иначе `wt_session` непуст → `windows-terminal`; иначе `entrypoint=cli` → `conhost`; иначе `unknown`. Entrypoint ставится самим claude по способу запуска и бьёт унаследованные переменные терминала; `TERM_PROGRAM` бьёт `WT_SESSION`, потому что VS Code, запущенный ИЗ Windows Terminal, протекает `WT_SESSION` в свои интегрированные терминалы. **Форки (Cursor/Devin) тоже отдают `TERM_PROGRAM=vscode` → `vscode-terminal`** — отдельная детекция форка не нужна; `editor_exe` различает их только для фокуса пикеров.

**Гейт ancestry (решение 2026-06-11):** fingerprint пишется всегда (бесплатно); синхронный walk (~1.0–1.2 с, PowerShell-снапшот CIM) — только для `windows-terminal`/`conhost`, где ancestry потребляется (liveness-gate и фокус-кнопки). VS Code-хосты (терминал и панель) walk пропускают: decision-канал не требует окна, picker-фокус идёт по `editor_exe`+заголовку — ежедневные промпты остаются мгновенными.

### Hook-decision канал (единый для B/A/C; S8 — панель, S10 — терминальный TUI)

Permission-промпт закрывается решением самого хука — без фокуса и клавиатуры. S8 доказал механизм для панели, S10 — для терминального TUI: `Promise.race(хук↔UI)` — поведение ядра Claude Code, общее для **всех** хостов (включая терминал редактора).

1. Hook видит `kind=permission` + decision-хост (`vscode-terminal` | `vscode-extension` | `windows-terminal` | `conhost`) → пишет pending с `decision_file`/`wait_until` и **блокирующе поллит** decision-файл (100 мс, всего 60 мин / `PRESS1_DECISION_WAIT_MS`). **Early-exit:** в той же петле хук проверяет существование собственного pending-файла; teardown (ответ в TUI/боксе) или AHK liveness-gate (окно терминала умерло) удаляют pending → хук выходит сразу, не досиживая окно. Decision-файл проверяется первым — решение, написанное в один тик с teardown, побеждает (безопасное направление: это реальный ответ пользователя).
2. AHK показывает строку с бейджем хоста (терминал редактора — без бейджа; «WT»/«console»/«panel» — для прочих) и кнопками по options-подсказке pending'а (3-опционный бокс → `1·Allow / 2·Always allow / 3·Deny`; 2-опционный «1 Yes / 2 No» → `1·Allow / 2·Deny`); хоткей атомарно (tmp+move) пишет слово `allow|always|deny` в decision-файл и показывает тост-атрибуцию. **Маппинг цифра→слово зеркалит раскладку**: на 2-опционном боксе `2`→`deny`; `3`→`deny` на любой раскладке. Esc/закрытие popup пишет `pass`.
3. Hook читает слово, удаляет pending+decision и возвращает на stdout:
   - `allow` → `{"decision":{"behavior":"allow"}}`
   - `always` → allow + `updatedPermissions` = echo `permission_suggestions` из payload (тот же тип `PermissionUpdate`; правило персистится как родная кнопка «Always allow»)
   - `deny` → `{"behavior":"deny","message":"Denied by user via press-1 hotkey"}`
   - `pass`/таймаут/early-exit → exit 0 без вывода → нативный box / TUI-промпт остаётся ждать (штатный путь любого не-decision хоста).
4. Семантика на стороне CC: `Promise.race([hook-decision, ответ в UI])`. Нативный box / TUI-промпт рендерится сразу и остаётся рабочим всё время ожидания — пользователь может ответить в нём, и его ответ побеждает. **Проигравший хук CC убивает** (без graceful exit) — его pending-орфан убирает AHK по `hook_pid` (см. риск 4).

**Требование конфига (load-bearing):** per-hook `timeout` в `~\.claude\settings.json` обязан быть **больше** окна ожидания (сейчас 3660 с > 3600 с). Меньший timeout молча обрубает приём decision: popup работает, хук отдаёт ответ, CC игнорирует.

Слово `always` без `permission_suggestions` деградирует до простого allow. Pending живёт ровно столько, сколько хук ждёт: его наличие = «ещё можно ответить» (AHK отказывается писать decision, если pending исчез). AskUserQuestion/ExitPlanMode → `kind=picker`: хук не отвечает решением, а блокируется как **маяк живости** (`waitForPendingGone`, до 60 мин), AHK показывает attention-строку, хоткей = WinActivate нужного окна (терминал редактора — по `editor_exe`; standalone — по глиф-скану; панель — по заголовку). **Для ExitPlanMode chord подавлён** (его approval-бокс живёт во вкладке plan-preview, а не в чат-панели).

### Фокус-хелперы (только для пикеров; промахи безопасны)

Доставка ответа решением не требует окна. Фокус нужен лишь для picker-строк и кнопки 🔍:

- **Терминал редактора** (`vscode-terminal`): `FindEditorByName(project_name, editor_exe)` — предпочитает окно конкретного редактора (`Code.exe`/`Cursor.exe`/`Devin.exe`) по `editor_exe`, фоллбэк — кросс-редакторный список по заголовку. `EditorWindowList`/`IsEditorTitle` покрывают все три редактора (Windsurf — `Devin.exe` после ребренда; `Windsurf.exe` оставлен для старых сборок).
- **Панель** (`vscode-extension`): `FindVSCodeByName` (fuzzy заголовок по project_name), gentle-активация (без Alt-dance — иначе focus-война между панелями).
- **Standalone** (`windows-terminal`/`conhost`): `ResolveStandaloneHwnd` — глиф-скан окон `top_level_exe` («✳ …» = окно с активным claude-табом) → сохранённый `hwnd` → PID-скан сверху вниз по ancestry (conhost: окно атрибутировано клиенту cmd.exe).

### Teardown-канал

`session-teardown.js` регистрируется на **PostToolUse** (без matcher — все тулы) и **Stop**. Оба события означают «промпт этой сессии больше не ждёт»: PostToolUse — разрешённый tool отработал, Stop — ход завершён. Хук удаляет все pending с совпадающим `session_id`. Это закрывает зомби-строки после ответа в TUI/нативном боксе. **Отмену** промпта (Esc) ни PostToolUse, ни Stop не фаерят — её ловит хук-маяк: живой хук = промпт ждёт, CC убивает хук при ответе И отмене → AHK роняет строку по мёртвому `hook_pid`.

Владельцы жизненного цикла pending по хостам (теперь единообразно — decision/маяк-хук во всех случаях):

| host.type | Удаляет при ответе | Орфан-очистка |
|---|---|---|
| `vscode-terminal` / `vscode-extension` × permission | hook при выходе (ответ/pass/таймаут 60 мин); teardown при ответе в TUI/боксе → early-exit хука | AHK hook-liveness по `hook_pid` (CC убил проигравший хук → файл удаляется в ближайший тик); скрытие по `wait_until`+2 с; 90-мин backstop |
| Codex × permission × `native_control` (фаза 2 гибрида: панель/vsterm/WT; или panel-native-only) | teardown при approve (в т.ч. после доставленной цифры); TTL по `wait_until` (standalone-ветка ТОЖЕ удаляет файл по TTL); **same-session cleanup** — новый промпт той же `session_id` удаляет прежние codex-pending при записи (interrupt/Esc в TUI не фаерит teardown-событий; без этого ретраи копят карточки-трупы, и FIFO-активная строка бьёт в мусор) | hook-liveness **не применяется** (hook вышел by design); liveness-gate окна для WT остаётся; неоднозначность (2+ pending на окно / окно не найдено / не активно) → цифра не шлётся, pending живёт до TTL, пользователь отвечает в native UI |
| `vscode-terminal` / `vscode-extension` × picker | хук-маяк блокируется (`waitForPendingGone`, до 60 мин); teardown при ответе → маяк освобождается | AHK hook-liveness по `hook_pid` (CC убивает маяк при ответе И отмене — teardown отмену не ловит); dead-session picker — 90-мин backstop |
| `windows-terminal` / `conhost` × permission | hook при выходе; teardown при ответе в TUI → early-exit | AHK hook-liveness по `hook_pid`; AHK liveness-gate (окно/процесс умерли → файл удаляется → early-exit); `wait_until`+2 с; 90-мин backstop |
| `windows-terminal` / `conhost` × picker | хук-маяк блокируется; teardown при ответе → маяк освобождается | AHK hook-liveness; AHK liveness-gate; 90-мин backstop |

Backstop отображения pending-строк (`STANDALONE_BACKSTOP_MS` = 90 мин) — только crash-страховка; обязан превышать окно ожидания хука (60 мин). Принятая гонка: при параллельных tool-вызовах PostToolUse тула A может удалить живой pending тула B той же сессии — направление отказа безопасно (строка исчезает, пользователь отвечает в TUI; ответ никогда не перенаправляется).

## Ключевые механизмы

- **Анти-фантом = S1**: hook фиреится только на реальные промпты (auto-allowed тулы pending не создают). Поэтому каждый pending-файл — настоящий ждущий промпт; phantom-фильтры/скрейп-гейты не нужны.
- **Диспетчеризация по kind**: permission → decision-слово в decision-файл (без смены фокуса, на любом хосте); `native_control` Codex-панели → fail-closed отправка цифры `1/2/3` в единственное **title-matched** editor-window (чат панели на cwd ≠ workspace окна титулом не резолвится → фоллбэк `ResolveCodexPanelFallback`: единственное окно редактора активируется, цифра по фоллбэку НЕ шлётся — счёт «окно одно» это косвенная улика, не позитивная идентификация); picker/прочие → фокусировка нужного окна (по host: editor_exe / глиф-скан / заголовок). Цифра в picker слепо НЕ шлётся.
- **Dismiss-подпись**: `ComputeSignature` керится на `prompt_id` (= `id` pending'а, уникален per-хук). Закрытый пользователем popup не переоткрывается для того же набора промптов; новый промпт (новый id) busts подавление.
- **Раскладка цифр = раскладке TUI**: popup рендерит кнопки из `options` pending'а (`permission_suggestions` непуст ⇒ 3-опционный). При отсутствии подсказки — дефолт 3-опционный (худшая ошибка Deny-вместо-Always-allow — безопасное направление).

## Принятые риски

1. **`claude_pid` эфемерен** — это PID короткоживущего cmd/bash-враппера, запускающего hook; умирает за секунды. PID-walk — best-effort tiebreaker; для schema v2 ancestry собирается В хуке, пока цепочка жива.
2. **Блокирующий хук для decision-хостов (окно 60 мин)**: каждый permission-промпт терминала/панели/WT/conhost держит hook-процесс до 60 мин. Это не задерживает пользователя (box/TUI рендерится сразу, нативный ответ побеждает race мгновенно). Зомби и орфаны закрывают три механизма: (а) early-exit — teardown или liveness-gate удаляют pending → ждущий хук выходит; (б) **hook-liveness по `hook_pid`** — CC УБИВАЕТ проигравший race хук без graceful exit (TUI-deny/interrupt не фаерит ни PostToolUse, ни Stop), поэтому «pending есть, hook-процесса нет» = орфан → AHK гасит строку и файл; (в) скрытие по `wait_until`+2 с — пояс на случай переиспользованного PID.
3. **Связка таймаутов (load-bearing)**: окно ожидания хука (3600000 мс = 3600 с, `PRESS1_DECISION_WAIT_MS`) < `timeout` PermissionRequest-хука в settings.json (3660 с) < backstop отображения pending (`STANDALONE_BACKSTOP_MS` = 5400000 мс = 90 мин). Нарушение первого неравенства ломает доставку молча; backstop обязан превышать окно хука. **Единицы load-bearing:** `*_MS`-константы — миллисекунды, settings-`timeout` — секунды.
4. **Title-guard — историческое**: захват титула хуком невозможен (хук живёт в скрытой консоли враппера, `CREATE_NO_WINDOW`), поле `title` зарезервировано пустым; глиф-скан («✳ …») жив в `ResolveStandaloneHwnd` для выбора окна при фокусе standalone.

**Снят (Phase 8):** прежний риск №1 — proposed API `terminalDataWriteEvent`. Companion-расширение дропнуто, скрейп-зависимость устранена; терминал редактора идёт через decision-канал. Восстановимо `git revert`, если форки когда-нибудь откроют proposed API.

## Известные ограничения

Баги №2 (index-shift), №8 (коллизия одноимённых workspace) и №9 (claude в подпапке) закрыты schema v2. Остаточное:

- Охват терминала редактора — permission + hook-пикеры (scrape-only состояния не всплывают, см. выше) — by design.
- Ответ хоткеем возможен только в окне ожидания хука (60 мин); после таймаута строка гаснет, ответ руками в TUI/боксе. Per-monitor хоткеи (F16–F21) таргетируют только окна редакторов.
- Сценарий C при нескольких панельных вкладках в одном окне: **доставка decision иммунна к количеству вкладок** (роутинг per-pending по `decision_file`), но строки popup различимы только по tool_name/tool_input (project_name одинаков), а «Focus panel» фокусирует «какую-то» панель, не конкретную вкладку.
- Фаза 2 Codex-гибрида: доставка цифрой работает только для панели при единственном live-промпте на единственное активное title-matched окно (иначе фокус/tooltip); фаза 1 (decision-окно) от этих ограничений свободна. Нативный deny/cancel в фазе 2 не даёт хук-событий → строка живёт до TTL (5 мин дефолт; следующий промпт сессии убирает раньше — same-session cleanup). Титул `[ ! ]/[ . ] Action Required` подтверждён (CX-S7, 0.142.5): ставится в имя вкладки WT, но заголовок ОКНА зеркалит только активную вкладку — фоновую кроет фоллбэк «единственное окно exe». Панельное таргетирование слепо при cwd чата ≠ workspace окна (фоллбэк: единственное окно редактора, активация без отправки цифры).
- Несколько терминалов редактора с одновременными промптами в одном окне: доставка адресная (per-pending `decision_file`), но picker-фокус по `editor_exe` приводит к окну редактора, не к конкретному терминалу-вкладке.
