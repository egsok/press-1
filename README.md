<div align="center">

# ⌨️ press-1

**Answer your AI agent's permission prompts with a single keypress — from any window, on any monitor, without switching focus.**

**English** · [Русский](README.ru.md)

[![Latest Release](https://img.shields.io/github/v/release/egsok/press-1?style=for-the-badge)](../../releases/latest)
![Platform](https://img.shields.io/badge/Platform-Windows-blue?style=for-the-badge)
![Agents](https://img.shields.io/badge/Agents-Claude%20Code%20%C2%B7%20Codex-452BA6?style=for-the-badge)
![Editors](https://img.shields.io/badge/Editors-VS%20Code%20%C2%B7%20Cursor%20%C2%B7%20Windsurf-2496ED?style=for-the-badge)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

![press-1](assets/press-1.png)

</div>

---

AI coding agents like Claude Code and Codex stop and ask before they do anything consequential — *run this command? edit this file? delete that?* The catch: the prompt appears wherever the agent happens to be running, which is rarely the window you're looking at. So the agent sits and waits, you lose time and flow hunting for the prompt — or worse, you never notice it and your agent is just idle.

**press-1 surfaces every waiting prompt in one small always-on-top popup, plays a soft sound, and lets you answer with a single global hotkey — without leaving whatever you're doing — or with a click in the popup itself. Either way your focus stays put.** Every decision is still yours; press-1 just removes the window-hunting between you and the prompt.

![press-1 across three monitors](assets/press-1-3-monitors.png)

## Why you'll want it

- **Several monitors** — A prompt pops up on a screen you're not looking at. Normally that's reach for the mouse → click into the window → answer: a handful of actions across the desk. press-1 collapses it to one hotkey — no mouse, no focus change.
- **One screen, lots of windows** — Your editor or terminal is buried under other windows and you don't even see the prompt. The agent waits while you think it's working — pure lost time. press-1 makes sure you always see *and* hear it.
- **Even on a laptop** — You kicked off a task and threw a YouTube video on top of the terminal. The sound and popup tell you the moment you're needed, and you can approve without closing the video.
- **Context, right in the popup** — The popup shows what's being asked (the command, the file, the question), so most of the time you can decide without ever looking at the terminal. Need the full picture? One button jumps you straight to the right window.
- **A soft, unobtrusive sound** lets you know attention is needed — and it's one click to mute if you'd rather keep things quiet.
- **No keyboard needed** — You can handle prompts entirely with the mouse, clicking right in the popup.

## The popup

![The press-1 popup](assets/press-1-popup.png)

- A two-ink card stack on a deep ink-violet wall, one card per waiting prompt — oldest at the top. Hotkeys answer the **active** card: its title prints sharp and a magenta registration mark lights up in its corner, while queued cards sit slightly "off-register", like prints waiting for the press. `Ctrl+Win+↑/↓` moves the selection.
- Each card shows which agent is asking (a `CLAUDE` / `CODEX` chip) and the one action that's waiting — `Bash(npm test)`, `Write(src/config.ts)`, and so on. Long commands get an **Expand ▾** control (`Ctrl+Win+E`) that unfolds the full command right on the card.
- Buttons map to the real 2- or 3-option layout and are clickable. `🔍` normally focuses the prompt's window **without** answering. On an opt-in Codex panel proxy card, where press-1 cannot address the webview directly, it only hides the local popup; the native card stays waiting.
- A card disappears when its route reports that the prompt is resolved. The exact lifecycle differs between Claude Code and Codex; both are described below.

## Hotkeys

Out of the box: **Ctrl+Win+1 / 2 / 3** answer the selected prompt (option 1 / 2 / 3), and **Ctrl+Win+Esc** closes the popup without approving. If a hook is holding the request, `Ctrl+Win+Esc` immediately hands it back to the agent's native UI. The buttons always mirror the prompt's real options, so a digit never means something different from what you see.

Prefer dedicated keys? Map them to **whatever hardware you like** — a macro pad, a mini keyboard, a stream-deck-style console, a keypad with little screens. Out of the box, press-1 also listens on `F13`–`F21`, so anything that can send those works. Use whatever's comfortable.

<table align="center">
  <tr>
    <td align="center">
      <img src="assets/logitech-mx-console.jpg" alt="Logitech MX Creative Console running press-1" height="450"><br>
      <sub><b>My own setup</b> — a Logitech MX Creative Console; the top row (CC&nbsp;1/2/3) answers press-1.</sub>
    </td>
    <td align="center">
      <img src="assets/macro-pad.png" alt="A bare 3-key macro pad" height="450"><br>
      <sub><b>Or go minimal</b> — a 3-key macro pad is cheap, tiny, and does the whole job.</sub>
    </td>
  </tr>
</table>

## Not an auto-approver

The important part: **press-1 itself never answers for you.** When it handles a prompt, it does not auto-approve, bypass the check, or "trust" commands. Every decision remains deliberate — one keypress or click. If the agent itself is running an automatic approval mode, press-1 may never receive the request or may deliberately step aside; in that case the agent makes the decision, not press-1.

## Claude Code

Claude Code has one consistent route across all supported surfaces: the installer registers a `PermissionRequest` hook, press-1 surfaces the request, and Claude's native prompt remains available at the same time. Answer in either place; the losing route closes itself.

### Where it works

- **Panel and integrated terminal** in VS Code, [Cursor](https://cursor.com/), and [Windsurf](https://windsurf.com/).
- **Windows Terminal**, plus standalone `cmd` and PowerShell windows.

For ordinary permission prompts, the hotkey returns a decision directly to the exact waiting hook — no focus switch and no digit typed into another window. Questions, option pickers, and plan approvals appear as attention cards: the hotkey takes you to the correct window and you answer in Claude's own UI.

You can disable Claude handling from the tray: **Active for → Claude Code**. The installed hooks stay in place but immediately defer to Claude's native UI.

### Claude Code limitations

- The press-1 answer window is 60 minutes; Claude's native prompt remains usable throughout.
- If Claude's own classifier resolves a permission automatically, no hook fires and press-1 stays silent.
- Terminal-only menus such as `/model` and free-text input are not surfaced.

## OpenAI Codex

Codex runs its hook **before** rendering its own approval UI. There are two transport routes: the standard hook, enabled by the normal install on every supported surface, and the separate opt-in proxy for the VS Code panel. The experimental auto-review bypass is a policy inside the standard hook, not a Desktop-only route.

| Where Codex runs | Route | Exact same-turn `auto_review` | Manual, unknown, or probe error |
|---|---|---|---|
| CLI in an editor terminal / Windows Terminal | Standard hook | press-1 stays silent; Codex's reviewer decides | press-1 first; native prompt after handoff |
| CLI in standalone `cmd` / PowerShell | Standard hook | press-1 stays silent; Codex's reviewer decides | Only press-1 until handoff or the 60-second timeout |
| VS Code panel without proxy | Standard hook | press-1 stays silent; Codex's reviewer decides | press-1 first; native card after handoff |
| Native Desktop | Standard hook | press-1 stays silent; Codex's reviewer decides | press-1 is primary; native card after handoff |
| VS Code panel with proxy | Separate opt-in | Not applicable: auto-resolved actions never reach the proxy | Native card and press-1 together for a real manual request |

### Standard hook — the default

The installer registers the Codex hook automatically. In an editor terminal, Windows Terminal, and the ordinary VS Code panel, press-1 gets a short decision window of about 15 seconds. If you do not answer, the hook releases Codex and its native prompt appears. On a timed handoff, a terminal card never sends a digit — it only focuses the native prompt. A panel card can remain a remote, but it sends an option only when one matching window is already active; otherwise it also focuses only. `Ctrl+Win+Esc` hands off immediately and closes the local card.

Standalone `cmd` / PowerShell and Native Desktop in **Ask for approval** use a decision-only window of up to 60 seconds. If press-1 answers, the native card never appears; after a handoff or timeout, the request continues in Codex's native UI.

For command approvals, **Always allow** attempts to save a command-prefix rule. The current action is still allowed if persistence fails; Codex may also fail to match the rule for some complex PowerShell commands and ask again later.

### Auto-review bypass on the standard hook

Before creating a pending file or playing a sound, the standard hook checks the current turn's reviewer. This happens on every standard hook surface: CLI in standalone terminals, Windows Terminal and editor terminals, the non-proxy VS Code panel, and Native Desktop.

Only an exact same-turn `approvals_reviewer: "auto_review"` match is bypassed. press-1 returns no decision of its own and leaves the action to Codex's reviewer. A `user` reviewer, an unknown value, a missing/mismatched/conflicting record, or any read, parse, or time-budget error follows the ordinary popup route. Reviewer choice belongs to the turn, so changing **Approve for me / Ask for approval** affects only a **new turn**; a turn already in progress keeps its original reviewer.

To make that check, the hook reads only the newest bounded portion (up to 32 MiB) of the current Codex rollout transcript stored locally under `~/.codex/sessions`. press-1 does not upload or copy it elsewhere. The optional diagnostic status contains only fixed outcome/reason labels, timing, and byte counts — never commands, paths, turn IDs, or transcript content.

This integration is on by default and relies on version-sensitive Codex internals. Any uncertainty safely falls back to the ordinary press-1 popup. To make every standard-hook request use the popup, uncheck **Codex → Let Auto-review decide (experimental)** in the tray. Its backing opt-out file intentionally keeps the historical name `~/.press-1-off-codex-desktop-auto-review`, so an existing preference survives upgrades.

`Ctrl+Win+D` shows the latest Codex reviewer probe from the last 10 minutes, such as `auto_pass / exact_auto_review`. It is a record of the last event, not an indicator of the selector's current position.

### VS Code panel proxy — advanced opt-in

The optional `codex-mitm` stdio proxy applies only to the Codex panel in VS Code. It sits between the extension and `codex app-server`, sets `PRESS1_PROXY=1` so the global hook and its reviewer probe stay out of that panel, mirrors a real `requestApproval` into the popup, and injects your answer back. The native card and press-1 therefore appear together, and a hotkey answer resolves the native card like a click.

The proxy is deliberately excluded from the transcript-based bypass: its requests have already passed the reviewer and are real manual approvals. In `Approve for me`, actions resolved automatically never reach the proxy; a popup appears only for a request that Codex actually sent for manual approval.

The proxy is not part of the standard install. After using the one-line installer, clone or download the repository first, then run these commands from its folder (Node.js required; reload your VS Code windows after either command):

```powershell
.\enable-codex-proxy.ps1     # builds codex-mitm.exe and sets chatgpt.cliExecutable
.\disable-codex-proxy.ps1    # removes the setting and returns to bundled Codex
```

This is **experimental and off by default**:

- The channel relies on `chatgpt.cliExecutable`, which OpenAI marks **DEVELOPMENT ONLY**; an extension update may break it.
- The wrapper sits in the panel's critical path, but its relay is relay-first: a popup-side failure should not stop frames from passing. If the panel misbehaves, run the disable script and reload the window.
- **Deny** through the proxy hard-aborts the current turn. The native Deny button declines gracefully and lets the agent continue.
- Enable keeps a write-once copy of the original `settings.json` as `settings.json.press1-bak`. Disable removes `chatgpt.cliExecutable` but does not automatically restore a previous custom value; recover it from the backup if needed.

Design and failure modes are documented in [docs/DESIGN-CODEX-PROXY.md](docs/DESIGN-CODEX-PROXY.md) (Russian).

### Codex controls

- **Active for → Codex** — master switch for hooks and proxy-row visibility. It does not uninstall or disable an enabled panel proxy; the native panel remains usable, and a still-live proxy row becomes visible again when you re-enable Codex.
- **Codex → Let Auto-review decide (experimental)** — exact same-turn `auto_review` bypass on every standard hook surface; it does not apply to the panel proxy.
- `enable-codex-proxy.ps1` / `disable-codex-proxy.ps1` — only the VS Code panel transport.
- **Mute prompt sound** — press-1's sound; it does not mute Codex's own notifications.

These settings survive press-1 upgrades: reinstalling does not reset them or turn off an already enabled proxy.

## Install

**The fast way — one line.** It installs the prerequisites it needs (AutoHotkey v2 and Node.js, via `winget`, only if they're missing) and then press-1 itself:

```powershell
irm https://raw.githubusercontent.com/egsok/press-1/main/bootstrap.ps1 | iex
```

That's it — you're done. (If you're upgrading from an older press-1, the installer will tell you to reload your editor windows once.)

**Prefer to read the code first?** Clone the repo, look it over, and run the same installer:

```powershell
git clone https://github.com/egsok/press-1
cd press-1
.\install.ps1
```

`install.ps1` checks for **[AutoHotkey v2](https://www.autohotkey.com/)** and **[Node.js](https://nodejs.org/)**, offers to install whichever is missing via `winget`, sets everything up, and (re)starts AutoHotkey. You're set.

**Requirements:** Windows 10/11 and at least one supported agent — Claude Code and/or Codex. VS Code, Cursor, or Windsurf is only required for editor-based scenarios. `winget` (built into current Windows) installs AutoHotkey v2 and Node.js automatically; without it, install both prerequisites by hand and re-run the installer. For Codex hook trust, the installer can use either a `codex` command on `PATH` or the executable bundled with Native Codex Desktop. If Codex is not installed at all, Claude support still installs and the installer clearly reports that the optional Codex surface was skipped.

> **In a hurry?** Hand the repo to your AI agent and ask it to install press-1 — it'll do exactly this. That's the kind of chore it's built for.

<details>
<summary><b>What the installer actually does</b></summary>

<br>

- Installs any missing prerequisite (**AutoHotkey v2**, **Node.js**) via `winget`, after asking — or tells you loudly if `winget` isn't available.
- Copies the two hooks (`permission-request.js`, `session-teardown.js`) to `~\.claude\hooks\`.
- Merges its hook entries into `~\.claude\settings.json` **safely** — only its own entries are touched, your other hooks and settings survive, and a backup is written first. Invalid JSON → it stops loudly and changes nothing.
- Registers Codex hooks in the required wrapper schema in `~\.codex\hooks.json`, writes a backup, resolves either Codex CLI or Native Desktop's bundled executable, and verifies that all press-1 hooks are trusted. If Codex exists but trust cannot be confirmed, installation finishes loudly with a manual `/hooks` action instead of reporting false success. Inactive wrong-schema top-level keys that would break Codex's entire hooks file are saved to `.disabled-by-press-1` and removed from the active config.
- Copies the resident script (`press-1.ahk` + its tray icon) and the popup's bundled fonts (`fonts\`, OFL-licensed — loaded process-private, nothing is installed into Windows) to `~\scripts\`, and adds a startup shortcut.
- (Re)starts AutoHotkey so the new version is live.
- The experimental Codex-panel proxy is **not** part of the install — it's opt-in via `enable-codex-proxy.ps1` (see above).
- An upgrade does not reset tray preferences or disable a proxy that was already enabled.

</details>

## Shared limitations

- **Windows only.** press-1 depends on AutoHotkey and Win32.
- The agent must run on the same Windows machine. A local press-1 cannot see prompts from a process running remotely through SSH, tmux, or screen.
- Questions and option pickers may be focus-only: press-1 never types digits blindly when the target window's internal focus cannot be proven.
- If you answer in the agent's own UI instead of press-1, the card clears when that tool finishes — a long-running command keeps its card on screen until it returns. Answering with a hotkey clears it instantly.

## How it works

Claude Code and the standard Codex route share one local file bus: a hook writes an addressed pending file under `%TEMP%\press-1` and plays the sound, while the resident AutoHotkey script renders the popup and returns a decision to that exact request. If the request is already gone, the answer is dropped — no digit is retyped into an unrelated window.

### Claude Code

The native prompt and hook behave as a race: Claude's UI appears immediately, and the first real decision — from press-1 or Claude — wins. A teardown hook removes the card when the request is resolved in Claude's own UI: it recognises the answered request by the tool that completed, and clears whatever is left over at the end of the turn.

### Codex

The standard Codex hook is a blocking gate before the native prompt, so it first runs the exact same-turn reviewer check and otherwise uses a short decision phase followed by handoff. The opt-in `codex-mitm` replaces the hook only for the VS Code panel and mirrors post-review app-server requests.

| Repo file | Purpose |
|-----------|---------|
| `permission-request.js` | the hook: pending file, sound, decision wait |
| `codex-permission-request.js` | the same hook, Codex flavor (`~\.codex\hooks\`) |
| `codex-reviewer.js` | the Codex auto-review detector, isolated so it can be dropped when upstream ships a reviewer field |
| `session-teardown.js` | removes prompts answered elsewhere |
| `press-1.ahk` | resident script: hotkeys, popup, routing |
| `install.ps1` | installer (Claude + Codex hooks, fonts, autostart) |
| `codex-mitm.js` + `enable`/`disable-codex-proxy.ps1` | the experimental Codex-panel proxy (opt-in) |

The full file-protocol contract is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (Russian). Offline test suites live in [tests/](tests/).

## Troubleshooting

### Shared

| Symptom | Check |
|---------|-------|
| No popup appears | Is AutoHotkey running (press-1 tray icon)? Is the correct agent checked under **Active for**? Is `node` in `PATH`? |
| Per-monitor hotkey hits the wrong window | `Ctrl+Win+D` shows the detected windows and monitor order |

### Claude Code

| Symptom | Check |
|---------|-------|
| Popup appears but hotkeys do not answer | The `PermissionRequest` hook timeout must be at least 3660 seconds; the installer sets it automatically |
| Editor-terminal prompts are not detected | After an upgrade, run **Developer: Reload Window** once; then inspect `~\.claude\settings.json` |
| An automatically allowed action produced no popup | Expected: Claude does not call `PermissionRequest` when it decides by itself |

### Codex

| Symptom | Check |
|---------|-------|
| Codex prompts produce no popup | Check `~\.codex\hooks.json`, trust through `/hooks`, and **Active for → Codex** |
| Installation says Codex hooks are not trusted | Run `codex`, enter `/hooks`, approve all press-1 entries, then re-run `install.ps1`. If the command is unavailable, install or update Codex CLI first |
| No native card appears in Desktop `Ask for approval` | Expected: the press-1 hook runs first. `Ctrl+Win+Esc` immediately hands the request to the native UI |
| press-1 appears although Codex should auto-review | Select the mode before starting a new turn, check **Codex → Let Auto-review decide (experimental)**, and press `Ctrl+Win+D`; exact `user`, ambiguity, and any probe error intentionally fall back to the popup |
| press-1 appears for a proxied panel request in Auto-review | Expected: automatically resolved actions never reach the proxy; anything that does is a real post-review manual request |
| `Ctrl+Win+D` shows an old `auto_pass` | The line records the latest Codex reviewer probe for up to 10 minutes; it is not the current selector |
| The panel misbehaves after enabling the proxy | Run `.\disable-codex-proxy.ps1` from the repository and reload VS Code windows |

## Credits

Made by AI 🤖 · checked by human.

Built on [AutoHotkey v2](https://www.autohotkey.com/) — the popup, hotkeys, and routing are all AHK. The popup is drawn with a vendored copy of the [AHKv2-Gdip](https://github.com/buliasz/AHKv2-Gdip) GDI+ library, and the hooks run on [Node.js](https://nodejs.org/). The two-ink look is set in [IBM Plex](https://github.com/IBM/plex) and [Unbounded](https://fonts.google.com/specimen/Unbounded), bundled under the OFL (see `fonts/OFL-NOTICE.txt`).

## Author

Built by [Egor Sokolov](https://egorsokolov.ru/) — 10 years in product (Sberbank, Rolf, Claustrophobia). Writing and experimenting with AI tooling — mostly Claude Code, Codex, and dev workflow tooling.

📣 My Telegram, where I geek out about AI tooling:

[![Telegram](https://img.shields.io/badge/Telegram-%40neiroset__ne__vinovata-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/+AHKYCN02eONjYTVi)

Other open-source experiments:

- [plan-tango](https://github.com/egsok/plan-tango) — a Claude ↔ Codex plan-review loop for Claude Code.
- [napotom](https://github.com/egsok/napotom) — a desktop video downloader with a queue, a friendly GUI over yt-dlp (YouTube, VK, 1000+ sites).
- [klava-nevinovata](https://github.com/egsok/klava-nevinovata) — a personal fork of Handy, offline speech-to-text tuned for Russian IT.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Egor Sokolov.
