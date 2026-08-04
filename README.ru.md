<div align="center">

# ⌨️ press-1

**Сразу узнавайте, когда вы нужны AI-агенту: отвечайте на разрешения глобально или переходите прямо к ожидающему вопросу.**

[English](README.md) · **Русский**

[![Latest Release](https://img.shields.io/github/v/release/egsok/press-1?style=for-the-badge)](../../releases/latest)
![Platform](https://img.shields.io/badge/Platform-Windows-blue?style=for-the-badge)
![Agents](https://img.shields.io/badge/Agents-Claude%20Code%20%C2%B7%20Codex-452BA6?style=for-the-badge)
![Editors](https://img.shields.io/badge/Editors-VS%20Code%20%C2%B7%20Cursor%20%C2%B7%20Windsurf-2496ED?style=for-the-badge)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

![press-1](assets/press-1.png)

</div>

---

AI-агенты останавливаются на разрешениях и пользовательских вопросах в том терминале, редакторе или на том мониторе, где работают. Запрос легко пропустить — и агент будет стоять, пока вам кажется, что задача всё ещё выполняется.

**press-1 собирает поддерживаемые ожидающие чекпоинты в одном popup поверх остальных окон и проигрывает мягкий звук.** На permission можно ответить глобальным хоткеем; если Codex ждёт обычный ответ, press-1 перенесёт прямо в нужное окно. Решение всегда остаётся за вами.

## Посмотрите press-1 в работе

https://github.com/user-attachments/assets/fa8f3a6f-ac4e-4688-a18c-44c3480c5488

![press-1 на трёх мониторах](assets/press-1-3-monitors.png)

## Что даёт press-1

- **Не надо искать prompt.** Запрос видно и слышно, даже если агент спрятан под другими окнами или работает на другом мониторе.
- **Контекст уже в карточке.** Видны агент, проект, команда, файл или вопрос; длинную команду можно развернуть.
- **Глобальное управление.** Клавиатура, кликабельные кнопки popup или любая макропанель с функциональными клавишами.
- **Безопасный роутинг.** Решение адресуется одному конкретному запросу. Если запрос уже исчез, ответ отбрасывается, а не печатается в чужое окно.

![Popup press-1](assets/press-1-popup.png)

Permission-карточки повторяют реальные две или три опции. Needs-user карточки намеренно только фокусируют: **Focus terminal / Focus panel** ищет вероятное окно Codex, но никогда не угадывает и не печатает ответ. Повторный Focus перебирает окна редактора с одинаковым точным заголовком и ненадолго подсвечивает выбранное.

## Хоткеи

| Хоткей | Действие |
|---|---|
| `Ctrl+Win+1 / 2 / 3` | Выбрать вариант 1 / 2 / 3 в активной permission-карточке |
| `Ctrl+Win+↑ / ↓` | Перемещаться по ожидающим карточкам |
| `Ctrl+Win+E` | Развернуть или свернуть полную команду |
| `Ctrl+Win+Esc` | Закрыть popup; передать удерживаемый запрос родному UI |
| `Ctrl+Win+D` | Показать диагностику роутинга |

press-1 также слушает `F13`–`F21`, поэтому макропады и консоли можно настроить на отдельные кнопки.

<table align="center">
  <tr>
    <td align="center"><img src="assets/logitech-mx-console.jpg" alt="Logitech MX Creative Console с press-1" height="400"><br><sub>Моя Logitech MX Creative Console</sub></td>
    <td align="center"><img src="assets/macro-pad.png" alt="Макропад на три клавиши" height="400"><br><sub>Достаточно и простого макропада на три клавиши</sub></td>
  </tr>
</table>

### На каких экранах показывать popup

По умолчанию используется экран, отмеченный в Windows как **Основной дисплей**, а не тот, который Windows случайно назвала монитором 1. В трее откройте **Popup displays** и выберите один экран или любую их комбинацию. Копии разделяют одно состояние: ответ или закрытие любой из них убирает все.

Выбор следует за физическим монитором при перенумерации и перестановке экранов. Если отключены все выбранные дисплеи, press-1 временно использует текущий основной, не забывая настройку. Размер popup учитывает Windows scaling каждого экрана, включая смешанные конфигурации 100%/150%.

## Статус поддержки

Граница между обычной и экспериментальной поддержкой:

| Уровень | Что входит |
|---|---|
| **Поддерживается и включено по умолчанию** | Permission hooks Claude Code; стандартные permission hooks Codex; needs-user уведомления Codex; многомониторный popup и хоткеи |
| **Best effort** | Фокус точного терминала/редактора; поиск явных текстовых чекпоинтов вроде «Ответьте номером». Эти пути fail-safe, но могут пропустить необычную формулировку или неоднозначное окно |
| **Экспериментально, включено по умолчанию** | Same-turn bypass Codex `auto_review`, потому что он читает version-sensitive локальный rollout |
| **Экспериментально, opt-in** | Proxy панели Codex в VS Code (`codex-mitm`) |

### Какой вариант установки выбрать?

**Рекомендация: начните с обычной установки одной командой.** В неё уже входят все основные функции: permissions Claude и Codex, needs-user уведомления Codex, глобальные хоткеи, фокус окна и многомониторный popup. Proxy не нужен, чтобы узнавать, когда Codex ждёт обычный ответ пользователя.

Включайте экспериментальный proxy, только если **панель Codex в VS Code — ваш основной интерфейс** и вы хотите надёжно отвечать на её permission-карточки через press-1 независимо от фокуса, задержки и нескольких похожих окон VS Code. Без proxy у стандартного hook есть прямой decision-канал примерно 15 секунд; после handoff родному UI управление панелью становится best effort. С proxy родная карточка и press-1 появляются вместе, а popup отвечает напрямую через `app-server`.

Proxy меняет только permissions панели VS Code. Он ничего не добавляет к needs-user уведомлениям, Codex CLI, Windows Terminal, Native Desktop, Claude Code и выбору дисплеев. Для интенсивной работы через панель это полезное улучшение, но не рекомендуемый default для всех.

Сам press-1 — **не auto-approver**. Он никогда не выбирает Allow, Always allow или Deny за вас. Экспериментальная reviewer-интеграция лишь отступает, когда текущий тёрн Codex однозначно работает в собственном автоматическом режиме.

## Claude Code

Установщик регистрирует `PermissionRequest` hook для:

- панелей и встроенных терминалов VS Code, Cursor и Windsurf;
- Windows Terminal, отдельных `cmd` и PowerShell.

Для permissions глобальный хоткей возвращает решение точному hook, а родной prompt Claude остаётся доступен. Вопросы, option picker и plan approval остаются focus-only и отвечаются в UI Claude. Claude можно независимо выключить через **Active for → Claude Code**.

Ограничения: собственный classifier Claude может решить действие до вызова hook; терминальные меню вроде `/model` и свободный ввод не показываются; hook может ждать ответ до 60 минут.

## OpenAI Codex

Стандартная установка решает две задачи:

1. **Permissions.** Сначала окно решения получает press-1, затем неотвеченный запрос передаётся родному prompt Codex.
2. **Needs-user уведомления.** Нативный `request_user_input` без ответа или явный финальный контракт ответа создаёт focus-only карточку.

Обычная вопросительная проза намеренно игнорируется ради защиты от ложных уведомлений. Карточка может показать вопрос и сфокусировать вероятное окно, но никогда не отправляет номер или текст ответа.

### Стандартный маршрут

| Поверхность | Ручной или неопределённый permission |
|---|---|
| Терминал редактора, Windows Terminal, обычная панель VS Code | Около 15 секунд в press-1, затем handoff родному UI |
| Отдельный `cmd` / PowerShell, Native Desktop | До 60 секунд в press-1, затем handoff родному UI |

`Ctrl+Win+Esc` делает handoff сразу. **Always allow** пытается сохранить правило по префиксу команды; текущее действие всё равно разрешается, если persistence не удался.

### Экспериментальный auto-review bypass

До показа permission стандартный hook проверяет текущий локальный тёрн Codex. press-1 молчит только при точном same-turn совпадении `approvals_reviewer: "auto_review"`; неоднозначность и любая ошибка чтения или парсинга возвращают обычный popup.

Проверка читает только ограниченный хвост локального rollout в `~/.codex/sessions` и ничего не загружает наружу. Если все standard-hook запросы должны проходить через press-1, отключите **Codex → Let Auto-review decide (experimental)**. `Ctrl+Win+D` показывает результат последней пробы.

### Экспериментальный proxy панели VS Code

Опциональный транспорт `codex-mitm` зеркалит уже прошедшие reviewer approvals панели VS Code и может закрыть родную карточку напрямую. Он не входит в стандартную установку и использует `chatgpt.cliExecutable`, который OpenAI помечает как development-only.

```powershell
.\enable-codex-proxy.ps1
.\disable-codex-proxy.ps1
```

После любой команды перезагрузите VS Code. Если панель ведёт себя неправильно, отключите proxy: стандартный hook остаётся поддерживаемым маршрутом. Сценарии отказа описаны в [дизайне proxy](docs/DESIGN-CODEX-PROXY.md).

## Установка

Требуется Windows 10/11. Bootstrap при необходимости ставит AutoHotkey v2 и Node.js через `winget`, затем устанавливает press-1:

```powershell
irm https://raw.githubusercontent.com/egsok/press-1/main/bootstrap.ps1 | iex
```

Чтобы сначала посмотреть код:

```powershell
git clone https://github.com/egsok/press-1
cd press-1
.\install.ps1
```

Установщик добавляет только записи press-1 в конфиги hooks Claude и Codex, создаёт бэкапы, проверяет trust Codex-hooks, копирует resident AHK и process-private шрифты, добавляет автозапуск и перезапускает press-1. Чужие hooks и tray-настройки сохраняются. Экспериментальный proxy панели автоматически не включается.

Если установщик просит ручной trust Codex, запустите `codex`, откройте `/hooks`, подтвердите записи press-1 и повторите установку. После обновления один раз перезагрузите открытые окна редактора, если установщик об этом попросит.

## Ограничения

- Только Windows; агент должен работать на том же компьютере. Удалённые SSH/tmux-сессии локально не видны.
- Вопросы и option picker остаются focus-only, пока нет проверенного decision-канала.
- При ответе в родном UI карточка может жить до завершения текущего tool; ответ через press-1 убирает её сразу.
- Точный terminal-tab нельзя сфокусировать без расширения редактора. Неоднозначный матч завершается безопасно.

## Решение проблем

| Симптом | Что проверить |
|---|---|
| Нет popup | Tray icon, переключатель **Active for**, Node.js и конфиг hooks нужного агента |
| Codex hooks не trusted | В Codex откройте `/hooks`, подтвердите все записи press-1 и повторите `install.ps1` |
| Codex остановился на вопросе без карточки | Уведомления вызывают только нативный `request_user_input` и явные финальные контракты ответа; перезагрузите редактор и проверьте hooks |
| Codex должен auto-review, но появился press-1 | После смены режима начните новый тёрн; проверьте experimental toggle и `Ctrl+Win+D` |
| Фокус редактора неоднозначен | Нажмите Focus ещё раз для перебора точных совпадений; `Ctrl+Win+D` показывает детали |
| Proxy-панель ведёт себя неправильно | Запустите `.\disable-codex-proxy.ps1` и перезагрузите VS Code |

## Как это работает

Hooks пишут адресные pending-записи в `%TEMP%\press-1`; resident AutoHotkey показывает их и возвращает решение только совпавшему запросу. Teardown hooks удаляют завершённые и мёртвые записи. Attention hooks Codex создают focus-only карточки для поддерживаемых user-answer блокеров.

Протокол, trust-модель, таймауты и поведение при ошибках описаны в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Офлайн-тесты лежат в [tests/](tests/).

## Технологии и автор

Сделал [Егор Соколов](https://egorsokolov.ru/) вместе с AI, проверил человек. press-1 использует [AutoHotkey v2](https://www.autohotkey.com/), Node.js, vendored [AHKv2-Gdip](https://github.com/buliasz/AHKv2-Gdip) и OFL-шрифты IBM Plex и Unbounded.

[![Telegram](https://img.shields.io/badge/Telegram-%40neiroset__ne__vinovata-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/+AHKYCN02eONjYTVi)

Другие эксперименты: [plan-tango](https://github.com/egsok/plan-tango), [napotom](https://github.com/egsok/napotom) и [klava-nevinovata](https://github.com/egsok/klava-nevinovata).

## Лицензия

MIT — см. [LICENSE](LICENSE). Copyright (c) 2026 Egor Sokolov.
