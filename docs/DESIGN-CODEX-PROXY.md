# Дизайн — экспериментальный прокси-канал Codex-панели («codex-proxy»)

> Статус: **дизайн утверждён 2026-07-09** (решения Егора: opt-in скриптами, Deny как есть, hook-mute через env-var). Основание — оба гейта закрыты вживую: G1 прозрачность + G2 инжекция гасит карточку в webview (RESEARCH-CODEX §19, «Живой прогон — Этап 2»). Продуктовый код пишется после явного go пользователя. Позиционирование: **opt-in «use at your own risk», выключено по умолчанию, откат одним действием.**

## 1. Суть

stdio-MITM-обёртка (`codex-mitm`) между расширением `openai.chatgpt` и бандл-бинарём `codex app-server` (подмена через `chatgpt.cliExecutable`). Обёртка видит `item/commandExecution/requestApproval`, публикует pending-файл для AHK, принимает decision-файл от AHK и инжектит ответ серверу; карточка в webview гаснет на штатный `serverRequest/resolved` (доказано глазами). Полный Claude-паритет для панели: натив виден сразу, ответ хоткеем без фокуса, взаимное снятие, персист.

Чем платим (честно, для README): обёртка в critical path расширения (баг = мёртвая панель до disable+reload); живём на «DEVELOPMENT ONLY» настройке; Deny = обрыв тёрна.

## 2. Компоненты и изменения

| Компонент | Изменение |
|---|---|
| `codex-mitm.js` (новый, продуктизация спайка) | Канонический исходник в репо; деплой как Node SEA `.exe`. Дельта от спайка: (а) **атомарная запись pending** (tmp+rename — в спайке `writeFileSync` без rename, возможен torn read); (б) **`PRESS1_PROXY=1` в env дочернего app-server** (hook-mute, §4) — выставляется только при `ctrlOk=true` (control-dir создан), иначе hook-канал остаётся жив; (в) инварианты спайка неизменны: relay-first целым кадром, инжектор в try/catch, недоступный control-dir → чистый pass-through, нет бинаря → exit 127, cleanup pending на resolved/exit, динамический резолв свежайшего бандла `~/.vscode/extensions/openai.chatgpt-*`. |
| `press-1.ahk` | Три новые вещи, остальное переиспользуется: (1) `ReadAllProxyPending()` — чтение `%TEMP%\press-1\proxy\*.pending.json` + адаптер схемы (см. §3; схема не пересекается со schema v2, через общий regex-парсер НЕ гнать); (2) `WriteProxyDecision()` — атомарная запись `<pid>-<reqId>.decision.json` с JSON `{"decision":…}`; (3) ветка в `DispatchByKind` для `channel:"proxy"`. Гашение попапа при исчезновении pending — уже работает (reconcile). Бейдж: новый host-токен `codex-proxy` → `codex·proxy`. |
| `codex-permission-request.js` | Одна проверка в начале: `process.env.PRESS1_PROXY` → тихий exit 0 (до pending и звука). Скоуп естественный: env есть только в процессах под живой обёрткой (панель); CLI в терминале не затронут. |
| `enable-codex-proxy.ps1` / `disable-codex-proxy.ps1` (новые) | Enable: сборка SEA `.exe` (Node 22 + postject, exe ~85 МБ — в git не кладём), деплой в `~\scripts\codex-mitm.exe`, бэкап `settings.json` (write-once sidecar), **JSONC-безопасная** вставка `chatgpt.cliExecutable` (через Node-хелпер, не regex в PS), напоминание про Reload Window. Disable: снять настройку (восстановить из бэкапа при отсутствии других правок), напомнить reload; exe можно оставить (инертен). |
| Трей AHK | Только индикация статуса (пункт «Codex proxy: on/off» read-only или с подсказкой «запусти disable-скрипт»); сам трей settings.json не трогает. |

## 3. Протокол `press1.codex.proxy/1` (контракт)

Pending: `%TEMP%\press-1\proxy\<pid>-<requestId>.pending.json` — `{schema, pid, agent:"codex", channel:"proxy", requestId, threadId, turnId, itemId, command, cwd, reason, availableDecisions, proposedExecpolicyAmendment, ts}`. Decision: `<pid>-<requestId>.decision.json` — `{"decision": "accept" | "cancel" | {acceptWithExecpolicyAmendment:{execpolicy_amendment:[…]}}}`. Обёртка удаляет оба файла на `serverRequest/resolved` (ответил кто угодно) и на exit. Fail-closed: адресация парой `(pid, requestId)`, мульти-окно = разные pid.

Маппинг в попап (адаптер AHK):

| Попап | Из прокси-pending |
|---|---|
| `project_name` | `basename(cwd)` (обязателен — гард AHK дропает строки без него) |
| `tool_name` / `tool_input_short` | `"exec"` / `command` (+ `reason` в subtitle — отдельного слота в карточке нет) |
| Кнопки | `accept`→`1 Allow`; `acceptWithExecpolicyAmendment`→`2 Always allow`; `cancel`→`3 Deny`. Если amendment не предложен — 2 кнопки, `2 = Deny` (существующий гард 2-опционных). |
| `prompt_id` (ключ reconcile) | `pid-requestId` |

**Always allow** в v1 включаем: AHK не сериализует JSON — сырой substring `proposedExecpolicyAmendment` захватывается при парсе и вклеивается в decision байт-в-байт (тест на байт-точность обязателен). Это серверный amendment — лучше самодельного `prefix_rule` hook-канала (BACKLOG 15); ширина amendment плавает — это свойство Codex, честность UX как в hook-канале.

## 4. Арбитраж каналов (hook-mute) — решение: env-var

Обёртка выставляет `PRESS1_PROXY=1` дочернему app-server; hook-процессы его наследуют → codex-hook молча выходит. Свойства: глушится ТОЛЬКО панель под живой обёрткой; Codex CLI в терминале живёт на hook-канале как сегодня; **самовосстановление** — прокси умер/выпилен/настройка снята ⇒ env нет ⇒ hook сам возвращается, панель не остаётся без попапов (тихий отказ флаг-файла исключён by construction). Первый шаг реализации — офлайн-проверка наследования env до хука на готовом стенде sp2 (hooks.json, эхо env в файл).

## 5. Направления отказа

| Сбой | Результат |
|---|---|
| Баг инжектора/парсера обёртки | Релей жив (relay-first) — панель работает, фича инертна |
| Control-dir недоступен | Чистый pass-through, pending не пишутся; `PRESS1_PROXY` выставляется ТОЛЬКО при `ctrlOk=true` (уточнение к §2) ⇒ hook-канал остаётся живым — попапы панели работают через него |
| Бандл-бинарь не найден (апдейт сломал layout) | exit 127, расширение показывает ошибку CLI (loud) → disable-скрипт |
| Настройка снята / расширение её игнорирует | Панель на бандл-бинаре напрямую; env нет → hook-канал возвращается сам |
| Обёртка убита/крашнулась | Расширение видит смерть CLI; рестарт сессии панели; pending подчищены на exit |
| press-1 молчит (не отвечает) | Passthrough: нативный ответ в карточке, pending исчезает на resolved (доказано вживую) |

## 6. Ограничения v1 (зафиксировано)

- **Только VS Code**: резолв бандла захардкожен на `~/.vscode/extensions`; Cursor/Windsurf — отдельная итерация (свои extensions-дир и settings.json).
- **WSL-режим не поддержан**: при включённом `chatgpt.runCodexInWindowsSubsystemForLinux` обёртку не ставить (enable-скрипт проверяет и отказывается).
- **Deny = abort-turn** (в панельных `availableDecisions` нет `decline`): кнопка остаётся «Deny», семантика — в README режима. Нативный «No + фидбек» доступен только руками в карточке.
- Перф: транзит байт-релей, офлайн-прогоны и живые G1/G2 задержек не показали (inject→resolved 1–2 мс); формальный замер — в живом смоуке реализации.

## 7. Тест-план

- **AHK-харнесс** (`tests/ahk-harness.ahk`): парс проксов-pending (адаптер, дроп без cwd), маппинг decisions→кнопки (вкл. 2-кнопочный кейс), `WriteProxyDecision` (форма JSON + байт-точность amendment), роутинг `DispatchByKind`, reconcile на исчезновение pending, бейдж.
- **Hook-тесты** (`tests/codex-hook.test.js`): `PRESS1_PROXY=1` → exit 0 без pending/звука; без env — штатно.
- **Wrapper-тесты**: `verify-mitm.mjs` (accept/deny/persist/passthrough, уже есть) + `buffer-test.mjs` — в обязательный набор «после любых изменений»; новый кейс — атомарность pending (нет torn read).
- **Env-inheritance тест** (офлайн, стенд sp2): env доходит до hook-процесса.
- **Скрипты**: JSONC-сохранность settings.json, идемпотентность enable, восстановление disable (fail-loud стиль merge-hooks-тестов).
- **Живой смоук** (чек-лист в REGRESSION): ровно одна карточка (без дубля hook-канала), Ctrl+Win+1/2/3 → карточка гаснет, disable → панель живёт, hook-канал вернулся.

## 8. Порядок реализации (после go)

1. Офлайн-проверка env-inheritance (гейт для §4). 2. Продуктизация `codex-mitm.js` (атомарный pending, env) + wrapper-тесты. 3. Hook-mute (1 строка) + тесты. 4. AHK-адаптер + тесты. 5. enable/disable-скрипты + тесты. 6. Живой смоук (гейт пользователя, как SP-прогоны). 7. Доки: README-секция экспериментального режима (риски честно), ARCHITECTURE (новый канал), REGRESSION (смоук-чек-лист). Публичный релиз — отдельное решение пользователя (двух-репо воркфлоу).

## 9. Риски (в README режима)

1. Худший случай: баг обёртки → панель мертва до disable+reload (восстановимо одним действием; потому strict opt-in).
2. Ответ не тому requestId → fail-closed матчинг `(pid, requestId)` обязателен (в протоколе by design).
3. Тихая смерть после апдейта расширения → направление отказа безопасное (§5), фича выключается, панель живёт, hook возвращается.
4. «DEVELOPMENT ONLY»: OpenAI не обещает стабильность `cliExecutable`; любой апдейт может выпилить настройку — принято как условие эксперимента.
