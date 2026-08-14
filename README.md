<div align="center">

# ⌨️ press-1

**Know the moment your AI agent needs you — approve permissions globally or jump straight to a waiting question.**

**English** · [Русский](README.ru.md)

[![Latest Release](https://img.shields.io/github/v/release/egsok/press-1?style=for-the-badge)](../../releases/latest)
![Platform](https://img.shields.io/badge/Platform-Windows-blue?style=for-the-badge)
![Agents](https://img.shields.io/badge/Agents-Claude%20Code%20%C2%B7%20Codex-452BA6?style=for-the-badge)
![Editors](https://img.shields.io/badge/Editors-VS%20Code%20%C2%B7%20Cursor%20%C2%B7%20Windsurf-2496ED?style=for-the-badge)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

![press-1](assets/press-1.png)

</div>

---

AI coding agents stop for permissions and user choices in whichever terminal, editor, or monitor they happen to occupy. That prompt is easy to miss, so an agent can sit idle while you think it is still working.

**press-1 shows every supported waiting checkpoint in one always-on-top popup and plays a soft sound.** Approve a permission with one global hotkey; when Codex needs an ordinary answer, jump straight to the waiting window. Every decision remains yours.

## Watch press-1 in action

https://github.com/user-attachments/assets/846ec00b-f291-4d3f-b5e2-38d6d154de10

![press-1 across three monitors](assets/press-1-3-monitors.png)

## What it gives you

- **No prompt hunting.** See and hear requests even when the agent is buried under other windows or running on another monitor.
- **Decide from context.** Each card shows the agent, project, command, file, or question. Long commands can be expanded in place.
- **Global controls.** Use the keyboard, clickable popup buttons, or any macro pad that can send function keys.
- **Safe routing.** A decision is addressed to one exact waiting request. If that request is already gone, the answer is dropped instead of being typed into another window.

![The press-1 popup](assets/press-1-popup.png)

Permission cards mirror the real two- or three-option prompt. Needs-user cards are deliberately focus-only: **Focus terminal / Focus panel** finds the likely Codex window but never guesses or types the answer. Repeated Focus cycles through editor windows with the same exact title and briefly outlines the selected one.

## Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl+Win+1 / 2 / 3` | Choose option 1 / 2 / 3 on the active permission card |
| `Ctrl+Win+↑ / ↓` | Move through waiting cards |
| `Ctrl+Win+E` | Expand or collapse the full command |
| `Ctrl+Win+Esc` | Close the popup; hand a held request back to the native UI |
| `Ctrl+Win+D` | Show routing diagnostics |

press-1 also listens on `F13`–`F21`, so macro pads and consoles can use dedicated keys.

<table align="center">
  <tr>
    <td align="center"><img src="assets/logitech-mx-console.jpg" alt="Logitech MX Creative Console running press-1" height="400"><br><sub>My Logitech MX Creative Console</sub></td>
    <td align="center"><img src="assets/macro-pad.png" alt="A bare 3-key macro pad" height="400"><br><sub>A minimal three-key macro pad works too</sub></td>
  </tr>
</table>

### Choose the popup displays

The default target is the display marked **Main display** in Windows — not whatever Windows happens to call monitor 1. From the tray, open **Popup displays** and select one screen or any combination of screens. Copies share one state: answering or closing any copy clears them all.

The choice follows the physical monitor through Windows renumbering and rearrangement. If every selected display is disconnected, press-1 temporarily uses the current primary without forgetting the choice. Popup size follows each display's Windows scaling, including mixed 100%/150% setups.

## Support status

The boundary is intentionally explicit:

| Level | Included |
|---|---|
| **Supported and enabled by default** | Claude Code permission hooks; Codex standard permission hooks; Codex needs-user alerts; multi-display popup and hotkeys |
| **Best effort** | Focusing the exact editor/terminal; detecting explicit text checkpoints such as “Reply with the option number.” These paths fail safe and may miss unusual wording or ambiguous windows |
| **Experimental, enabled by default** | Codex same-turn `auto_review` bypass, because it reads a version-sensitive local rollout format |
| **Experimental, opt-in** | Codex VS Code panel proxy (`codex-mitm`) |

### Which setup should I use?

**Recommendation: start with the one-line standard install.** It already includes every core feature: Claude and Codex permissions, Codex needs-user alerts, global hotkeys, window focus, and multi-display popup. You do not need the proxy to be notified when Codex is waiting for an ordinary answer.

Enable the experimental proxy only if the **Codex panel in VS Code is your main interface** and you want its permission cards to remain directly answerable from press-1 regardless of focus, delay, or several similar VS Code windows. Without the proxy, the standard hook has a direct decision channel for about 15 seconds; after native handoff, panel control becomes best effort. With the proxy, the native card and press-1 appear together and the popup answers through `app-server` directly.

The proxy changes only VS Code panel permissions. It adds nothing to needs-user alerts, Codex CLI, Windows Terminal, Native Desktop, Claude Code, or display selection. It is useful for a demanding panel-heavy workflow, but it is not the recommended default for everyone.

press-1 itself is **not an auto-approver**. It never chooses Allow, Always allow, or Deny for you. The experimental reviewer integration only steps aside when the current Codex turn is unambiguously in its own automatic-review mode.

## Claude Code

The installer registers a `PermissionRequest` hook for:

- VS Code, Cursor, and Windsurf panels and integrated terminals;
- Windows Terminal, standalone `cmd`, and PowerShell.

For permissions, the global hotkey returns a decision to the exact hook while Claude's native prompt remains usable. Questions, option pickers, and plan approvals are focus-only and stay in Claude's UI. Claude can be disabled independently through **Active for → Claude Code**.

Limitations: Claude's own classifier may resolve an action before any hook fires; terminal-only menus such as `/model` and free-text input are not surfaced; a hook request can wait for up to 60 minutes.

## OpenAI Codex

The standard install covers two jobs:

1. **Permissions.** press-1 gets the first decision window, then hands unresolved requests to Codex's native prompt.
2. **Needs-user alerts.** An unmatched native `request_user_input` or an explicit final answer contract creates a focus-only card.

Broad question-like prose is deliberately ignored to avoid false notifications. The card can show the question and focus the likely window, but it never submits a number or free-text answer.

### Standard route

| Surface | Manual or uncertain permission |
|---|---|
| Editor terminal, Windows Terminal, ordinary VS Code panel | About 15 seconds in press-1, then native handoff |
| Standalone `cmd` / PowerShell, Native Desktop | Up to 60 seconds in press-1, then native handoff |

`Ctrl+Win+Esc` hands off immediately. **Always allow** attempts to save a command-prefix rule; the current action is still allowed if persistence fails.

### Experimental auto-review bypass

Before showing a standard-hook permission, press-1 checks the current local Codex turn. Only an exact same-turn `approvals_reviewer: "auto_review"` match makes press-1 stay silent; ambiguity or any read/parse error falls back to the normal popup.

This check reads only a bounded tail of the local `~/.codex/sessions` rollout and uploads nothing. Disable it through **Codex → Let Auto-review decide (experimental)** if you want every standard-hook request to use press-1. `Ctrl+Win+D` shows the latest probe result.

### Experimental VS Code panel proxy

The optional `codex-mitm` transport mirrors post-review VS Code panel approvals and can resolve the native card directly. It is excluded from the standard install and relies on `chatgpt.cliExecutable`, which OpenAI marks development-only.

```powershell
.\enable-codex-proxy.ps1
.\disable-codex-proxy.ps1
```

Reload VS Code after either command. If the panel misbehaves, disable the proxy; the standard hook remains the supported path. See [the proxy design notes](docs/DESIGN-CODEX-PROXY.md) for its failure modes.

## Install

Windows 10/11 is required. The bootstrap installs AutoHotkey v2 and Node.js through `winget` when missing, then installs press-1:

```powershell
irm https://raw.githubusercontent.com/egsok/press-1/main/bootstrap.ps1 | iex
```

To inspect the code first:

```powershell
git clone https://github.com/egsok/press-1
cd press-1
.\install.ps1
```

The installer merges only press-1 entries into the Claude and Codex hook configs, writes backups, verifies Codex hook trust, copies the resident AHK script and process-private fonts, adds autostart, and restarts press-1. Existing agent hooks and tray preferences are preserved. The experimental panel proxy is never enabled automatically.

If the installer asks for manual Codex trust, run `codex`, open `/hooks`, approve the press-1 hooks, and run the installer again. After an upgrade, reload open editor windows once if prompted.

## Limitations

- Windows only; the agent must run on the same machine. Remote SSH/tmux sessions are not visible locally.
- Questions and option pickers remain focus-only unless a verified decision channel exists.
- If you answer in the agent's native UI, a card may remain until the current tool returns; a press-1 answer clears immediately.
- Exact terminal-tab focus is not available without an editor extension. Ambiguous matches fail safe.

## Troubleshooting

| Symptom | Check |
|---|---|
| No popup | Confirm the tray icon, **Active for** switch, Node.js, and the relevant hook config |
| Codex hooks are not trusted | Use Codex `/hooks`, approve all press-1 entries, then rerun `install.ps1` |
| Codex stopped on a question without a card | Only native `request_user_input` and explicit final answer contracts trigger alerts; reload the editor and verify hooks |
| Codex should auto-review but press-1 appears | Start a new turn after changing the mode; inspect the experimental toggle and `Ctrl+Win+D` |
| Editor focus is ambiguous | Press Focus again to cycle exact-title matches; `Ctrl+Win+D` shows routing details |
| Proxied panel misbehaves | Run `.\disable-codex-proxy.ps1` and reload VS Code |

## How it works

Hooks write addressed pending records under `%TEMP%\press-1`; the resident AutoHotkey process renders them and returns a decision only to the matching request. Teardown hooks remove resolved or dead records. Codex attention hooks create focus-only records for supported user-answer blockers.

The protocol, trust model, timeouts, and failure behavior are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Offline suites live in [tests/](tests/).

## Credits and author

Built by [Egor Sokolov](https://egorsokolov.ru/) with AI, checked by a human. press-1 uses [AutoHotkey v2](https://www.autohotkey.com/), Node.js, vendored [AHKv2-Gdip](https://github.com/buliasz/AHKv2-Gdip), and bundled OFL fonts IBM Plex and Unbounded.

[![Telegram](https://img.shields.io/badge/Telegram-%40neiroset__ne__vinovata-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/+AHKYCN02eONjYTVi)

Other experiments: [plan-tango](https://github.com/egsok/plan-tango), [napotom](https://github.com/egsok/napotom), and [klava-nevinovata](https://github.com/egsok/klava-nevinovata).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Egor Sokolov.
