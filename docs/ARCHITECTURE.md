# Architecture — press-1

Актуально для: **v8.0 + Codex Stage 2d (двухфазный гибрид) + needs-user attention + экспериментальный прокси-канал панели (opt-in) + экспериментальный exact same-turn Auto-review bypass на всех стандартных Codex hook-поверхностях** (companion-расширение дропнуто; **единый hook-decision канал** — один путь доставки permission для трёх терминальных/панельных сценариев; отдельный focus-only attention-канал сообщает, когда Codex ждёт обычный ответ пользователя; точный `auto_review` может быть fail-safe передан родному reviewer до создания pending — см. секции ниже). Этот файл — контракт между компонентами. Обновляется только при изменении протокола.

## Компоненты

| Компонент | Файл | Роль |
|---|---|---|
| **Hook** | `permission-request.js` → `~\.claude\hooks\` | PermissionRequest hook Claude Code. Пишет pending-файл, играет звук. Для permission-промптов на decision-хостах (терминал редактора, панель, WT, conhost) блокирующе ждёт decision-файл до 60 мин с early-exit при исчезновении собственного pending. Никогда не ломает Claude Code (все ошибки проглатываются). |
| **Teardown hook** | `session-teardown.js` → `~\.claude\hooks\` | Один файл на два события: PostToolUse + Stop. Удаляет pending-файлы своей `session_id`, **чей хук мёртв** (ответ в TUI/нативном боксе — CC убивает хук) или `native_control`; pending с живым хуком = параллельный промпт ещё ждёт — не трогается (scoped 2026-07-28). |
| **AHK-роутер** | `press-1.ahk` → `~\scripts\` | Резидентный. Глобальные хоткеи (F13–F21, Ctrl+Win+1-3), popup (auto-show 500ms), запись decision-файлов, фокусировка окон. Диспетчеризация по `kind × host`; permission на любом decision-хосте → decision-слово (Win32-доставка удалена, резолв окна остался только для фокуса пикеров). Исключение: opt-in `native_control` для Codex-панели отправляет цифру `1/2/3` в родной webview после fail-closed фокус-проверки. |

**Дроп companion-расширения (Phase 8).** Раньше сценарий B (терминал редактора) шёл через companion-расширение: скрейп вывода терминала (proposed API `terminalDataWriteEvent`), запись `prompts`-metadata, доставка через `terminal.sendText()`. В стабильных сборках форков VS Code (Cursor, Windsurf/Devin) этот proposed API **заблокирован** для sideloaded-расширений (доказано логами Extension Host). Расширение удалено целиком; терминал редактора (`vscode-terminal`, включая форки) переведён на тот же hook-decision канал, что A и C. Прежний протокол `prompts/*.json` и `response-*.txt` больше не существует.

## Пять стадий жизненного цикла × decision-канал (единый для B/A/C)

| Стадия | B: терминал редактора (VS Code / Cursor / Devin) | A: standalone terminal (WT/conhost) | C: панель расширения |
|---|---|---|---|
| **Детекция** (реальный промпт ждёт) | Hook pending (`host.type=vscode-terminal`); фантомов нет — hook фиреится только на реальные промпты (S1) | Hook pending (`host.type=windows-terminal\|conhost`); фантомов нет (S1). Liveness-gate: AHK скрывает И удаляет pending, чьё top-level окно/процесс умерли | Hook pending (`host.type=vscode-extension`); фантомов нет. В auto-режиме классификатор отвечает сам, hook молчит |
| **Идентификация** (какое окно) | **Не нужна для доставки** (decision-файл адресован hook-процессу по id). Для focus-only строк — `editor_exe` (basename `VSCODE_GIT_ASKPASS_NODE`: `Code.exe`/`Cursor.exe`/`Devin.exe`) + заголовок; если terminal cwd (например GSD worktree) не совпал с workspace title, fallback разрешён только при ровно одном окне этого exe | **Не нужна для доставки.** Для liveness-gate и фокуса — `host` fingerprint (ancestry/top_level_pid/hwnd — gated walk для WT/conhost): глиф-скан окон exe → hwnd → PID-скан ancestry | Не нужна для доставки. Для picker-fallback — fuzzy-match заголовка окна по project_name (`FindVSCodeByName`) |
| **Презентация** | AHK popup, без бейджа; permission → кнопки по options-подсказке хука (2 или 3), picker → attention-строка | Тот же popup, бейдж «WT»/«console» | Тот же popup, бейдж «panel» |
| **Доставка** | `response-hook-<id>.txt` (слово allow/always/deny/pass) → hook возвращает `hookSpecificOutput.decision`, ядро CC применяет (S10). Фокус и клавиатура не используются; фоновый таб/свёрнутое окно работают. Focus-only: WinActivate по title-match, затем unique-`editor_exe` fallback; при 2+ окнах — отказ | `response-hook-<id>.txt` → `hookSpecificOutput.decision`. Picker: WinActivate терминала (глиф-скан/hwnd/PID) | `response-hook-<id>.txt` → `hookSpecificOutput.decision`. Picker: WinActivate + best-effort chord |
| **Очистка** | Hook удаляет pending+decision при выходе (ответ/pass/таймаут 60 мин); teardown (PostToolUse/Stop) и hook-liveness по `hook_pid` удаляют pending → hook early-exit; орфаны убитого хука — по `wait_until`+2 с и 90-мин backstop | Как B + liveness-gate (окно/процесс умерли → pending удалён) | Как B (нет liveness-gate — нет walk) |

**Охват терминала редактора (важно).** Hook фиреится на **permission + hook-пикеры (AskUserQuestion / ExitPlanMode)** — ровно это и покрывает попап. Scrape-only состояния, которые раньше ловило ТОЛЬКО расширение — slash-меню (`/model`/`/resume`/`/agents`/`/help`) и свободный ввод (`kind=text`, «ctrl-g to edit») — больше не всплывают в попапе и отвечаются прямо в TUI. Паритета «все промпты терминала» нет — by design.

## Codex CLI (Phase 6, Stage 2d — двухфазный гибрид на decision-канале)

Codex CLI скопировал систему хуков Claude почти дословно (snake_case payload, тот же `hookSpecificOutput.decision.behavior`, события `Stop`/`PostToolUse`). press-1 переиспользует **тот же файловый протокол** (`%TEMP%\press-1\pending` + `response-hook-*.txt`) и **те же AHK-роутер и popup** — pending'и Claude и Codex сосуществуют, различаются полем `agent` (`claude`|`codex`); session_id не коллизят.

| Компонент | Файл | Отличие от Claude |
|---|---|---|
| **Codex hook** | `codex-permission-request.js` + `codex-reviewer.js` → `~\.codex\hooks\` | До pending делает экспериментальный exact same-turn `auto_review` pass-through (детектор — отдельный модуль `codex-reviewer.js`, деплоится рядом; удаляется целиком при появлении официального reviewer-поля upstream) на всех стандартных hook-поверхностях (`PRESS1_PROXY` исключён); иначе `agent:"codex"`; **всегда 3 кнопки** (нет `permission_suggestions`); БЕЗ `updatedPermissions` (Codex его отвергает); **двухфазный гибрид** (см. ниже): окно фазы 1 `PRESS1_CODEX_HYBRID_WAIT_MS` (15 с дефолт) → rewrite pending в `native_control` → exit; decision-only-окно `PRESS1_CODEX_WAIT_MS` (60 с дефолт); **кламп обоих окон 60000** = `70000 (outer) − 4000 (звук) − 3000 (walk) − 3000 (запас)`; `wait_until` при записи несёт +4 с звукового бюджета; codex-`classifyHost` (нет `CLAUDE_CODE_ENTRYPOINT` → панель по `VSCODE_PID`, fallback `conhost`); walk только для WT |
| **Codex attention** | `codex-attention.js` → `~\.codex\hooks\` | `UserPromptSubmit` запускает bounded rollout-watcher активного turn и добавляет developer-контракт естественной финальной фразы. Незакрытый `request_user_input` после debounce 750 мс → live `kind:"attention"`; быстрый Default-mode reject успевает закрыться без popup. `Stop` показывает только exact contract (`Ответьте номером` + ≥2 опции / `Жду вашего ответа` и EN-аналоги), более широкую эвристику пишет в shadow-log. `SessionEnd` и следующий `UserPromptSubmit` чистят строки |
| **GSD Stop compatibility** | `codex-gsd-context-monitor.js` → `~\.codex\hooks\` | Оборачивает только GSD `gsd-context-monitor` на событии Stop: запускает исходный JS ради его side effects и всегда возвращает валидный no-op `{}`. PostToolUse GSD остаётся прямым и не меняется |
| **Teardown** | `session-teardown.js` → `~\.codex\hooks\` | тот же файл, зарегистрирован на Codex `Stop`+`PostToolUse` |
| **Proxy-обёртка (opt-in, экспериментально)** | `codex-mitm.js` → SEA `.exe` в `~\scripts\` (сборка `enable-codex-proxy.ps1`) | stdio-MITM между расширением панели и бандл-бинарём `codex app-server` (подмена через `chatgpt.cliExecutable`). Прокси-канал панели: см. секцию ниже + [DESIGN-CODEX-PROXY.md](DESIGN-CODEX-PROXY.md) |
| **Merge/trust** | `merge-codex-hooks.js` | пишет `~\.codex\hooks.json` в **wrapper-схеме** `{"hooks":{…}}`; чужие top-level ключи **УДАЛЯЕТ** (Codex `HooksFile` = serde `deny_unknown_fields` → любой не-`hooks` ключ ломает ВЕСЬ файл, доказано на дыме — не «инертны»; сайдкар `.disabled-by-press-1` write-once, это удаление, НЕ миграция); PermissionRequest несёт `statusMessage` («press-1: hotkey …») — TUI показывает его во время фазы 1; direct GSD context-monitor на Stop точечно заменяется совместимой обёрткой; **верифицируемый auto-trust** `trusted_hash` в `config.toml` через `codex app-server`/`hooks/list`, запущенный из `PATH` или bundled binary Native Desktop. Exit 0 только после re-list шести обязательных entries и всех установленных optional press-1 wrappers в состоянии trusted/managed; найденный Codex с неподтверждённым trust = exit 2 и fail-loud ручной `/hooks`; отсутствие опционального Codex = exit 3/warning без поломки Claude-only установки |

**Три отличия протокола Codex (доказаны эмпирически, RESEARCH-CODEX §16–17):**
1. **Блокирующий гейт, нет `Promise.race`.** Пока хук ждёт — нативный промпт Codex **невидим** (в TUI/панели), виден только popup press-1. Поэтому окно ограничено, а timeout хука в `hooks.json` — **70 с** (не Claude-3660): зависший хук обязан умереть за предсказуемое время, чтобы pass-through показал нативный промпт. Гибрид (ниже) снимает главный минус: попап больше не умирает на pass-through.
2. **«Always allow» — через rules-файл, не через хук.** На слове `always` хук возвращает allow И дописывает `prefix_rule(pattern=[<полные токены команды>], decision="allow")` в `~/.codex/rules/default.rules` (формат TUI-дефолта; live-reload без рестарта). Аппенд синхронный, до вывода allow, изолирован (ошибка не ломает allow). Лимит: pwsh-обёрнутые shell-команды — benign no-op.
3. **Trust.** Command-хуки Codex не исполняются без `trusted_hash` в `config.toml`. install находит `codex` в `PATH` либо новейший `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`, пишет hashes, затем повторным `hooks/list` требует шесть обязательных press-1 entries и установленную optional GSD-обёртку в состоянии `trusted|managed`. Неподтверждённый trust — не успех установки; ручной `/hooks` остаётся фоллбэком.

### Needs-user attention (Codex)

`request_user_input` на Codex 0.147 — специализированный function tool: он записывается в rollout как `response_item/function_call`, но не проходит через `PreToolUse`/`PostToolUse`. Поэтому точный сигнал берётся из уже локального transcript. На каждом `UserPromptSubmit` hook запускает один detached watcher с lease по `turn_id`, начиная с текущего EOF. Вызов становится live-событием только если 750 мс остаётся без парного `function_call_output`: штатный отказ «unavailable in Default mode» закрывается быстрее и не звучит. Ответ удаляет pending; `task_complete` завершает watcher. Чтение потоковое по 64 KiB с `StringDecoder`; non-target JSONL-строка >4 MiB отбрасывается до следующего newline, чтобы image/tool outputs не раздували процесс.

Для обычного текстового блокера `UserPromptSubmit.additionalContext` задаёт естественный контракт: numbered choice заканчивается `Ответьте номером.` / `Reply with the option number.`, free text — `Жду вашего ответа.` / `Waiting for your answer.`. Exact Stop-детектор требует либо финальную free-text фразу, либо imperative номер/цифру вместе минимум с двумя нумерованными опциями. HTML-marker из первого smoke (`<!-- press-1:needs-user -->`) оставлен только как временно распознаваемый legacy-вход: Codex показывает HTML comments буквально, новые turns его больше не получают. Более широкие RU/EN-паттерны пока только пишутся в `%TEMP%\press-1\attention-shadow.jsonl`; риторические/необязательные вопросы не логируются. Attention никогда не отправляет цифру: кнопка/хоткей только фокусирует окно.

**Hard-kill lifecycle (исправлен 2026-08-10).** `text_contract` создаётся на `Stop`, то есть уже после `task_complete`; основные владельцы очистки — следующий `UserPromptSubmit` той же `session_id` или `SessionEnd`. Жёсткое закрытие/kill интегрированного терминала может не вызвать `SessionEnd`. Поэтому у `kind:"attention"` есть два локальных владельца: явный X/Esc считается acknowledgement и удаляет pending (picker/permission не удаляются), а общий `STANDALONE_BACKSTOP_MS` (90 мин) удаляет просроченный attention JSON вместо простого скрытия. Автоматическую раннюю детекцию terminal death через owner PID не добавляем: она сложнее и не нужна при bounded TTL + явном dismiss.

### Exact same-turn Auto-review bypass (все стандартные hook-поверхности; экспериментально, default-on)

До pending и звука стандартный `PermissionRequest` hook запускает общий fail-safe арбитр в CLI/conhost, Windows Terminal, терминале редактора, обычной панели без proxy и Native Desktop. Весь детектор (парсер transcript + статус-сайдкар) живёт в отдельном модуле `codex-reviewer.js` (require из хука, деплой в тот же `~\.codex\hooks\`): version-sensitive workaround изолирован и при появлении официального reviewer-поля удаляется одним файлом. Codex `trusted_hash` покрывает только entry-скрипт хука — модуль едет рядом без собственного trust-хэша (принято: свой файл в своей папке). Порядок ранних гейтов load-bearing: глобальный `~/.press-1-off-codex` → `PRESS1_PROXY` → Codex reviewer probe → обычный popup-маршрут. `PRESS1_PROXY` — жёсткое раннее исключение: hook не читает transcript, не запускает reviewer probe и не записывает reviewer-status. Proxy видит только post-review запросы, которые Codex уже передал на реальное ручное согласование.

Ранний pass-through разрешён **только** при точном сочетании:

- отсутствие opt-out `~/.press-1-off-codex-desktop-auto-review` доказано через filesystem lookup (legacy-имя сохранено намеренно ради совместимости; отсутствующий `USERPROFILE`, ACL/I/O/path error и гонка включения флага → popup без probe/status);
- hook input содержит непустые `turn_id` и абсолютный `transcript_path`;
- все matching top-level `type:"turn_context"` с тем же `payload.turn_id` дают одно уникальное reviewer-значение `payload.approvals_reviewer:"auto_review"`; одинаковые дубликаты допустимы, разные значения → conflict/popup.

Успех = exit 0 без stdout: press-1 **не одобряет** запрос, а не выносит verdict и немедленно отдаёт управление родному reviewer. Silent exact-auto route не создаёт и не удаляет pending: одна `session_id` не доказывает, что другая approval-карточка этой сессии уже мертва; regression сохраняет параллельный ручной pending отвечаемым. `user`, guardian/неизвестный reviewer, конфликт записей, missing/null, parse/I/O/budget/path error и любая новая структура → прежний popup. Кэша reviewer нет.

Чтение ограничено локальным regular `.jsonl` под каноническим `realpath((CODEX_HOME || USERPROFILE/.codex)/sessions)`. Единственное допустимое device-like spelling — штатный Windows extended local drive path `\\?\X:\...`, который Native/resumed Codex может записать в `transcript_path` и который допустим для явно заданного `CODEX_HOME`: hook симметрично снимает только точный префикс `\\?\` **до** `path.join`/файловых операций, после чего transcript и sessions root обязаны пройти те же lexical/realpath/inside-root проверки, а transcript также `.jsonl`/regular-file. Relative, обычный UNC (`\\server`), `\\.\`, `\\?\UNC`, `GLOBALROOT`, `Volume{...}`, mixed-separator/ADS/NUL/CR/LF forms, outside-root и symlink/junction escape отвергаются. Сканируется только новейший хвост до 32 MiB, максимум 3 стабильных snapshot-попытки; рост файла приводит к повтору, не к догадке. Все полные JSONL-записи внутри bounded snapshot обязаны пройти fatal UTF-8 decode и JSON parse, но лимит 4 MiB относится только к reviewer-кандидату `type:"turn_context"`: Codex штатно хранит более крупные image/tool outputs, и валидная non-turn запись не создаёт reviewer-неопределённость; malformed encoding/JSON, oversized `turn_context` и reviewer conflict остаются fail-safe popup. Wall-clock бюджет 250 мс проверяется до и после каждого блока чтения по 256 KiB и после каждого parse-шага. Это **кооперативный**, а не hard real-time лимит: отдельный синхронный filesystem syscall/UTF-8 decode/`JSON.parse` нельзя прервать; внешний 70-секундный timeout хука остаётся последним жёстким предохранителем.

Трей: **Codex → Let Auto-review decide (experimental)** отмечен по умолчанию; снять check = создать opt-out-флаг и вернуть popup на всех стандартных hook-поверхностях. Имя файла `~/.press-1-off-codex-desktop-auto-review` — legacy и намеренно сохранено для преемственности пользовательского выбора и обратной совместимости. **Active for → Codex** остаётся master switch и дополнительно скрывает proxy-строки в AHK, не удаляя wrapper-owned pending (после включения та же живая строка снова видна).

Best-effort атомарный статус последней реально выполненной Codex reviewer-пробы: `%TEMP%\press-1\codex-reviewer-last.json`. Схема фиксирована и не содержит command/cwd/path/turn/session/raw error; `Ctrl+Win+D` показывает только свежую (≤10 мин) пару enum `outcome/reason` и `elapsed_ms`. Master-off, reviewer opt-out и `PRESS1_PROXY` этот файл не перетирают.

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
- **AHK**: читает proxy-дир тем же 200-мс refresh'ем; адаптер строит строку попапа (`project_name` = basename(cwd), `exec(<command>)`, кнопки из `availableDecisions`: 3 = Allow/Always/Deny, 2 = Allow/Deny), `WriteProxyDecision` пишет JSON атомарно; исчезновение pending = карточка снята (штатный reconcile). Focus-роутинга у proxy-строк нет (Esc = локальный dismiss, ответ руками в панели остаётся доступен — passthrough). Бейдж `codex·proxy`. Master-флаг `~/.press-1-off-codex` фильтрует эти строки на чтении, но не трогает pending-файлы обёртки.
- **Арбитраж каналов**: обёртка выставляет `PRESS1_PROXY=1` дочернему app-server **только при живом control-dir**; hook-процессы наследуют → `codex-permission-request.js` молча выходит (дубль карточек исключён). Codex CLI в терминале переменную не видит — hook-канал для него живёт. Самовосстановление: прокси мёртв/выпилен → env нет → hook-канал панели возвращается сам.
- **Семантика Deny**: в панельных `availableDecisions` нет `decline` — Deny = `cancel` = обрыв тёрна (Esc-семантика), команда не выполняется. Нативная «No + фидбек» — только руками в карточке.

## Файловый протокол (`%TEMP%\press-1\`)

```
press-1/
├── pending/<timestamp>-<rand>.json     ← hook (один файл на permission / picker / attention)
├── response-hook-<id>.txt              ← AHK (decision-слово; hook поллит 100 мс и удаляет; отсутствует в Codex native-control)
├── codex-reviewer-last.json             ← sanitized status последней Codex reviewer-пробы (best-effort, atomic overwrite)
├── attention-shadow.jsonl               ← strict text candidates, без popup до rollout-gate
├── attention-watch/<turn_id>.lock       ← lease одного rollout-watcher на turn
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
  "tool_key": "4dd67e21f03c…",           // sha1(tool_name + канонический JSON tool_input) — идентичность тула для матча teardown'а на PostToolUse
  "kind": "permission | picker | attention", // attention = Codex ждёт текстовый ответ; focus-only
  "attention_source": "request_user_input | text_contract | legacy_marker", // только для attention
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

### Фокус-хелперы (для picker/attention; промахи безопасны)

Доставка ответа решением не требует окна. Фокус нужен лишь для picker-строк и кнопки 🔍:

- **Терминал редактора** (`vscode-terminal`): `FindEditorCandidates(project_name, editor_exe)` — предпочитает окна конкретного редактора (`Code.exe`/`Cursor.exe`/`Devin.exe`) по `editor_exe`, фоллбэк — кросс-редакторный список по заголовку. Если terminal cwd (например GSD worktree) не совпал с workspace title, разрешён только focus-only fallback на ровно одно окно сохранённого `editor_exe`; при 2+ не совпавших по title окнах — отказ. Несколько одинаковых **title-match** не выбираются случайно: повторный Focus циклически перебирает их в стабильном numeric-HWND порядке и показывает `Window N/M`. Выбранное окно проходит полный `ActivateHwnd`: restore свёрнутого окна и foreground-lock retry, затем получает короткую click-through рамку + `FlashWindowEx`; само окно не двигается, snap/maximized не меняются. `EditorWindowList`/`IsEditorTitle` покрывают все три редактора (Windsurf — `Devin.exe` после ребренда; `Windsurf.exe` оставлен для старых сборок).
- **Панель** (`vscode-extension`): `FindVSCodeByName` (fuzzy заголовок по project_name), gentle-активация (без Alt-dance — иначе focus-война между панелями). Эта щадящая политика не распространяется на `vscode-terminal`.
- **Standalone** (`windows-terminal`/`conhost`): `ResolveStandaloneHwnd` — глиф-скан окон `top_level_exe` («✳ …» = окно с активным claude-табом) → сохранённый `hwnd` → PID-скан сверху вниз по ancestry (conhost: окно атрибутировано клиенту cmd.exe).

### Teardown-канал

`session-teardown.js` регистрируется на **PostToolUse** (без matcher — все тулы) и **Stop**. С 2026-08-03 у событий **разные полномочия**, а различаются они по форме payload'а, а не по написанию `hook_event_name` (у двух агентов оно своё): **PostToolUse всегда несёт `tool_name`, Stop — никогда**. `kind:"attention"` исключён из обоих cleanup-путей: Stop может одновременно создавать такую строку, поэтому её удаляет только attention-owner (ответ/следующий `UserPromptSubmit`/`SessionEnd`). Hook всегда печатает валидный `{}`: Codex Stop отвергает пустой stdout как invalid JSON.

**PostToolUse — скоупнутое удаление**, к прежним трём условиям добавлено четвёртое и главное: **`tool_key` pending'а совпал с только что завершившимся тулом**. Это единственное правило, не зависящее от смерти хука, и оно load-bearing, потому что **текущий Claude Code больше НЕ убивает проигравший `PermissionRequest`-хук** — живой инцидент 2026-08-03: два панельных промпта отвечены мышью, оба тула выполнились, оба хука через 2,5 мин всё ещё поллили, карточки висели бы все 60 мин. Завершившийся тул — доказательство того, что его промпт отвечен. Матчится **не более ОДНОГО** pending на событие (старейший по `timestamp`): две идентичные параллельные команды дают две карточки, каждой нужно своё завершение. `tool_key` = sha1 от `tool_name` + канонический (рекурсивно отсортированные ключи) JSON `tool_input` — порядок полей в payload'е на матч не влияет; формула продублирована в `permission-request.js` и `session-teardown.js`, обе копии прибиты к одному дайджесту тестами (hook T17 / teardown T10). Остаточный зазор by design: карточка гаснет по **завершению** тула, а не в момент клика — более раннего сигнала не существует (между `tool_use` и `tool_result` CC не пишет в транскрипт ничего, PreToolUse идёт ДО permission-гейта). Для долгих команд карточка живёт столько, сколько выполняется тул; ответ хоткеем этим не задет — там pending удаляет сам хук.

**Stop — blanket-удаление** всех pending'ов сессии: тёрн завершён, а ждущий промпт **блокирует** тёрн, значит ничего отвечаемого не осталось. Это единственное, что закрывает **нативный Deny** (deny не запускает тул → PostToolUse не фаерится). Гейт по имени события односторонний, только на сужение: tool-less событие с непустым именем, не равным `Stop` (например `SubagentStop`, где промпт соседнего сабагента реально может ждать), blanket-полномочий не получает; отсутствие имени = legacy-форма Stop → blanket.

Прежние условия PostToolUse (2026-07-28) в силе: pending удаляется, если его `hook_pid` мёртв (ответ/отмена в TUI/нативном боксе на старых сборках CC; сюда же падают краши), либо это `native_control`-строка (хук вышел by design), либо **`kind:"picker"`** — у picker-строк семантика живости ИНВЕРТИРОВАНА: хук — маяк, сознательно заблокированный на `waitForPendingGone`, и удаление pending на same-session событии — его штатный путь освобождения (строка не несёт канала ответа, терять нечего; живой инцидент 2026-07-28 — отвеченный AskUserQuestion висел минутами под liveness-щитом). Permission-pending с **живым** хуком — параллельный промпт, который реально ещё ждёт: он переживает teardown и остаётся отвечаемым хоткеем. PID-reuse может дать ложное «жив» — такой орфан добирает AHK orphan-гейт (`ProcessStartMs`+`PidStaleDecision`) в ближайший тик; направление отказа — «строка живёт чуть дольше», никогда не перенаправленный ответ. **Отмену** промпта (Esc/interrupt) ни PostToolUse, ни Stop не фаерят. Раньше её ловил мёртвый `hook_pid` (CC убивал хук при ответе И отмене) — на текущей сборке CC этого убийства нет, поэтому практический бэкстоп отменённой permission-строки — **Stop следующего тёрна той же сессии** (blanket), а хвостовой пояс прежний: `wait_until`+2 с и 90-мин backstop. Для picker-строк канал освобождения не изменился (teardown по same-session событию).

Владельцы жизненного цикла pending по хостам (теперь единообразно — decision/маяк-хук во всех случаях):

| host.type | Удаляет при ответе | Орфан-очистка |
|---|---|---|
| `vscode-terminal` / `vscode-extension` × permission | hook при выходе (ответ/pass/таймаут 60 мин); teardown при ответе в TUI/боксе → early-exit хука | AHK hook-liveness по `hook_pid` (CC убил проигравший хук → файл удаляется в ближайший тик); скрытие по `wait_until`+2 с; 90-мин backstop |
| Codex × permission × `native_control` (фаза 2 гибрида: панель/vsterm/WT; или panel-native-only) | teardown при approve (в т.ч. после доставленной цифры); TTL по `wait_until` (standalone-ветка ТОЖЕ удаляет файл по TTL); legacy **same-session cleanup** выполняется только когда popup-route публикует новую строку. Exact-auto намеренно ничего не чистит: параллельный same-session pending может быть жив | hook-liveness **не применяется** (hook вышел by design); liveness-gate окна для WT остаётся; неоднозначность (2+ pending на окно / окно не найдено / не активно) → цифра не шлётся, pending живёт до TTL, пользователь отвечает в native UI |
| `vscode-terminal` / `vscode-extension` × picker | хук-маяк блокируется (`waitForPendingGone`, до 60 мин); teardown при ответе → маяк освобождается | AHK hook-liveness по `hook_pid` (CC убивает маяк при ответе И отмене — teardown отмену не ловит); dead-session picker — 90-мин backstop |
| `windows-terminal` / `conhost` × permission | hook при выходе; teardown при ответе в TUI → early-exit | AHK hook-liveness по `hook_pid`; AHK liveness-gate (окно/процесс умерли → файл удаляется → early-exit); `wait_until`+2 с; 90-мин backstop |
| `windows-terminal` / `conhost` × picker | хук-маяк блокируется; teardown при ответе → маяк освобождается | AHK hook-liveness; AHK liveness-gate; 90-мин backstop |

Backstop отображения pending-строк (`STANDALONE_BACKSTOP_MS` = 90 мин) — только crash-страховка; обязан превышать окно ожидания хука (60 мин). Прежняя принятая гонка «PostToolUse тула A удаляет живой pending тула B той же сессии» **закрыта scoped-teardown'ом 2026-07-28** (живой хук = pending не трогается): при параллельных tool-вызовах ответ хоткеем на одну карточку больше не гасит остальные. Тот же liveness-фильтр применён к `cleanupCodexSessionPendings` codex-хука (interrupt-трупы чистятся, параллельный живой approval-хук того же thread — нет).

## Ключевые механизмы

- **Анти-фантом = S1**: hook фиреится только на реальные промпты (auto-allowed тулы pending не создают). Поэтому каждый pending-файл — настоящий ждущий промпт; phantom-фильтры/скрейп-гейты не нужны.
- **Диспетчеризация по kind**: permission → decision-слово в decision-файл (без смены фокуса, на любом хосте); `native_control` Codex-панели → fail-closed отправка цифры `1/2/3` в единственное **title-matched** editor-window (чат панели на cwd ≠ workspace окна титулом не резолвится → фоллбэк `ResolveCodexPanelFallback`: единственное окно редактора активируется, цифра по фоллбэку НЕ шлётся — счёт «окно одно» это косвенная улика, не позитивная идентификация); picker/прочие → фокусировка нужного окна (по host: editor_exe / глиф-скан / заголовок). Цифра в picker слепо НЕ шлётся.
- **Dismiss-подпись**: `ComputeSignature` керится на `prompt_id` (= `id` pending'а, уникален per-хук). Закрытый пользователем popup не переоткрывается для того же набора промптов; новый промпт (новый id) busts подавление.
- **Раскладка цифр = раскладке TUI**: popup рендерит кнопки из `options` pending'а (`permission_suggestions` непуст ⇒ 3-опционный). При отсутствии подсказки — дефолт 3-опционный (худшая ошибка Deny-вместо-Always-allow — безопасное направление).

## Принятые риски

1. **`claude_pid` эфемерен** — это PID короткоживущего cmd/bash-враппера, запускающего hook; умирает за секунды. PID-walk — best-effort tiebreaker; для schema v2 ancestry собирается В хуке, пока цепочка жива.
2. **Блокирующий хук для decision-хостов (окно 60 мин)**: каждый permission-промпт терминала/панели/WT/conhost держит hook-процесс до 60 мин. Это не задерживает пользователя (box/TUI рендерится сразу, нативный ответ побеждает race мгновенно). Зомби и орфаны закрывают три механизма: (а) early-exit — teardown (матч по `tool_key` на PostToolUse, blanket на Stop) или liveness-gate удаляют pending → ждущий хук выходит; (б) **hook-liveness по `hook_pid`** — исторически CC убивал проигравший race хук без graceful exit, и «pending есть, hook-процесса нет» = орфан → AHK гасит строку и файл. **На текущей сборке CC этого убийства больше нет** (доказано 2026-08-03), поэтому механизм (б) деградировал до страховки от крашей, а рабочим стал (а); (в) скрытие по `wait_until`+2 с — пояс на случай переиспользованного PID.
3. **Связка таймаутов (load-bearing)**: окно ожидания хука (3600000 мс = 3600 с, `PRESS1_DECISION_WAIT_MS`) < `timeout` PermissionRequest-хука в settings.json (3660 с) < backstop отображения pending (`STANDALONE_BACKSTOP_MS` = 5400000 мс = 90 мин). Нарушение первого неравенства ломает доставку молча; backstop обязан превышать окно хука. **Единицы load-bearing:** `*_MS`-константы — миллисекунды, settings-`timeout` — секунды.
4. **Title-guard — историческое**: захват титула хуком невозможен (хук живёт в скрытой консоли враппера, `CREATE_NO_WINDOW`), поле `title` зарезервировано пустым; глиф-скан («✳ …») жив в `ResolveStandaloneHwnd` для выбора окна при фокусе standalone.
5. **Codex reviewer signal нестабилен upstream.** `transcript_path` и JSONL `turn_context` shape — внутренние/version-sensitive контракты Codex. Поэтому detector default-on только как эксперимент с exact same-turn match и направлением отказа в popup; при появлении официального reviewer field workaround должен быть заменён.
6. **`session_id` не является request-id.** Exact-auto не удаляет same-session pending, потому что соседний approval hook может оставаться активным. Lifecycle debt закрыт 2026-07-28 liveness-ключом `hook_pid`: и teardown, и popup-route cleanup codex-хука скоупнуты по живости хука (живой → не трогаем; мёртвый/`native_control` → чистим), per-approval id от upstream больше не требуется для этого класса коллизий.

**Снят (Phase 8):** прежний риск №1 — proposed API `terminalDataWriteEvent`. Companion-расширение дропнуто, скрейп-зависимость устранена; терминал редактора идёт через decision-канал. Восстановимо `git revert`, если форки когда-нибудь откроют proposed API.

## Известные ограничения

Баги №2 (index-shift), №8 (коллизия одноимённых workspace) и №9 (claude в подпапке) закрыты schema v2. Остаточное:

- Охват терминала редактора — permission + hook-пикеры (scrape-only состояния не всплывают, см. выше) — by design.
- Ответ хоткеем возможен только в окне ожидания хука (60 мин); после таймаута строка гаснет, ответ руками в TUI/боксе. Per-monitor хоткеи (F16–F21) таргетируют только окна редакторов.
- Сценарий C при нескольких панельных вкладках в одном окне: **доставка decision иммунна к количеству вкладок** (роутинг per-pending по `decision_file`), но строки popup различимы только по tool_name/tool_input (project_name одинаков), а «Focus panel» фокусирует «какую-то» панель, не конкретную вкладку.
- Фаза 2 Codex-гибрида: доставка цифрой работает только для панели при единственном live-промпте на единственное активное title-matched окно (иначе фокус/tooltip); фаза 1 (decision-окно) от этих ограничений свободна. Нативный deny/cancel в фазе 2 не даёт хук-событий → строка живёт до TTL (5 мин дефолт; следующий промпт сессии убирает раньше — same-session cleanup). Титул `[ ! ]/[ . ] Action Required` подтверждён (CX-S7, 0.142.5): ставится в имя вкладки WT, но заголовок ОКНА зеркалит только активную вкладку — фоновую кроет фоллбэк «единственное окно exe». Панельное таргетирование слепо при cwd чата ≠ workspace окна (фоллбэк: единственное окно редактора, активация без отправки цифры).
- Несколько терминалов редактора с одновременными промптами в одном окне: доставка адресная (per-pending `decision_file`), но picker/attention-фокус приводит к окну редактора, не к конкретному терминалу-вкладке. Точно адресовать окно при cwd/workspace mismatch без кода внутри редактора поддерживаемым способом нельзя: Win32 видит один Electron HWND/main process; официальный `code --reuse-window` выбирает последнее активное окно и CLI не исполняет workbench-команду «focus terminal»; внутренний VS Code IPC и UI Automation не являются стабильными контрактами. Теоретическое точное решение — маленький extension focus-bridge: per-window token в env терминала → token в pending → адресный `Terminal.show(false)` (при необходимости terminal match по `shellIntegration.cwd`/`processId`), без прежнего scrape/proposed API. **Решение 2026-08-09:** extension только ради Focus несоразмерен; bridge не строим, текущий title-first + unique-`editor_exe` fallback считаем принятым поведением, неоднозначность остаётся fail-closed.
- Codex reviewer-routing аттестован офлайн для CLI/conhost, Windows Terminal, терминала редактора, обычной hook-панели и Native Desktop против текущего rollout shape; финальный production-installed safe pure-pass build прошёл изолированный fresh standalone CLI Auto live (`auto_pass / exact_auto_review`, 3 ms, no pending), а manual/fail-safe hook — popup→hotkey `allow` (exact `reviewer:user` отдельно доказан предыдущим build). Остальная cross-surface live matrix ещё нужна. Формат не является стабильным hook API: любой дрейф безопасно вернёт popup, но бесшовный Auto-review потребует обновления detector. Proxy намеренно не участвует: его запросы уже прошли reviewer.
