#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; GDI+ wrapper (vendored, buliasz AHKv2-Gdip) for the v6 GDI+ popup renderer
; (BACKLOG 11). Path is relative to THIS file (A_LineFile) so the tests/ harness
; — which #Includes press-1.ahk from tests/ — resolves it too.
#Include %A_LineFile%\..\Gdip_All.ahk

; ---- Configuration ----

PENDING_DIR := EnvGet("TEMP") "\press-1\pending"
PERM_DIR := EnvGet("TEMP") "\press-1"
; Experimental Codex proxy channel (DESIGN-CODEX-PROXY): the stdio-MITM wrapper
; publishes pending files here and reads decision files back — a dir disjoint
; from the hook's PENDING_DIR (schema doesn't cross the schema-v2 regex path).
PROXY_DIR := EnvGet("TEMP") "\press-1\proxy"

; Show popup when this many or more prompts are active
; 1 = always show (even for single prompt), 2 = only when ambiguous
POPUP_MIN_PROMPTS := 1

; v5.2: display cap for pending-only rows (editor terminals, standalone
; WT/conhost, panel pickers). Their PRIMARY cleanup is the session-teardown hook
; (answered) and the AHK liveness gate (window/process died); this cap is only
; the crash backstop, so it's deliberately long — a prompt may legitimately wait
; while the user is away, and killing its row defeats the tool's purpose. MUST
; exceed the hook's decision-wait window (3600000 ms) so it never sweeps a
; pending the hook is still actively waiting on (ARCHITECTURE timeout-chain).
STANDALONE_BACKSTOP_MS := 5400000  ; 90 min

; Per-prompt cursor for duplicate editor-title matches. The key is normally the
; pending's prompt_id, so a new attention starts from candidate 1. Bounded to
; avoid retaining an unbounded history across a long-lived resident process.
P1_EDITOR_FOCUS_CYCLES := Map()

; Read-only focus telemetry surfaced by Ctrl+Win+D. It intentionally stores no
; title/path: only whether Windows restored the selected HWND on another monitor.
P1_LAST_FOCUS_DIAGNOSTIC := ""

; Popup display routing. No preference file means the current Windows primary;
; explicit choices are stable physical-monitor ids, never volatile DISPLAY1/2
; enumeration numbers. The catalog is refreshed on WM_DISPLAYCHANGE.
P1_POPUP_DISPLAY_PREFS_PATH := EnvGet("USERPROFILE") "\.press-1-popup-displays"
P1_POPUP_DISPLAY_PREFS := []
P1_DISPLAY_CATALOG := []
P1_DISPLAY_MENU := 0
P1_DISPLAY_MENU_IDS := Map()
P1_DISPLAY_CHANGE_FN := ""

; ---- Hotkey bindings: default (single-prompt or popup-selected) ----

F13::SendToPrompt("1")         ; Logitech button
F14::SendToPrompt("2")         ; Logitech button
F15::SendToPrompt("3")         ; Logitech button
^#1::SendToPrompt("1")         ; Ctrl+Win+1
^#2::SendToPrompt("2")         ; Ctrl+Win+2
^#3::SendToPrompt("3")         ; Ctrl+Win+3
^#d::DebugPending()            ; Ctrl+Win+D — diagnostic

; ---- Per-monitor hotkeys (Logitech MX Console: 3 monitors × 3 options) ----

F16::MonitorTargeted(1, "1")   ; Monitor 1, option 1
F17::MonitorTargeted(1, "2")   ; Monitor 1, option 2
F18::MonitorTargeted(1, "3")   ; Monitor 1, option 3
F19::MonitorTargeted(2, "1")   ; Monitor 2, option 1
F20::MonitorTargeted(2, "2")   ; Monitor 2, option 2
F21::MonitorTargeted(2, "3")   ; Monitor 2, option 3
; F22-F24 would be Monitor 3 if needed (uncomment below)
; F22::MonitorTargeted(3, "1")
; F23::MonitorTargeted(3, "2")
; F24::MonitorTargeted(3, "3")

; ---- Main dispatch: send option to the right prompt ----

SendToPrompt(key) {
    global POPUP_MIN_PROMPTS
    prevWin := WinGetID("A")

    ; Wait for physical modifier keys to be released
    KeyWait "Ctrl", "T2"
    KeyWait "LWin", "T2"
    KeyWait "RWin", "T2"
    KeyWait "Shift", "T2"
    KeyWait "Alt", "T2"

    ; If popup is visible and has a selection, route to that selection.
    ; Use the popup's stored promptData (what the user sees) — NOT a fresh
    ; ReadAllPrompts(), which can race with newly arriving/cleared prompts
    ; and shift the index under the user's finger.
    if PromptPopup.IsVisible() && PromptPopup.selectedIndex > 0 {
        if PromptPopup.selectedIndex <= PromptPopup.promptData.Length {
            selected := PromptPopup.promptData[PromptPopup.selectedIndex]
            DispatchByKind(selected, key, prevWin, 0)
        }
        PromptPopup.Refresh()
        return
    }

    ; Read active prompts from hook pending files (no phantoms — S1)
    allPrompts := ReadAllPrompts()

    if allPrompts.Length >= POPUP_MIN_PROMPTS {
        ; Show popup for disambiguation
        if !PromptPopup.IsVisible()
            PromptPopup.Show(allPrompts)
        ; Don't send yet — user must click button or select + hotkey
        return
    }

    ; No active prompts — do nothing
    SoundPlay "*48"
}

; Answer attribution toast (BACKLOG 3): confirm WHAT was answered and WHERE it
; went — option label (not just the digit), project, host badge, tool. Label
; falls back to the bare digit when it can't be resolved from the row's
; options (e.g. digit 3 on a 2-option box) — a bare digit is never wrong.
ShowTip(key, promptInfo) {
    label := key
    if promptInfo.HasOwnProp("options") && IsInteger(key) {
        n := Integer(key)
        if n >= 1 && n <= promptInfo.options.Length
            label := promptInfo.options[n]
    }
    tipText := Chr(0x2713) " " label " " Chr(0x2192) " " promptInfo.project_name
    if promptInfo.HasOwnProp("host") {
        agent := promptInfo.HasOwnProp("agent") ? promptInfo.agent : ""
        badge := P1_HostBadge(agent, promptInfo.host)
        if badge != ""
            tipText .= " · " badge
    }
    if promptInfo.tool_name != "" {
        tipText .= "`n" promptInfo.tool_name
        if promptInfo.tool_input_short != ""
            tipText .= "(" promptInfo.tool_input_short ")"
    }
    ToolTip(tipText)
    SetTimer(() => ToolTip(), -3000)
}

; ---- Per-monitor targeting ----

MonitorTargeted(monitorIndex, key) {
    prevWin := WinGetID("A")

    KeyWait "Ctrl", "T2"
    KeyWait "LWin", "T2"
    KeyWait "RWin", "T2"
    KeyWait "Shift", "T2"
    KeyWait "Alt", "T2"

    allPrompts := ReadAllPrompts()

    ; If only 1 prompt, route directly regardless of monitor
    if allPrompts.Length = 1 {
        DispatchByKind(allPrompts[1], key, prevWin, 0)
        return
    }

    if allPrompts.Length = 0 {
        SoundPlay "*48"
        return
    }

    ; Find which VS Code window is on the target monitor
    monitorHwnd := FindVSCodeOnMonitor(monitorIndex)
    if !monitorHwnd {
        ToolTip("No VS Code on monitor " monitorIndex)
        SetTimer(() => ToolTip(), -3000)
        SoundPlay "*48"
        return
    }

    ; Match the window on that monitor to a prompt
    try monitorTitle := WinGetTitle(monitorHwnd)
    catch
        monitorTitle := ""

    for promptInfo in allPrompts {
        variants := BuildNameVariants(promptInfo.project_name)
        for variant in variants {
            if InStr(monitorTitle, variant) {
                DispatchByKind(promptInfo, key, prevWin, monitorHwnd)
                return
            }
        }
    }

    ToolTip("No matching prompt on monitor " monitorIndex)
    SetTimer(() => ToolTip(), -3000)
    SoundPlay "*48"
}

; Route a selected prompt to the right action depending on its kind × host.
;   permission × any decision host → write the decision word for the waiting
;                hook (editor terminal B, panel C, standalone A — every normal
;                host is on the hook-decision channel, S8/S10). Focus never
;                moves, no synthetic keyboard; Claude/Codex core applies the
;                hook decision. Opt-in Codex native-control is the only
;                exception: it sends 1/2/3 to an already-active Codex webview.
;   other kinds → activate the right window (prefer the already-resolved
;                monitorHwnd if provided, else look up by host). prevWin is no
;                longer restored — nothing types into a window anymore.
DispatchByKind(promptInfo, key, prevWin, preferHwnd) {
    kind := promptInfo.HasOwnProp("kind") && promptInfo.kind != ""
        ? promptInfo.kind
        : "permission"
    host := promptInfo.HasOwnProp("host") && promptInfo.host != ""
        ? promptInfo.host
        : "vscode-terminal"
    if kind = "permission" {
        ; Experimental Codex proxy channel: never a hook/native writer — the
        ; wrapper polls its own decision file (WriteProxyDecision). Checked first
        ; so a proxy row can't fall into the decision/native paths below.
        if promptInfo.HasOwnProp("channel") && promptInfo.channel = "proxy" {
            if WriteProxyDecision(promptInfo, key)
                ShowTip(key, promptInfo)
            return
        }
        if promptInfo.HasOwnProp("native_control") && promptInfo.native_control
            && promptInfo.HasOwnProp("agent") && promptInfo.agent = "codex" {
            ; Phase-2 rows of the Codex hybrid (and the panel-only native-only
            ; mode): the hook is gone, the native prompt is visible — the row is
            ; a remote. Panel → fail-closed digit into the webview; terminals →
            ; focus only (their TUI takes 1/2/3 first-class, a blind digit is
            ; never sent). conhost never reaches here (no hybrid rewrite).
            route := NativeRouteForHost(host)
            if route = "panel" {
                if SendCodexNativeDecision(promptInfo, key, prevWin)
                    ShowTip(key, promptInfo)
                return
            }
            if route = "wt-focus" {
                FocusCodexStandalone(promptInfo)
                return
            }
            if route = "editor-focus" {
                FocusCodexEditorTerminal(promptInfo)
                return
            }
            ; unroutable native row (unexpected host) → fall through to the
            ; decision path, which refuses loudly on the missing decision_file
        }
        if host = "vscode-terminal" || host = "vscode-extension" || host = "windows-terminal" || host = "conhost" {
            if SendHookDecision(promptInfo, key)
                ShowTip(key, promptInfo)
        } else {
            ToolTip("Host '" host "' not wired yet")
            SetTimer(() => ToolTip(), -3000)
            SoundPlay "*48"
        }
        return
    }
    if preferHwnd {
        try WinActivate("ahk_id " preferHwnd)
    } else {
        FocusPrompt(promptInfo)
    }
}

; ---- Scenario A focus helpers: standalone Windows Terminal / conhost ----
;
; Since v5.4 DELIVERY to standalone terminals is the hook-decision channel
; (S10) — same as the panel, no window targeting, no synthetic keyboard. The
; helpers below only FOCUS a terminal window (picker rows, the 🔍 button) and
; feed the liveness gate; a wrong window here is a benign miss, not a misroute.

; Resolve the window for a standalone pending, by precision: a single
; glyph-titled window («✳ …» — claude's topic title, so SOME claude tab is
; active there) beats the stored hwnd (one WindowsTerminal.exe process owns
; several windows and MainWindowHandle points at an arbitrary one).
ResolveStandaloneHwnd(promptInfo) {
    exe := promptInfo.HasOwnProp("top_level_exe") ? promptInfo.top_level_exe : ""
    if exe != "" {
        try {
            glyphHits := []
            for hwnd in WinGetList("ahk_exe " exe) {
                try {
                    if IsClaudeTopicTitle(WinGetTitle(hwnd))
                        glyphHits.Push(hwnd)
                }
            }
            if glyphHits.Length = 1
                return glyphHits[1]
        }
    }
    hwnd := promptInfo.HasOwnProp("hwnd") ? promptInfo.hwnd : 0
    if hwnd && WinExist("ahk_id " hwnd)
        return hwnd
    ; PID scan, top-down through the whole chain: top_level_pid alone is blind
    ; for conhost (the console window is attributed to the client cmd.exe, and
    ; conhost.exe owns no windows — confirmed live 2026-06-12). Dead wrapper
    ; PIDs (node/bash) simply yield empty lists.
    candidates := []
    if promptInfo.HasOwnProp("top_level_pid") && promptInfo.top_level_pid
        candidates.Push(promptInfo.top_level_pid)
    if promptInfo.HasOwnProp("ancestry_pids") {
        i := promptInfo.ancestry_pids.Length
        while i >= 1 {
            candidates.Push(promptInfo.ancestry_pids[i])
            i--
        }
    }
    for p in candidates {
        try {
            list := WinGetList("ahk_pid " p)
            if list.Length > 0
                return list[1]
        }
    }
    return 0
}

; Claude Code paints the tab/window title as "<spinner glyph> <topic>" —
; the glyph set is the TUI's star family. A glyph-prefixed title means SOME
; claude tab is active in that window.
IsClaudeTopicTitle(title) {
    t := Trim(title)
    if StrLen(t) < 3
        return false
    first := SubStr(t, 1, 1)
    static glyphs := [Chr(0x2722), Chr(0x2733), Chr(0x2736), Chr(0x2738),
        Chr(0x273A), Chr(0x273B), Chr(0x273D)]  ; ✢ ✳ ✶ ✸ ✺ ✻ ✽
    for g in glyphs {
        if first = g
            return true
    }
    return false
}

; Card title for a standalone (WT/conhost) prompt (BACKLOG 13). The hook stores
; project_name = basename(cwd), which reads "Egor Sokolov" for a session started
; from the home folder — uninformative. CC paints the tab/window title as
; "<glyph> <topic>", so prefer that topic. IsClaudeTopicTitle doubles as the
; generic-title guard: a shell title ("Windows PowerShell", "cmd.exe", "") has no
; status glyph, so we fall back to project_name. Pure (no window access) so the
; offline harness can pin the reject-generic intent.
StandaloneTitleOrFallback(winTitle, fallback) {
    if IsClaudeTopicTitle(winTitle) {
        topic := Trim(SubStr(Trim(winTitle), 2))   ; drop the leading status glyph
        if topic != ""
            return topic
    }
    return fallback
}

; Resolve the live claude tab topic for a standalone card title, or "" to keep
; project_name. Window-touching (kept out of the pure helper above); reuses the
; existing glyph-aware window resolver. Read at card-build time, not in the hook,
; because the topic is set after session start and may post-date the prompt.
StandaloneCardTitle(info) {
    hwnd := ResolveStandaloneHwnd(info)
    if !hwnd
        return ""
    title := ""
    try title := WinGetTitle(hwnd)
    return StandaloneTitleOrFallback(title, "")
}

; ---- Codex hybrid phase-2 helpers (native rows: the hook already exited) ----

; Routing table for a codex native_control permission row — pure so the offline
; harness can pin it (the finding class behind this: a native WT row silently
; falling into SendHookDecision and refusing on its empty decision_file).
NativeRouteForHost(host) {
    return host = "vscode-extension" ? "panel"
        : host = "windows-terminal" ? "wt-focus"
        : host = "vscode-terminal" ? "editor-focus"
        : ""
}

; Codex TUI paints "[ ! ] Action Required" (blinking to "[ . ]") into the
; terminal title while an approval waits — the codex analog of claude's glyph
; scan (RESEARCH-CODEX §7). Pure helper, offline-testable.
IsCodexActionTitle(title) {
    return RegExMatch(Trim(title), "^\[\s*[!.]\s*\]\s*Action Required") ? true : false
}

; Pick the ONE window carrying a codex action-required title from [{hwnd, title}]
; candidates. 0 or 2+ matches → 0: an arbitrary MainWindowHandle among several
; WT windows would focus the wrong one, so ambiguity means "don't touch focus".
; Pure (callers feed it the live window list) so the harness can pin the guard.
PickCodexActionHwnd(candidates) {
    hits := []
    for c in candidates {
        if IsCodexActionTitle(c.title)
            hits.Push(c.hwnd)
    }
    return hits.Length = 1 ? hits[1] : 0
}

; Full phase-2 target resolution for a standalone codex row: unique action-titled
; window first; else, when the terminal exe owns exactly ONE window overall, that
; window is unambiguous by count alone (live smoke CX8: the action title may
; never reach the WT window title — background tab, or the TUI title drifted —
; and the common single-WT-window setup shouldn't degrade to tooltip-only).
ResolveCodexStandaloneTarget(candidates) {
    t := PickCodexActionHwnd(candidates)
    if t
        return t
    return candidates.Length = 1 ? candidates[1].hwnd : 0
}

; Count-of-one fallback for the PANEL native route (CX4): FindUniqueEditorByName
; is blind when the chat's cwd basename matches no window title (a panel chat
; can run on home cwd while living in a workspace window). A single editor
; window is the host by elimination — callers may ACTIVATE it but never send
; the digit into it (circumstantial ID, not positive: a ≤TTL pending can
; outlive its closed window). Pure for the offline harness.
ResolveCodexPanelFallback(wins) {
    return wins.Length = 1 ? wins[1] : 0
}

; Phase-2 hotkey on a codex standalone (WT) native row: focus ONLY on an
; unambiguous action-titled window; otherwise tooltip without touching focus.
; The digit is NEVER sent — the TUI takes 1/2/3 first-class once focused.
; CX-S7 caveat: if the OSC title never reaches the WT window title, this
; degrades to tooltip-only (the row stays a reminder; focus by hand).
FocusCodexStandalone(promptInfo) {
    exe := promptInfo.HasOwnProp("top_level_exe") ? promptInfo.top_level_exe : ""
    candidates := []
    if exe != "" {
        try {
            for hwnd in WinGetList("ahk_exe " exe) {
                t := ""
                try t := WinGetTitle(hwnd)
                candidates.Push({hwnd: hwnd, title: t})
            }
        }
    }
    target := ResolveCodexStandaloneTarget(candidates)
    if target {
        ActivateHwnd(target)
        ToolTip("Answer in Codex: press 1/2/3")
    } else {
        ToolTip("Answer in Codex: press 1/2/3 (terminal window not uniquely identified)")
    }
    SetTimer(() => ToolTip(), -3500)
}

; Phase-2 hotkey on a codex editor-terminal native row: surface the right editor
; window and let the user press the digit in the TUI. Editor terminals use the
; full restore/activation path; the gentle policy is reserved for extension
; panels, where the stronger path previously caused a focus war.
FocusCodexEditorTerminal(promptInfo) {
    editorExe := promptInfo.HasOwnProp("editor_exe") ? promptInfo.editor_exe : ""
    choice := FocusWorkspace(promptInfo.project_name,
        P1_EditorFocusGentle("vscode-terminal"), editorExe,
        P1_EditorFocusCycleKey(promptInfo))
    if choice && choice.total = 1 {
        ToolTip("Answer in Codex: press 1/2/3")
        SetTimer(() => ToolTip(), -3500)
    }
}

; Live codex native-control panel pendings mapping to the same target window
; (project_name + editor_exe). The webview digit is NOT row-addressed — it lands
; in whichever approval is active — so SendCodexNativeDecision refuses to send
; when more than one prompt shares the target.
CountCodexPanelNativeTargets(projectName, editorExe) {
    n := 0
    for pi in ReadAllPending() {
        if pi.native_control && pi.agent = "codex" && pi.host_type = "vscode-extension"
            && pi.project_name = projectName && pi.editor_exe = editorExe
            n++
    }
    return n
}

; Panel permission prompt (scenario C): the hook is blocked waiting for a
; decision word in decision_file. Digits keep their native-box meaning,
; which DEPENDS on the box layout (mirrored by the row's options):
;   3-option box: 1 = Allow, 2 = Always allow (hook echoes
;                 permission_suggestions as updatedPermissions), 3 = Deny.
;   2-option box ("1 Yes / 2 No" — e.g. out-of-workspace writes): 2 = Deny.
;                 Mapping it to "always" would invert the user's "No" into an
;                 allow (unknown "always" degrades to allow) — seen live
;                 2026-06-12 on "Allow write to %TEMP%\...".
;   3 = Deny on ANY layout (deny is always a valid hook decision; preserves
;                 muscle memory even when the box has no option 3).
; "pass" (written on popup dismissal) releases the hook immediately so the
; user can answer the native box instead.
DecisionWordForKey(promptInfo, key) {
    twoOpt := promptInfo.HasOwnProp("options") && promptInfo.options.Length = 2
    return key = "1" ? "allow"
        : key = "2" ? (twoOpt ? "deny" : "always")
        : key = "3" ? "deny"
        : ""
}

SendHookDecision(promptInfo, key) {
    word := DecisionWordForKey(promptInfo, key)
    if word = "" {
        SoundPlay "*48"
        return false
    }
    return WriteHookDecision(promptInfo, word, false)
}

SendCodexNativeDecision(promptInfo, key, prevWin := 0) {
    if !(key = "1" || key = "2" || key = "3") {
        SoundPlay "*48"
        return false
    }
    if !promptInfo.HasOwnProp("pending_file") || promptInfo.pending_file = ""
        || !FileExist(promptInfo.pending_file) {
        ToolTip("Prompt expired — answer in the native popup")
        SetTimer(() => ToolTip(), -3000)
        SoundPlay "*48"
        return false
    }
    projectName := promptInfo.HasOwnProp("project_name") ? promptInfo.project_name : ""
    editorExe := promptInfo.HasOwnProp("editor_exe") ? promptInfo.editor_exe : ""
    ; Uniqueness guard (critical): the webview digit is NOT row-addressed — it
    ; lands in whichever approval is active in that window, while the pending we
    ; delete is the SELECTED row's. With 2+ live native prompts on the same
    ; target that can approve the wrong request → never send; surface the window
    ; (best-effort) and let the user answer inside Codex.
    if CountCodexPanelNativeTargets(projectName, editorExe) > 1 {
        multiHwnd := FindUniqueEditorByName(projectName, editorExe)
        if !multiHwnd || multiHwnd = -1
            multiHwnd := ResolveCodexPanelFallback(EditorWindowList())
        if multiHwnd
            ActivateHwnd(multiHwnd, true)
        ToolTip("Multiple Codex prompts here — answer in Codex")
        SetTimer(() => ToolTip(), -3500)
        return false
    }
    hwnd := FindUniqueEditorByName(projectName, editorExe)
    if hwnd = -1 {
        ToolTip("Multiple matching Codex windows — answer in the native popup")
        SetTimer(() => ToolTip(), -3500)
        SoundPlay "*48"
        return false
    }
    if !hwnd {
        ; Title resolution is structurally blind when the chat's cwd diverges
        ; from the window's workspace (live CX4 2026-07-03: panel chat on home
        ; cwd → project "Egor Sokolov" matched no window title). A single open
        ; editor window is the host by elimination — surface it, tell the user
        ; to answer inside Codex; the digit is never sent on this path.
        fb := ResolveCodexPanelFallback(EditorWindowList())
        if fb {
            ActivateHwnd(fb, true)
            ToolTip("Press 1/2/3 in Codex")
            SetTimer(() => ToolTip(), -3500)
            return false
        }
        ToolTip("Codex window not found for '" projectName "' — answer in the native popup")
        SetTimer(() => ToolTip(), -3500)
        SoundPlay "*48"
        return false
    }
    if !NativeControlWindowMatches(hwnd, prevWin) || !WinActive("ahk_id " hwnd) {
        ; Window resolved but not active at hotkey time (or focus slipped since):
        ; don't send — gently surface the window instead, so the second hotkey
        ; press (or a plain digit in the now-focused webview) answers it.
        ActivateHwnd(hwnd, true)
        ToolTip("Press the hotkey again or press 1/2/3 in Codex")
        SetTimer(() => ToolTip(), -3500)
        return false
    }
    try {
        Send(key)
    } catch {
        SoundPlay "*48"
        return false
    }
    ; Do NOT delete the pending here (live smoke CX4, 2026-07-02): the digit
    ; lands wherever the webview's INNER focus sits — with the approval card's
    ; inline feedback input focused it types a character instead of answering,
    ; and an optimistic delete kills the popup row while the native prompt still
    ; waits. Lifecycle ownership stays with teardown (approve → PostToolUse) and
    ; the TTL wait_until — exactly as if the user answered the native card by
    ; hand. A delivered digit thus clears the row within a couple of seconds; a
    ; missed one leaves the row alive for another try.
    return true
}

NativeControlWindowMatches(targetHwnd, prevWin) {
    return targetHwnd && prevWin && targetHwnd = prevWin
}

WriteHookDecision(promptInfo, word, quiet) {
    ; No declared decision channel = pre-v5.4 pending or non-decision host;
    ; nothing to write into — beep instead of silently doing nothing.
    if !promptInfo.HasOwnProp("decision_file") || promptInfo.decision_file = "" {
        if !quiet
            SoundPlay "*48"
        return false
    }
    ; The pending file lives exactly as long as the hook waits — gone means
    ; the prompt was already answered or the hook gave up (timeout/teardown).
    if promptInfo.HasOwnProp("pending_file") && promptInfo.pending_file != ""
        && !FileExist(promptInfo.pending_file) {
        if !quiet {
            ToolTip("Prompt expired — answer in the window")
            SetTimer(() => ToolTip(), -3000)
            SoundPlay "*48"
        }
        return false
    }
    ; Transition-race guard (hybrid phase 1→2): the hook may have rewritten this
    ; pending to native_control between the popup tick that built the row and
    ; this hotkey — the decision_file is no longer read by anyone. Re-read the
    ; live file; if it switched, refuse (the next hotkey rides the native path).
    if promptInfo.HasOwnProp("pending_file") && promptInfo.pending_file != "" {
        liveRaw := ""
        try liveRaw := FileRead(promptInfo.pending_file, "UTF-8")
        if RegExMatch(liveRaw, '"native_control"\s*:\s*true') {
            if !quiet {
                ToolTip("Prompt switched to Codex — press again")
                SetTimer(() => ToolTip(), -3000)
            }
            return false
        }
    }
    ; Atomic write (tmp + move) — the hook polls every 100ms and must never
    ; read a half-written word.
    tmpFile := promptInfo.decision_file ".tmp"
    try FileDelete(tmpFile)
    try {
        FileAppend(word, tmpFile)
        FileMove(tmpFile, promptInfo.decision_file, 1)
    } catch {
        if !quiet
            SoundPlay "*48"
        return false
    }
    return true
}

; Experimental Codex proxy channel (DESIGN-CODEX-PROXY §3): write the decision
; file the wrapper polls for. Digit → decision value: 1 = accept; 3 = cancel;
; 2 = the acceptWithExecpolicyAmendment object when offered, else cancel (the
; 2-option "Deny"). AHK has no JSON serializer, so the amendment array is echoed
; BYTE-EXACT from the pending's proposedExecpolicyAmendment (captured raw at parse
; time). Atomic (tmp + FileMove); refuses if the pending vanished (already
; resolved) — mirrors WriteHookDecision's guard.
WriteProxyDecision(promptInfo, key) {
    if !(key = "1" || key = "2" || key = "3") {
        SoundPlay "*48"
        return false
    }
    path := promptInfo.HasOwnProp("proxy_pending_path") ? promptInfo.proxy_pending_path : ""
    ; The pending lives exactly as long as the wrapper waits — gone means the
    ; request was already answered (by us or natively). Abort silently.
    if path = "" || !FileExist(path)
        return false
    offered := promptInfo.HasOwnProp("amendment_offered") && promptInfo.amendment_offered
    amendRaw := promptInfo.HasOwnProp("amendment_raw") ? promptInfo.amendment_raw : ""
    if key = "1"
        decision := '"accept"'
    else if key = "3"
        decision := '"cancel"'
    else {  ; key = "2": amendment when offered, else Deny (2-option box)
        decision := (offered && amendRaw != "")
            ? '{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":' amendRaw '}}'
            : '"cancel"'
    }
    json := '{"decision":' decision '}'
    ; <pid>-<requestId>.decision.json next to the pending (same PROXY_DIR).
    decFile := RegExReplace(path, "\.pending\.json$", ".decision.json")
    tmpFile := decFile ".tmp"
    try FileDelete(tmpFile)
    try {
        ; UTF-8 WITHOUT BOM — the wrapper's JSON.parse rejects a leading BOM, and
        ; the spliced amendment may carry non-ASCII path bytes.
        FileAppend(json, tmpFile, "UTF-8-RAW")
        FileMove(tmpFile, decFile, 1)
    } catch {
        SoundPlay "*48"
        return false
    }
    return true
}

FocusPrompt(promptInfo) {
    ; Proxy rows (codex-proxy channel): no focus routing — the native approval
    ; card lives in the Codex webview and stays answerable there. The Focus button
    ; (and this path) just dismiss the popup locally, like Esc. Cheapest existing
    ; "dismiss without answer" path: DismissByUser (proxy rows carry no
    ; decision_file, so no "pass" is written — it only hides + suppresses re-show).
    if promptInfo.HasOwnProp("host") && promptInfo.host = "codex-proxy" {
        PromptPopup.DismissByUser()
        return
    }
    ; Standalone hosts (scenario A pickers): focus the terminal window itself —
    ; FindVSCodeByName would never match a WT/conhost window.
    host := promptInfo.HasOwnProp("host") ? promptInfo.host : ""
    if host = "windows-terminal" || host = "conhost" {
        hwnd := ResolveStandaloneHwnd(promptInfo)
        if !hwnd {
            SoundPlay "*48"
            return
        }
        ActivateHwnd(hwnd)
        return
    }
    ; Editor focus (panel C, editor-terminal B pickers). Panels stay gentle — a
    ; single WinActivate, no Alt-dance — because the stronger path previously
    ; participated in a focus war across extension panes. Integrated terminals
    ; need the full path so a minimized editor is restored and foreground-lock
    ; refusal can be retried. The old Ctrl+Alt+F10 claude-vscode.focus chord is
    ; still intentionally absent; this only activates the editor window.
    ; Prefer the editor the hook captured (editor_exe) so a Cursor/Devin prompt
    ; focuses that editor, not a VS Code window sharing the project name.
    editorExe := promptInfo.HasOwnProp("editor_exe") ? promptInfo.editor_exe : ""
    FocusWorkspace(promptInfo.project_name, P1_EditorFocusGentle(host), editorExe,
        P1_EditorFocusCycleKey(promptInfo))
}

; Only extension panels require gentle activation. A vscode-terminal row is a
; real editor-window target, so it may safely use restore + foreground retry.
; Unknown editor-like hosts retain the conservative historical behavior.
P1_EditorFocusGentle(host) {
    return host != "vscode-terminal"
}

P1_EditorFocusCycleKey(promptInfo) {
    if promptInfo.HasOwnProp("prompt_id") && promptInfo.prompt_id != ""
        return promptInfo.prompt_id
    host := promptInfo.HasOwnProp("host") ? promptInfo.host : ""
    editorExe := promptInfo.HasOwnProp("editor_exe") ? promptInfo.editor_exe : ""
    projectName := promptInfo.HasOwnProp("project_name") ? promptInfo.project_name : ""
    return StrLower(host "|" editorExe "|" projectName)
}

FindVSCodeOnMonitor(monitorIndex) {
    ; Get sorted monitor list (by X position, left to right)
    monitorCount := MonitorGetCount()
    monitors := []
    Loop monitorCount {
        MonitorGetWorkArea(A_Index, &left, &top, &right, &bottom)
        monitors.Push({index: A_Index, left: left, right: right, top: top, bottom: bottom})
    }
    ; Sort by left X coordinate
    SortMonitors(monitors)

    if monitorIndex > monitors.Length || monitorIndex < 1
        return 0

    targetMon := monitors[monitorIndex]

    ; Find an editor window (VS Code / Cursor / Windsurf) whose center is on this monitor
    wins := EditorWindowList()

    for hwnd in wins {
        try {
            title := WinGetTitle(hwnd)
            if !IsEditorTitle(title)
                continue
            WinGetPos(&wx, &wy, &ww, &wh, hwnd)
            centerX := wx + ww // 2
            if centerX >= targetMon.left && centerX < targetMon.right
                return hwnd
        }
    }
    return 0
}

SortMonitors(monitors) {
    ; Simple bubble sort for small arrays (max 3-4 monitors)
    n := monitors.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if monitors[j].left > monitors[j + 1].left {
                tmp := monitors[j]
                monitors[j] := monitors[j + 1]
                monitors[j + 1] := tmp
            }
        }
    }
}

; ---- Read ALL active prompts (hook pending files) ----

ReadAllPrompts() {
    ; Every prompt now arrives as a hook pending file — the companion extension
    ; and its prompts-metadata are gone, so there is nothing to merge. Editor
    ; terminals (B), the panel (C), and standalone terminals (A) all ride the
    ; hook-decision channel. No phantom risk: S1 proved the hook fires only on
    ; real prompts. Cleanup of answered prompts is the session-teardown hook
    ; (v5.2); the filters below are belt-and-suspenders for crashed sessions.
    result := []

    global STANDALONE_BACKSTOP_MS, offCodexFlag
    nowMs := EpochMs()
    ; FIFO: ReadAllPending sorts newest-first (legacy LIFO consumers like
    ; ReadNewestPending), but popup rows queue oldest-first — [A] is the prompt
    ; that has waited longest, new arrivals join the bottom (until v5.2 panel
    ; rows were inconsistent and the first hotkey answered the NEWEST prompt).
    allPending := ReadAllPending()
    ; Merge the experimental Codex proxy pendings into the same stream so they
    ; sort by timestamp (FIFO) alongside hook rows and share the reconcile pass.
    ; Unlike hook rows, proxy rows are published by the wrapper, which does not
    ; read the global off-Codex flag. Enforce the master switch at presentation
    ; time without touching the wrapper-owned pending files: removing the flag
    ; makes the same still-live request visible and answerable again.
    if !FileExist(offCodexFlag) {
        for pe in ReadAllProxyPending()
            allPending.Push(pe)
    }
    SortEntriesByTimestamp(allPending)
    Loop allPending.Length {
        pi := allPending[allPending.Length - A_Index + 1]
        ; Orphaned beacon/decision pending: the hook stays alive exactly while its
        ; prompt is open — a decision-wait for permission (v5.4), a liveness beacon
        ; for picker (AskUserQuestion/ExitPlanMode, 2026-06-14) — and deletes its
        ; pending on graceful exit. So pending + dead hook = CC killed the hook when
        ; the user resolved the prompt in the UI. The win is the CANCEL path: it
        ; fires neither PostToolUse nor Stop, so teardown never comes — without this
        ; the row would sit out the full window. Permission rows still require a
        ; declared decision_file; pickers gate on kind, so a pre-beacon picker (hook
        ; long exited) also clears here instead of lingering on the backstop.
        ; Stale = hook gone OR its PID reused by a live process that started after
        ; this pending was written (Windows recycles PIDs — a dead hook's number
        ; resurfacing on svchost/node would otherwise mask a dead-session picker
        ; until the 60-min backstop). Start-time check closes that race (BACKLOG 14
        ; tail / dead-session picker).
        if pi.hook_pid && !pi.native_control && HookPidStale(pi.hook_pid, pi.timestamp)
            && (pi.decision_file != "" || pi.kind = "picker") {
            try FileDelete(pi.file_path)
            continue
        }
        ; Editor hosts: the panel (C) and editor integrated terminals (B, real
        ; VS Code + Cursor + Devin — all classified vscode-terminal). Identical
        ; lifecycle: permission rows ride the decision channel, pickers are
        ; attention-only. No window-death gate (the walk is off for these — the
        ; decision channel needs no window); the general hook_pid-staleness gate
        ; above is the orphan owner. editor_exe rides along so a picker focuses
        ; the RIGHT editor.
        if pi.host_type = "vscode-extension" || pi.host_type = "vscode-terminal" {
            if pi.kind = "permission" && (pi.decision_file != "" || pi.native_control) {
                ; The pending lives exactly as long as the hook waits for a
                ; decision (the hook deletes it on exit), so file presence ≈
                ; still answerable; wait_until is the cutoff for a crashed
                ; hook's orphan file.
                if pi.wait_until && nowMs > pi.wait_until + (pi.native_control ? 0 : 2000) {
                    if pi.native_control
                        try FileDelete(pi.file_path)
                    continue
                }
                result.Push({
                    project_name: pi.project_name,
                    agent: pi.agent,
                    workspace_path: "",
                    tool_name: pi.tool_name,
                    tool_input_short: pi.tool_input_short,
                    tool_input_full: pi.tool_input_full,
                    terminal_index: -1,
                    terminal_name: "",
                    prompt_id: pi.id,
                    decision_file: pi.decision_file,
                    pending_file: pi.file_path,
                    host: pi.host_type,
                    editor_exe: pi.editor_exe,
                    native_control: pi.native_control,
                    ; v5.2: render the box's REAL layout from the hook's options
                    ; hint — 2-option boxes ("1 Yes / 2 No") exist here too, and
                    ; showing 3 buttons would miscommunicate digit 2.
                    options: pi.options.Length > 0 ? pi.options : ["Allow", "Always allow", "Deny"],
                    kind: "permission",
                    detected_at: pi.timestamp,
                })
            } else if pi.kind != "" && pi.kind != "permission" {
                ; Attention-only row (picker / Codex needs-user): a hook decision
                ; can't answer these; user answers in the editor. Picker files
                ; retain their hook-owned lifecycle. Codex attention has no hook
                ; beacon, so a hard-killed terminal may skip SessionEnd; delete
                ; that orphan when the display backstop expires.
                if pi.timestamp && nowMs - pi.timestamp > STANDALONE_BACKSTOP_MS {
                    if pi.kind = "attention"
                        try FileDelete(pi.file_path)
                    continue
                }
                result.Push({
                    project_name: pi.project_name,
                    agent: pi.agent,
                    workspace_path: "",
                    tool_name: pi.tool_name,
                    tool_input_short: pi.tool_input_short,
                    tool_input_full: pi.tool_input_full,
                    terminal_index: -1,
                    terminal_name: "",
                    prompt_id: pi.id,
                    decision_file: "",
                    pending_file: pi.file_path,
                    host: pi.host_type,
                    editor_exe: pi.editor_exe,
                    options: [],
                    kind: pi.kind,
                    detected_at: pi.timestamp,
                })
            }
        } else if pi.host_type = "windows-terminal" || pi.host_type = "conhost" {
            ; Scenario A (v5.4): standalone terminal. Delivery = hook-decision
            ; channel (S10), same as the editor hosts; the host fields below only
            ; serve the focus helpers. Liveness gate stays the lifecycle
            ; owner: deleting a dead pending doubles as the waiting hook's
            ; early-exit signal.
            if pi.timestamp && nowMs - pi.timestamp > STANDALONE_BACKSTOP_MS {
                try FileDelete(pi.file_path)
                continue
            }
            if pi.hwnd || pi.top_level_pid {
                winAlive := pi.hwnd ? (WinExist("ahk_id " pi.hwnd) != 0) : false
                procAlive := pi.top_level_pid ? (ProcessExist(pi.top_level_pid) != 0) : false
                if !winAlive && !procAlive {
                    try FileDelete(pi.file_path)
                    continue
                }
            }
            ; Crashed-hook orphan (pending outliving its declared wait window
            ; while the terminal is still alive): hide the row — the hook is
            ; gone, a decision would answer nobody. Backstop above deletes.
            ; Native-control rows (phase 2 of the Codex hybrid) instead DELETE
            ; the file on expiry, mirroring the editor branch: their hook exited
            ; by design, nobody else owns the file, and hiding alone would keep
            ; it until the 90-min backstop.
            if pi.kind = "permission" && pi.wait_until
                && nowMs > pi.wait_until + (pi.native_control ? 0 : 2000) {
                if pi.native_control
                    try FileDelete(pi.file_path)
                continue
            }
            rowKind := pi.kind != "" ? pi.kind : "permission"
            ; Missing options hint (pre-v5.2 hook) → assume 3-option layout:
            ; its worst mismatch is Deny instead of Always allow (safe); the
            ; 2-option default could turn Deny into Always allow (never).
            opts := pi.options.Length > 0 ? pi.options : ["Allow", "Always allow", "Deny"]
            result.Push({
                project_name: pi.project_name,
                agent: pi.agent,
                workspace_path: "",
                tool_name: pi.tool_name,
                tool_input_short: pi.tool_input_short,
                tool_input_full: pi.tool_input_full,
                terminal_index: -1,
                terminal_name: "",
                prompt_id: pi.id,
                decision_file: pi.decision_file,
                pending_file: pi.file_path,
                host: pi.host_type,
                hwnd: pi.hwnd,
                top_level_pid: pi.top_level_pid,
                top_level_exe: pi.top_level_exe,
                ancestry_pids: pi.ancestry_pids,
                ; Phase-2 rows of the Codex hybrid (the hook rewrote the pending
                ; after its decision window): DispatchByKind routes them to the
                ; focus path instead of SendHookDecision. Lesson 128: this push
                ; has its own field set — keep it in sync with the editor push.
                native_control: pi.native_control,
                options: rowKind = "permission" ? opts : [],
                kind: rowKind,
                detected_at: pi.timestamp,
            })
        } else if pi.host_type = "codex-proxy" {
            ; Experimental Codex proxy channel: a popup row with NO picker, NO
            ; native_control, NO hook_pid/liveness, NO wait_until math — the
            ; wrapper polls indefinitely and deletes the pending on resolve, so the
            ; ONLY dismissal signals are file-gone (reconcile fades the card) or
            ; answered by us. Answering rides WriteProxyDecision via the channel
            ; branch in DispatchByKind; the row carries the raw amendment for the
            ; byte-exact "Always allow" splice.
            result.Push({
                project_name: pi.project_name,
                agent: pi.agent,
                channel: pi.channel,
                workspace_path: "",
                tool_name: pi.tool_name,
                tool_input_short: pi.tool_input_short,
                tool_input_full: pi.tool_input_full,
                terminal_index: -1,
                terminal_name: "",
                prompt_id: pi.id,
                decision_file: "",
                pending_file: pi.file_path,
                proxy_pending_path: pi.proxy_pending_path,
                amendment_offered: pi.amendment_offered,
                amendment_raw: pi.amendment_raw,
                host: pi.host_type,
                options: pi.options,
                kind: "permission",
                detected_at: pi.timestamp,
            })
        }
    }
    return result
}

EpochMs() {
    return DateDiff(A_NowUTC, "19700101000000", "Seconds") * 1000
}

; Process creation time as epoch ms, or 0 if it can't be read (no such process /
; access denied). Used to detect PID reuse: Windows recycles PIDs, so a dead
; hook's number can resurface on an unrelated live process.
ProcessStartMs(pid) {
    if !pid
        return 0
    ; PROCESS_QUERY_LIMITED_INFORMATION = 0x1000 (succeeds without full rights).
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return 0
    creation := Buffer(8, 0), exitT := Buffer(8, 0), kernelT := Buffer(8, 0), userT := Buffer(8, 0)
    ok := DllCall("GetProcessTimes", "Ptr", h, "Ptr", creation, "Ptr", exitT, "Ptr", kernelT, "Ptr", userT)
    DllCall("CloseHandle", "Ptr", h)
    if !ok
        return 0
    ; FILETIME = 100-ns ticks since 1601-01-01; Unix-epoch offset = 11644473600 s.
    ft := NumGet(creation, 0, "UInt64")
    return Integer((ft - 116444736000000000) // 10000)
}

; A pending's hook_pid is "stale" when the hook is gone OR a live process with
; that PID started AFTER the pending was written (PID reuse). Pure decision split
; out for offline testing; HookPidStale feeds it the live ProcessExist/start time.
PidStaleDecision(exists, startMs, pendingTimestamp) {
    if !exists
        return true
    if !pendingTimestamp
        return false        ; no timestamp to compare against → trust existence
    ; The hook writes its pending right after it starts, so its own creation time
    ; is <= pendingTimestamp. A live PID that started later (2s margin) is a
    ; different, reused process. startMs=0 (unreadable) → not stale (keep the row).
    return startMs && startMs > pendingTimestamp + 2000
}

HookPidStale(pid, pendingTimestamp) {
    return PidStaleDecision(ProcessExist(pid) != 0, ProcessStartMs(pid), pendingTimestamp)
}

ReadNewestPromptOrPending() {
    ; For instant-send (single prompt, no popup) — try extension metadata first,
    ; fall back to newest pending file (LIFO). Used only by SendToPrompt for legacy path.
    prompts := ReadAllPrompts()
    if prompts.Length > 0
        return prompts[1]

    ; Fallback: newest pending file (extension not running or didn't catch prompt)
    pending := ReadAllPending()
    if pending.Length > 0 {
        pi := pending[1]
        return {
            project_name: pi.project_name,
            tool_name: pi.tool_name,
            tool_input_short: pi.tool_input_short,
            tool_input_full: pi.tool_input_full,
            terminal_index: -1,
            terminal_name: "",
            options: [],
            kind: "permission",
            detected_at: 0,
        }
    }
    return ""
}

; JSON string unescape: \" \\ \/ \n \r \t \b \f \uXXXX
JsonUnescape(s) {
    s := StrReplace(s, '\\', Chr(1))        ; temp marker for literal backslash
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, '\/', '/')
    s := StrReplace(s, '\n', "`n")
    s := StrReplace(s, '\r', "`r")
    s := StrReplace(s, '\t', "`t")
    s := StrReplace(s, '\b', Chr(8))
    s := StrReplace(s, '\f', Chr(12))
    ; \uXXXX — after the \\ marker swap above, any remaining \u is a genuine
    ; escape (JSON.stringify encodes control chars this way). Surrogate pairs
    ; decode correctly: each Chr() emits one UTF-16 code unit.
    while RegExMatch(s, '\\u([0-9A-Fa-f]{4})', &um)
        s := StrReplace(s, um[0], Chr(Integer("0x" um[1])))
    s := StrReplace(s, Chr(1), '\')         ; restore literal backslash
    return s
}

; JSON-aware string-field regex: captures content including escaped chars
; Pattern: "key"\s*:\s*"((?:\\.|[^"\\])*)"
JsonStrPattern(key) {
    return '"' key '"\s*:\s*"((?:\\.|[^"\\])*)"'
}

ReadAllPending() {
    global PENDING_DIR
    result := []

    if !DirExist(PENDING_DIR)
        return result

    ; Collect all files with timestamps
    files := []
    Loop Files, PENDING_DIR "\*.json" {
        files.Push({path: A_LoopFileFullPath, time: A_LoopFileTimeCreated})
    }

    ; Sort by time descending (newest first)
    SortFilesByTime(files)

    for f in files {
        try {
            raw := FileRead(f.path, "UTF-8")
        } catch {
            continue
        }

        entry := {id: "", agent: "", project_name: "", tool_name: "", tool_input_short: "", tool_input_full: "", file_path: f.path,
            host_type: "", kind: "", decision_file: "", wait_until: 0, timestamp: 0,
            hook_pid: 0, hwnd: 0, top_level_pid: 0, top_level_exe: "", editor_exe: "",
            native_control: false, options: [], ancestry_pids: []}
        if RegExMatch(raw, JsonStrPattern("id"), &m)
            entry.id := JsonUnescape(m[1])
        ; agent (claude|codex) — top-level, parsed first-match; lets the popup
        ; badge the right tool. Claude pendings carry "claude", Codex "codex".
        if RegExMatch(raw, JsonStrPattern("agent"), &m)
            entry.agent := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("project_name"), &m)
            entry.project_name := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("tool_name"), &m)
            entry.tool_name := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("tool_input_short"), &m)
            entry.tool_input_short := JsonUnescape(m[1])
        ; Full command (newlines preserved) for the popup expand affordance.
        ; JsonUnescape turns the JSON "\n"/"\t" escapes back into real line breaks.
        if RegExMatch(raw, JsonStrPattern("tool_input_full"), &m)
            entry.tool_input_full := JsonUnescape(m[1])
        ; v3 panel fields (scenario C). host.type is nested — anchor the search
        ; at the "host" object so a literal "type" inside tool_input_short
        ; can't shadow it.
        if RegExMatch(raw, JsonStrPattern("kind"), &m)
            entry.kind := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("decision_file"), &m)
            entry.decision_file := JsonUnescape(m[1])
        if RegExMatch(raw, '"native_control"\s*:\s*true')
            entry.native_control := true
        if RegExMatch(raw, '"wait_until"\s*:\s*(\d+)', &m)
            entry.wait_until := Integer(m[1])
        if RegExMatch(raw, '"hook_pid"\s*:\s*(\d+)', &m)
            entry.hook_pid := Integer(m[1])
        if RegExMatch(raw, '"timestamp"\s*:\s*(\d+)', &m)
            entry.timestamp := Integer(m[1])
        ; v5.2: options layout hint from the hook (permission_suggestions
        ; presence ⇒ 3-option TUI). Escaped quotes inside tool_input_short
        ; can't false-match: \" breaks the "options" key pattern.
        if RegExMatch(raw, '"options"\s*:\s*\[([^\]]*)\]', &m) {
            optPos := 1
            while optPos := RegExMatch(m[1], '"((?:\\.|[^"\\])*)"', &om, optPos) {
                entry.options.Push(JsonUnescape(om[1]))
                optPos += StrLen(om[0])
            }
        }
        ; host.* fields are nested — anchor every search at the "host" object so
        ; literal key-lookalikes inside tool_input_short can't shadow them.
        hostPos := InStr(raw, '"host"')
        if hostPos {
            if RegExMatch(raw, JsonStrPattern("type"), &m, hostPos)
                entry.host_type := JsonUnescape(m[1])
            if RegExMatch(raw, '"top_level_pid"\s*:\s*(\d+)', &m, hostPos)
                entry.top_level_pid := Integer(m[1])
            if RegExMatch(raw, JsonStrPattern("top_level_exe"), &m, hostPos)
                entry.top_level_exe := JsonUnescape(m[1])
            ; editor_exe (Code.exe / Cursor.exe / Devin.exe) — focuses the right
            ; editor for a vscode-terminal picker. Anchored at "host" so a literal
            ; "editor_exe" inside tool_input_short can't shadow it.
            if RegExMatch(raw, JsonStrPattern("editor_exe"), &m, hostPos)
                entry.editor_exe := JsonUnescape(m[1])
            if RegExMatch(raw, '"hwnd"\s*:\s*(\d+)', &m, hostPos)
                entry.hwnd := Integer(m[1])
            ; Ancestry PIDs (bottom-up: node → … → top). Window resolution
            ; scans them: for conhost the console window is attributed to the
            ; CLIENT process (cmd.exe), not the top-level conhost.exe.
            ancPos := InStr(raw, '"ancestry"', , hostPos)
            if ancPos {
                tlPos := InStr(raw, '"top_level_pid"', , ancPos)
                if tlPos {
                    seg := SubStr(raw, ancPos, tlPos - ancPos)
                    pp := 1
                    while pp := RegExMatch(seg, '"pid"\s*:\s*(\d+)', &pm, pp) {
                        entry.ancestry_pids.Push(Integer(pm[1]))
                        pp += StrLen(pm[0])
                    }
                }
            }
        }

        if entry.project_name != ""
            result.Push(entry)
    }
    ; Re-sort by the hook-written "timestamp" (epoch ms), newest first. File
    ; creation time is NOT a stable key: the hybrid phase 1→2 rewrite recreates
    ; the pending (tmp+rename), which bumps file time and reshuffled the popup
    ; stack mid-life (live smoke 2026-07-02). The JSON timestamp survives the
    ; rewrite; the file-time pre-sort above stays as a stable tiebreaker.
    SortEntriesByTimestamp(result)
    return result
}

; Bubble (stable, mirrors SortFilesByTime) — newest first; entries without a
; timestamp (0) sink to the end, keeping their file-time relative order.
SortEntriesByTimestamp(entries) {
    n := entries.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if entries[j].timestamp < entries[j + 1].timestamp {
                tmp := entries[j]
                entries[j] := entries[j + 1]
                entries[j + 1] := tmp
            }
        }
    }
}

SortFilesByTime(files) {
    n := files.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if files[j].time < files[j + 1].time {
                tmp := files[j]
                files[j] := files[j + 1]
                files[j + 1] := tmp
            }
        }
    }
}

ReadNewestPending() {
    ; Backward compat — returns single newest pending
    all := ReadAllPending()
    if all.Length > 0
        return all[1]
    return {id: "", project_name: "", tool_name: "", tool_input_short: "", file_path: ""}
}

; ---- Experimental Codex proxy channel (DESIGN-CODEX-PROXY §3) ----
;
; Basename of a cwd (last path segment, either separator) — the proxy pending has
; no project_name, so it's derived here. RTrim strips a trailing slash first so
; "D:\work\proj\" still yields "proj". Empty in → empty out (the caller drops the
; row: project_name is a hard requirement).
ProxyBasename(cwd) {
    p := RTrim(cwd, "\/")
    if p = ""
        return ""
    return RegExReplace(p, "^.*[\\/]", "")
}

; Extract the raw JSON array text (INCLUDING its brackets) beginning at/after
; startPos, respecting JSON string quoting so a "]" inside a token can't end it
; early. Returns the byte-exact substring (never JsonUnescape'd — it is spliced
; back into the decision file verbatim). "" when no balanced array is found.
JsonRawArrayAt(raw, startPos) {
    br := InStr(raw, "[", , startPos)
    if !br
        return ""
    ; NB: the "in a string" flag must NOT be named `inStr` — AHK identifiers are
    ; case-insensitive, so it would shadow the built-in InStr() called just above.
    depth := 0, inQuote := false, esc := false
    len := StrLen(raw), i := br
    while i <= len {
        ch := SubStr(raw, i, 1)
        if inQuote {
            if esc
                esc := false
            else if ch = "\"
                esc := true
            else if ch = '"'
                inQuote := false
        } else if ch = '"'
            inQuote := true
        else if ch = "["
            depth++
        else if ch = "]" {
            depth--
            if depth = 0
                return SubStr(raw, br, i - br + 1)
        }
        i++
    }
    return ""
}

; Read the proxy wrapper's pendings and adapt each to a ReadAllPending-shaped
; entry (host_type "codex-proxy", channel "proxy"). Deliberately NOT routed
; through the schema-v2 regex block above — the proxy schema is disjoint. Fully
; defensive: a torn/partial file (wrapper write is being made atomic in parallel,
; but stay safe) is skipped, and a row without a derivable project_name (missing
; cwd) is dropped.
ReadAllProxyPending() {
    global PROXY_DIR
    result := []
    if !DirExist(PROXY_DIR)
        return result

    Loop Files, PROXY_DIR "\*.json" {
        ; Only *.pending.json — ignore decision files and their .tmp siblings.
        if !RegExMatch(A_LoopFileName, "\.pending\.json$")
            continue
        path := A_LoopFileFullPath
        try
            raw := FileRead(path, "UTF-8")
        catch
            continue

        pid := "", req := ""
        if RegExMatch(raw, '"pid"\s*:\s*(\d+)', &m)
            pid := m[1]
        if RegExMatch(raw, '"requestId"\s*:\s*(\d+)', &m)
            req := m[1]
        cwd := ""
        if RegExMatch(raw, JsonStrPattern("cwd"), &m)
            cwd := JsonUnescape(m[1])
        proj := ProxyBasename(cwd)
        ; Hard requirements: an addressable (pid, requestId) pair and a non-empty
        ; project_name. A file missing any of these is torn or malformed — skip it.
        if pid = "" || req = "" || proj = ""
            continue

        command := ""
        if RegExMatch(raw, JsonStrPattern("command"), &m)
            command := JsonUnescape(m[1])
        reason := ""
        if RegExMatch(raw, JsonStrPattern("reason"), &m)
            reason := JsonUnescape(m[1])
        ts := 0
        if RegExMatch(raw, '"ts"\s*:\s*(\d+)', &m)
            ts := Integer(m[1])

        ; Amendment ("Always allow"): offered only when availableDecisions carries
        ; the acceptWithExecpolicyAmendment option (that key appears nowhere else in
        ; the schema). Its raw array is captured byte-exact from the top-level
        ; proposedExecpolicyAmendment for verbatim splice into the decision.
        amendRaw := ""
        pPos := RegExMatch(raw, '"proposedExecpolicyAmendment"\s*:')
        if pPos
            amendRaw := JsonRawArrayAt(raw, pPos)
        offered := RegExMatch(raw, '"acceptWithExecpolicyAmendment"') && amendRaw != ""
        ; Buttons mirror the box: 3 with the amendment, else Allow/Deny (digit 2 =
        ; Deny — the same 2-option semantics the hook channel uses).
        options := offered ? ["Allow", "Always allow", "Deny"] : ["Allow", "Deny"]

        ; Subtitle has no separate slot on the card — lead with the human reason,
        ; then the command (em dash); keep the bare command for expand (full).
        short := reason != "" ? reason " " Chr(0x2014) " " command : command

        result.Push({
            id: pid "-" req,
            agent: "codex",
            channel: "proxy",
            project_name: proj,
            tool_name: "exec",
            tool_input_short: short,
            tool_input_full: command,
            file_path: path,
            proxy_pending_path: path,
            host_type: "codex-proxy",
            kind: "permission",
            decision_file: "",
            wait_until: 0,
            timestamp: ts,
            hook_pid: 0,
            hwnd: 0, top_level_pid: 0, top_level_exe: "", editor_exe: "",
            native_control: false,
            options: options,
            ancestry_pids: [],
            amendment_offered: offered ? true : false,
            amendment_raw: amendRaw})
    }
    return result
}

; ---- Find VS Code window by project name (fuzzy: hyphens ↔ spaces) ----

BuildNameVariants(projectName) {
    variants := [projectName]
    v1 := StrReplace(projectName, "-", " ")
    if v1 != projectName
        variants.Push(v1)
    v2 := StrReplace(projectName, " ", "-")
    if v2 != projectName
        variants.Push(v2)
    return variants
}

; VS Code and its forks (Cursor, Windsurf/Devin) are all Electron/VS Code-based
; and host Claude Code terminals and panels identically, so window-matching
; treats them as one family. Used for FOCUS / per-monitor targeting only — never
; for answer routing (every host delivers through the hook-decision channel; a
; wrong window here is a benign miss, not a misroute). Windsurf's window process
; is Devin.exe after its rebrand; Windsurf.exe is kept for older builds.
EditorWindowList() {
    out := []
    for exe in ["Code.exe", "Cursor.exe", "Windsurf.exe", "Devin.exe"] {
        try {
            for hwnd in WinGetList("ahk_exe " exe)
                out.Push(hwnd)
        }
    }
    return out
}

IsEditorTitle(title) {
    for name in ["Visual Studio Code", "Cursor", "Windsurf", "Devin"]
        if InStr(title, name)
            return true
    return false
}

; Focus-only fallback for editor terminals whose cwd basename is not the VS Code
; workspace title (for example a GSD worktree opened inside an integrated
; terminal). A captured editor exe with exactly one window is unambiguous. If
; that exe has no windows, one editor window overall is the final safe fallback.
; Two or more candidates always fail closed; no digit is sent on this route.
ResolveEditorFocusCandidates(preferredMatches, preferredWins, allMatches, allWins) {
    if preferredMatches.Length > 0
        return preferredMatches
    if preferredWins.Length > 0
        return preferredWins.Length = 1 ? [preferredWins[1]] : []
    if allMatches.Length > 0
        return allMatches
    return allWins.Length = 1 ? [allWins[1]] : []
}

ResolveEditorFocusFallback(preferredWins, allWins) {
    candidates := ResolveEditorFocusCandidates([], preferredWins, [], allWins)
    return candidates.Length = 1 ? candidates[1] : 0
}

; Find an editor window for a workspace by title (fuzzy: hyphens ↔ spaces).
; Prefers a specific editor exe (Code.exe / Cursor.exe / Devin.exe) when the hook
; captured one in editor_exe — so a Cursor/Devin prompt focuses that editor, not
; a VS Code window that happens to share the project name. If the project title
; does not match, a unique window of that exe is still safe to focus. Duplicate
; title matches are intentionally preserved so FocusWorkspace can cycle them.
FindEditorCandidates(projectName, editorExe := "") {
    variants := BuildNameVariants(projectName)
    preferredWins := []
    preferredMatches := []
    if editorExe != "" {
        try {
            for hwnd in WinGetList("ahk_exe " editorExe) {
                preferredWins.Push(hwnd)
                if EditorWindowMatchesVariants(hwnd, variants, false)
                    preferredMatches.Push(hwnd)
            }
        }
        if preferredMatches.Length > 0 || preferredWins.Length > 0
            return ResolveEditorFocusCandidates(preferredMatches, preferredWins, [], [])
    }
    allWins := EditorWindowList()
    allMatches := []
    for hwnd in allWins
        if EditorWindowMatchesVariants(hwnd, variants, true)
            allMatches.Push(hwnd)
    return ResolveEditorFocusCandidates([], [], allMatches, allWins)
}

; Stable numeric ordering is independent of WinGetList's z-order. Activation
; moves a window to the front, so cycling raw enumeration order can bounce
; between two candidates forever and never reach a third.
P1_SortedHwnds(candidates) {
    sorted := []
    for hwnd in candidates
        sorted.Push(hwnd)
    n := sorted.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if sorted[j] > sorted[j + 1] {
                tmp := sorted[j]
                sorted[j] := sorted[j + 1]
                sorted[j + 1] := tmp
            }
        }
    }
    return sorted
}

P1_SelectEditorFocusCandidate(candidates, cycleKey, states?) {
    global P1_EDITOR_FOCUS_CYCLES
    if candidates.Length = 0
        return {hwnd:0, index:0, total:0}
    if !IsSet(states)
        states := P1_EDITOR_FOCUS_CYCLES
    sorted := P1_SortedHwnds(candidates)
    signature := ""
    for hwnd in sorted
        signature .= (signature = "" ? "" : ",") hwnd
    index := 1
    if states.Has(cycleKey) && states[cycleKey].signature = signature
        index := Mod(states[cycleKey].index, sorted.Length) + 1
    if !states.Has(cycleKey) && states.Count >= 64
        states.Clear()
    states[cycleKey] := {signature:signature, index:index}
    return {hwnd:sorted[index], index:index, total:sorted.Length}
}

FindUniqueEditorByName(projectName, editorExe := "") {
    if projectName = ""
        return 0
    variants := BuildNameVariants(projectName)
    if editorExe != "" {
        matches := []
        try {
            for hwnd in WinGetList("ahk_exe " editorExe) {
                if EditorWindowMatchesVariants(hwnd, variants, false)
                    matches.Push(hwnd)
            }
        }
        if matches.Length = 1
            return matches[1]
        if matches.Length > 1
            return -1
    }

    matches := []
    for hwnd in EditorWindowList() {
        if EditorWindowMatchesVariants(hwnd, variants, true)
            matches.Push(hwnd)
    }
    if matches.Length = 1
        return matches[1]
    return matches.Length > 1 ? -1 : 0
}

EditorWindowMatchesVariants(hwnd, variants, requireEditorTitle := true) {
    title := ""
    try title := WinGetTitle(hwnd)
    if requireEditorTitle && !IsEditorTitle(title)
        return false
    for variant in variants {
        if InStr(title, variant)
            return true
    }
    return false
}

; Bring the editor window for a workspace to the foreground. Used for non-
; permission prompt kinds (picker / search / text / unknown) where the user
; answers directly in the TUI — the popup's job is to surface attention, and
; hitting the hotkey delivers them into the right window. editorExe, when known
; (vscode-terminal pickers), picks the exact editor among the forks.
;
; Windows 11 blocks SetForegroundWindow from non-foreground apps (focus-steal
; prevention). AHK's WinActivate tries to work around this but often fails
; when the hotkey comes from a background script. Standard workaround: briefly
; tap Alt to reset the foreground lock, then call WinActivate twice (first
; restores the z-order, second actually takes focus on stubborn windows).
FocusWorkspace(projectName, gentle := false, editorExe := "", cycleKey := "") {
    candidates := FindEditorCandidates(projectName, editorExe)
    if candidates.Length = 0 {
        SoundPlay "*48"
        return false
    }
    if cycleKey = ""
        cycleKey := StrLower(editorExe "|" projectName)
    choice := P1_SelectEditorFocusCandidate(candidates, cycleKey)
    originalMonitor := P1_MonitorForWindow(choice.hwnd)
    ActivateHwnd(choice.hwnd, gentle)
    P1_SignalFocusedWindow(choice.hwnd, originalMonitor)
    if choice.total > 1 {
        ToolTip("Window " choice.index "/" choice.total " — click Focus again")
        SetTimer(() => ToolTip(), -3000)
    }
    return choice
}

; Non-invasive focus confirmation. FlashWindowEx asks Windows to flash the
; caption/taskbar button; the temporary click-through outline remains visible
; even with VS Code's custom titlebar. We never move the target window, so
; maximized state and Windows snap layouts remain intact.
P1_SignalFocusedWindow(hwnd, originalMonitor := 0) {
    size := A_PtrSize = 8 ? 32 : 20
    hwndOffset := A_PtrSize = 8 ? 8 : 4
    flagsOffset := A_PtrSize = 8 ? 16 : 8
    info := Buffer(size, 0)
    NumPut("UInt", size, info, 0)
    NumPut("Ptr", hwnd, info, hwndOffset)
    NumPut("UInt", 3, info, flagsOffset)       ; FLASHW_ALL
    NumPut("UInt", 2, info, flagsOffset + 4)  ; two flashes
    NumPut("UInt", 0, info, flagsOffset + 8)  ; system cursor blink rate
    try DllCall("User32\FlashWindowEx", "Ptr", info)
    SetTimer(P1_PulseWindowOutline.Bind(hwnd, originalMonitor), -60)
}

P1_FocusOutlineRects(x, y, w, h, thickness) {
    innerH := Max(0, h - 2 * thickness)
    return [
        {x:x, y:y, w:w, h:thickness},
        {x:x, y:y + h - thickness, w:w, h:thickness},
        {x:x, y:y + thickness, w:thickness, h:innerH},
        {x:x + w - thickness, y:y + thickness, w:thickness, h:innerH}
    ]
}

P1_IntersectFocusRect(rect, bounds) {
    left := Max(rect.x, bounds.x)
    top := Max(rect.y, bounds.y)
    right := Min(rect.x + rect.w, bounds.x + bounds.w)
    bottom := Min(rect.y + rect.h, bounds.y + bounds.h)
    if right <= left || bottom <= top
        return false
    return {x:left, y:top, w:right - left, h:bottom - top}
}

P1_MonitorForWindow(hwnd) {
    try return DllCall("User32\MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    return 0
}

P1_MonitorBounds(hwnd, workArea := false) {
    monitor := P1_MonitorForWindow(hwnd)
    if !monitor
        return false
    info := Buffer(40, 0) ; MONITORINFO
    NumPut("UInt", info.Size, info, 0)
    try ok := DllCall("User32\GetMonitorInfoW", "Ptr", monitor, "Ptr", info, "Int")
    catch
        return false
    if !ok
        return false
    offset := workArea ? 20 : 4
    left := NumGet(info, offset, "Int")
    top := NumGet(info, offset + 4, "Int")
    right := NumGet(info, offset + 8, "Int")
    bottom := NumGet(info, offset + 12, "Int")
    return {x:left, y:top, w:right - left, h:bottom - top}
}

; DWM's extended frame is the visible border. WinGetPos/GetWindowRect includes
; Electron's invisible resize margins, which puts every strip off-screen for a
; maximized window on a monitor edge. The fallback is clipped to the target
; monitor (work area when maximized) for the same reason.
P1_VisibleWindowRect(hwnd) {
    rectBuffer := Buffer(16, 0)
    try hr := DllCall("Dwmapi\DwmGetWindowAttribute",
        "Ptr", hwnd, "UInt", 9, "Ptr", rectBuffer, "UInt", rectBuffer.Size, "Int")
    catch
        hr := -1
    if hr != 0 {
        try ok := DllCall("User32\GetWindowRect", "Ptr", hwnd, "Ptr", rectBuffer, "Int")
        catch
            return false
        if !ok
            return false
    }
    left := NumGet(rectBuffer, 0, "Int")
    top := NumGet(rectBuffer, 4, "Int")
    right := NumGet(rectBuffer, 8, "Int")
    bottom := NumGet(rectBuffer, 12, "Int")
    if right <= left || bottom <= top
        return false
    rect := {x:left, y:top, w:right - left, h:bottom - top}
    try maximized := WinGetMinMax("ahk_id " hwnd) = 1
    catch
        maximized := false
    bounds := P1_MonitorBounds(hwnd, maximized)
    return bounds ? P1_IntersectFocusRect(rect, bounds) : rect
}

P1_WindowDpi(hwnd) {
    try {
        dpi := DllCall("User32\GetDpiForWindow", "Ptr", hwnd, "UInt")
        if dpi > 0
            return dpi
    }
    return A_ScreenDPI
}

P1_SetFocusMonitorDiagnostic(originalMonitor, finalMonitor) {
    global P1_LAST_FOCUS_DIAGNOSTIC
    if !originalMonitor || !finalMonitor {
        P1_LAST_FOCUS_DIAGNOSTIC := "Last focus monitor: unavailable"
        return
    }
    P1_LAST_FOCUS_DIAGNOSTIC := originalMonitor = finalMonitor
        ? "Last focus monitor: stable"
        : "Last focus monitor: CHANGED"
}

; Restore and Electron/DWM geometry settle asynchronously. Require two equal
; visible rectangles before drawing; while minimized, retry for up to ~1.5 s.
P1_PulseWindowOutline(hwnd, originalMonitor := 0, attempt := 0, priorSignature := "", *) {
    if !WinExist("ahk_id " hwnd)
        return
    try {
        if WinGetMinMax("ahk_id " hwnd) = -1 {
            if attempt < 20
                SetTimer(P1_PulseWindowOutline.Bind(hwnd, originalMonitor, attempt + 1), -75)
            return
        }
    } catch {
        return
    }

    oldDpiContext := 0
    try oldDpiContext := DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    overlays := []
    try {
        try rect := P1_VisibleWindowRect(hwnd)
        catch
            rect := false
        if !rect {
            if attempt < 20
                SetTimer(P1_PulseWindowOutline.Bind(hwnd, originalMonitor, attempt + 1), -75)
            return
        }

        signature := rect.x "," rect.y "," rect.w "," rect.h
        if attempt < 20 && signature != priorSignature {
            SetTimer(P1_PulseWindowOutline.Bind(hwnd, originalMonitor, attempt + 1, signature), -50)
            return
        }

        P1_SetFocusMonitorDiagnostic(originalMonitor, P1_MonitorForWindow(hwnd))
        thickness := Max(4, Round(5 * P1_WindowDpi(hwnd) / 96))
        if rect.w < 2 * thickness || rect.h < 2 * thickness
            return
        for strip in P1_FocusOutlineRects(rect.x, rect.y, rect.w, rect.h, thickness) {
            if strip.w <= 0 || strip.h <= 0
                continue
            g := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x20 +E0x08000000 -DPIScale")
            g.BackColor := "E11B76"
            g.Show("NA x" strip.x " y" strip.y " w" strip.w " h" strip.h)
            overlays.Push(g)
        }
    } finally {
        if oldDpiContext
            try DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldDpiContext, "Ptr")
    }
    if overlays.Length > 0
        SetTimer(P1_DestroyFocusOutline.Bind(overlays), -900)
}

P1_DestroyFocusOutline(overlays, *) {
    for g in overlays
        try g.Destroy()
}

; Foreground-lock dance, shared by every focus path (VS Code windows and
; standalone terminals alike).
ActivateHwnd(hwnd, gentle := false) {
    ; If minimized, restore it first — WinActivate won't un-minimize reliably.
    try {
        if WinGetMinMax("ahk_id " hwnd) = -1
            WinRestore("ahk_id " hwnd)
    }
    ; Fast path (BACKLOG 5): a bare WinActivate succeeds whenever Windows is
    ; willing to hand focus over (often the case) — paying the Alt-tap dance
    ; unconditionally made "Focus panel" feel laggy. Dance only on refusal.
    try WinActivate("ahk_id " hwnd)
    if WinWaitActive("ahk_id " hwnd, , 0.1)
        return
    ; Gentle path (B14): panel focus must NOT escalate. With many VS Code windows
    ; open, the synthetic-Alt + double-activate dance below feeds a focus war
    ; between extension panes. For panel callers, stop at one WinActivate and hint.
    if gentle {
        ToolTip("Couldn't focus — click the window")
        SetTimer(() => ToolTip(), -3000)
        return
    }
    ; Foreground-lock bypass: synthetic Alt keypress convinces Windows that
    ; "user input happened", allowing the next SetForegroundWindow to succeed.
    try Send("{Alt down}{Alt up}")
    try WinActivate("ahk_id " hwnd)
    try WinActivate("ahk_id " hwnd)  ; second pass — some windows need it
}

; ==============================================================================
; POPUP GUI — Visual prompt selector
; ==============================================================================

; ==============================================================================
; GDI+ popup renderer (BACKLOG 11) — file-scope drawing helpers
; Ported from design-proto\popup-proto.ahk. Pure drawing; no protocol/routing.
; The popup's only renderer. Layered NoActivate windows — never steal focus.
; ==============================================================================

P1_Smooth(t) => t * t * (3 - 2 * t)

P1_Present(card, x, y, alpha) {
    ; Coordinates and DIB dimensions are physical pixels. The resident process is
    ; otherwise system-DPI-aware, so scope every layered present to Per-Monitor-V2
    ; or Windows virtualizes side-monitor coordinates after a mixed-DPI change.
    oldCtx := 0
    try oldCtx := DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    try UpdateLayeredWindow(card.hwnd, card.hdc, Round(x), Round(y), card.w, card.h, alpha)
    finally {
        if oldCtx
            try DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldCtx, "Ptr")
    }
}

; Display-text badge for the answer toast / Focus label. Pure presentation —
; never gates routing (delivery is agent-agnostic). Claude: panel/WT/console
; (vscode-terminal shows none — basename is the project). Codex: codex·panel /
; codex·term / codex·WT / codex·console (a Codex prompt is always tagged so it
; reads distinct from a Claude one in the toast).
P1_HostBadge(agent, host) {
    base := host = "windows-terminal" ? "WT"
        : host = "conhost" ? "console"
        : host = "vscode-extension" ? "panel"
        : host = "vscode-terminal" ? "term"
        : host = "codex-proxy" ? "proxy" : ""
    if base = ""
        return ""
    if agent = "codex"
        return "codex·" base
    return host = "vscode-terminal" ? "" : base    ; Claude editor terminal: no badge
}

; Agent identity for the leading card pill — symmetric across both agents
; (placement B, D1: agent only, host lives in the answer toast). Title-case label;
; empty for a blank/unknown agent so no pill is drawn. Pure → harness-testable.
P1_AgentLabel(agent) {
    if agent = "claude"
        return "Claude"
    if agent = "codex"
        return "Codex"
    return ""
}

; Tray "Active for" checkmark mapping — INVERSE of mute: checked (= agent enabled)
; ⇔ NO off-flag present. Pure so the harness can pin the inverse semantics.
P1_AgentChecked(flagExists) => !flagExists

; ---- Popup display selection + per-monitor DPI --------------------------------

P1_CleanDisplayLabel(label) {
    label := StrReplace(label, "`t", " ")
    label := StrReplace(label, "`r", " ")
    label := StrReplace(label, "`n", " ")
    while InStr(label, "  ")
        label := StrReplace(label, "  ", " ")
    return Trim(label)
}

; Tiny line protocol: absent/invalid/empty = dynamic Windows primary. A last-known
; label is persisted only so an unplugged selected display remains understandable
; in the tray; routing uses id alone.
P1_ParsePopupDisplayPrefs(raw) {
    raw := StrReplace(raw, "`r")
    lines := StrSplit(raw, "`n")
    if lines.Length = 0 || Trim(lines[1]) != "v1"
        return []
    result := [], positions := Map()
    Loop lines.Length - 1 {
        line := lines[A_Index + 1]
        if line = ""
            continue
        tab := InStr(line, "`t")
        id := Trim(tab ? SubStr(line, 1, tab - 1) : line)
        label := P1_CleanDisplayLabel(tab ? SubStr(line, tab + 1) : "")
        if id = "" || InStr(id, "`t") || InStr(id, "`n")
            continue
        item := {id:id, label:label}
        if positions.Has(id)
            result[positions[id]] := item
        else {
            positions[id] := result.Length + 1
            result.Push(item)
        }
    }
    return result
}

P1_SerializePopupDisplayPrefs(items) {
    out := "v1`n", seen := Map()
    for item in items {
        id := Trim(item.id)
        if id = "" || seen.Has(id)
            continue
        seen[id] := true
        out .= id "`t" P1_CleanDisplayLabel(item.HasOwnProp("label") ? item.label : "") "`n"
    }
    return out
}

P1_ReadPopupDisplayPrefs(path) {
    if path = "" || !FileExist(path)
        return []
    try return P1_ParsePopupDisplayPrefs(FileRead(path, "UTF-8"))
    catch
        return []
}

P1_WritePopupDisplayPrefs(path, items) {
    if items.Length = 0 {
        try FileDelete(path)
        return true
    }
    tmp := path ".tmp"
    try FileDelete(tmp)
    try {
        FileAppend(P1_SerializePopupDisplayPrefs(items), tmp, "UTF-8-RAW")
        FileMove(tmp, path, 1)
        return true
    } catch {
        try FileDelete(tmp)
        return false
    }
}

; DISPLAY_DEVICEW: cb(4), DeviceName[32], DeviceString[128], StateFlags(4),
; DeviceID[128], DeviceKey[128] = 840 bytes. Enumerating child 0 of the display
; source yields the physical monitor's PnP id (normally includes its EDID serial)
; and friendly model string. This survives AHK/Windows monitor renumbering.
P1_MonitorDevice(sourceName) {
    dd := Buffer(840, 0), NumPut("UInt", 840, dd, 0)
    ok := false
    try ok := DllCall("User32\EnumDisplayDevicesW", "WStr", sourceName, "UInt", 0,
        "Ptr", dd.Ptr, "UInt", 0, "Int")
    if !ok
        return {id:StrLower(sourceName), name:sourceName}
    name := StrGet(dd.Ptr + 68, 128, "UTF-16")
    id := StrGet(dd.Ptr + 328, 128, "UTF-16")
    if id = ""
        id := sourceName
    if name = ""
        name := sourceName
    return {id:StrLower(id), name:name}
}

P1_DpiForMonitor(left, top, right, bottom) {
    x := left + Max(0, (right - left) // 2)
    y := top + Max(0, (bottom - top) // 2)
    pt := Buffer(8, 0), NumPut("Int", x, pt, 0), NumPut("Int", y, pt, 4)
    hmon := DllCall("User32\MonitorFromPoint", "Int64", NumGet(pt, 0, "Int64"), "UInt", 2, "Ptr")
    if hmon {
        dx := 0, dy := 0
        try {
            if DllCall("Shcore\GetDpiForMonitor", "Ptr", hmon, "Int", 0,
                "UInt*", &dx, "UInt*", &dy, "Int") = 0 && dx > 0
                return dx
        }
    }
    return A_ScreenDPI > 0 ? A_ScreenDPI : 96
}

P1_GetDisplayCatalog() {
    oldCtx := 0
    try oldCtx := DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    result := []
    try {
        primary := MonitorGetPrimary()
        Loop MonitorGetCount() {
            idx := A_Index
            MonitorGet(idx, &l, &t, &r, &b)
            MonitorGetWorkArea(idx, &wl, &wt, &wr, &wb)
            source := MonitorGetName(idx)
            dev := P1_MonitorDevice(source)
            result.Push({id:dev.id, index:idx, source:source, name:dev.name,
                primary:idx = primary, left:l, top:t, right:r, bottom:b,
                workLeft:wl, workTop:wt, workRight:wr, workBottom:wb,
                dpi:P1_DpiForMonitor(l, t, r, b)})
        }
    } finally {
        if oldCtx
            try DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldCtx, "Ptr")
    }
    ; Stable visual order for menu and cloned stacks: left-to-right, then top.
    Loop result.Length - 1 {
        i := A_Index
        Loop result.Length - i {
            j := A_Index
            a := result[j], b := result[j + 1]
            if a.left > b.left || (a.left = b.left && a.top > b.top) {
                result[j] := b, result[j + 1] := a
            }
        }
    }
    ; Broken/generic EDID can duplicate ids. Keep runtime identities unique and
    ; fail conservatively to the source name for only those ambiguous devices.
    counts := Map()
    for d in result
        counts[d.id] := counts.Has(d.id) ? counts[d.id] + 1 : 1
    for d in result
        if counts[d.id] > 1
            d.id .= "|" StrLower(d.source)
    return result
}

P1_ResolvePopupTargets(catalog, prefs) {
    targets := []
    if prefs.Length > 0 {
        wanted := Map()
        for p in prefs
            wanted[p.id] := true
        for d in catalog
            if wanted.Has(d.id)
                targets.Push(d)
        if targets.Length > 0
            return targets
    }
    for d in catalog
        if d.primary {
            targets.Push(d)
            return targets
        }
    if catalog.Length > 0
        targets.Push(catalog[1])
    return targets
}

P1_PopupScale(dpi, workWidth) {
    dpiScale := Max(0.5, dpi / 96.0)
    ; Base window is 640 DIP; leave an 8-DIP safety margin on both sides. Only a
    ; genuinely narrow work area shrinks it — resolution alone never enlarges it.
    fitScale := Max(0.35, (workWidth - Round(16 * dpiScale)) / 640.0)
    return Min(dpiScale, fitScale)
}

P1_CardInstanceKey(promptKey, displayKey) => displayKey "`n" promptKey

P1_DisplayLabel(display, ordinal := 0) {
    prefix := ordinal > 0 ? ordinal " · " : ""
    w := display.right - display.left, h := display.bottom - display.top
    pct := Round(display.dpi * 100 / 96)
    return prefix display.name " · " w "×" h " · " pct "%" (display.primary ? " · Primary" : "")
}

; Safe one-line diagnostic for the hook's sanitized reviewer-status sidecar.
; The rollout parser is version-sensitive, so malformed/old/unknown data must
; disappear rather than leak arbitrary transcript strings into DebugPending.
; Only fixed enum values and a non-negative integer duration are ever rendered.
P1_CodexReviewerStatusSummary(path, nowMs) {
    if path = "" || !FileExist(path)
        return ""
    raw := ""
    try raw := FileRead(path, "UTF-8")
    catch
        return ""
    raw := Trim(raw)
    if SubStr(raw, 1, 1) != "{" || SubStr(raw, -1) != "}"
        return ""

    ; Validate exactly what gets rendered (plus schema version and freshness);
    ; the enum whitelists below are what keeps arbitrary strings out of the tip.
    if !RegExMatch(raw, '"schema"\s*:\s*1(?:\s*[,}])')
        return ""
    if !RegExMatch(raw, '"ts"\s*:\s*(\d+)', &m)
        return ""
    ts := Integer(m[1])
    ageMs := nowMs - ts
    ; EpochMs() is second-granular while the hook writes JS Date.now(). A fresh
    ; status from the same second can therefore appear up to 999 ms in the
    ; future. Accept only that precision window; larger clock leads stay invalid.
    if ageMs < -999 || ageMs > 600000
        return ""
    if !RegExMatch(raw, JsonStrPattern("outcome"), &m)
        return ""
    outcome := JsonUnescape(m[1])
    if !RegExMatch(raw, JsonStrPattern("reason"), &m)
        return ""
    reason := JsonUnescape(m[1])
    if !RegExMatch(raw, '"elapsed_ms"\s*:\s*(\d+)', &m)
        return ""
    elapsedMs := Integer(m[1])

    if outcome = "auto_pass" {
        if reason != "exact_auto_review"
            return ""
    } else if outcome = "popup" {
        static popupReasons := Map(
            "reviewer_user", true,
            "reviewer_other", true,
            "input_missing", true,
            "path_rejected", true,
            "read_failed", true,
            "turn_not_found", true,
            "record_invalid", true,
            "reviewer_conflict", true,
            "budget_exceeded", true)
        if !popupReasons.Has(reason)
            return ""
    } else {
        return ""
    }
    return "Last Codex reviewer probe: " outcome " / " reason " (" elapsedMs " ms)"
}

; Whether a host is the editor extension panel (drives the Focus-button label).
; Decoupled from the badge string so badge text changes can't break the label.
IsPanelHost(host) => host = "vscode-extension"

; Pure stack layout. Given each card's outerY (top inset inside its window) and
; outerH (visible height) in slot order — index 1 = slot 0 = bottom-most — return
; the window-Y target for each so the visible cards sit bottom-anchored with a
; FIXED `gap` between them, regardless of differing heights. The old per-card math
; (baseY − slot·step derived from a card's OWN height) only held the gap when all
; cards were equal height; a taller card below a shorter one drove the gap
; negative → overlap (the active top card looked squashed). The recurrence
; subtracts each card's HEIGHT (oh), not its top inset (oy). A card's visible span
; is [ytar+oy, ytar+oy+oh]; harness-tested without GDI+ (T25).
P1_StackYTargets(outerYs, outerHs, anchorBottom, gap) {
    ytars := []
    visBottom := anchorBottom
    Loop outerYs.Length {
        oy := outerYs[A_Index], oh := outerHs[A_Index]
        ytars.Push(visBottom - oy - oh)
        visBottom := (visBottom - oh) - gap
    }
    return ytars
}

; Header bottom = top pad + title line + first command line + extra command lines.
; Pure (harness-tested T26): cmdLines 1/2 reproduce the old formula exactly, and
; it extends linearly to N lines for the expanded card.
P1_HeaderBottom(topPad, titleH, cmd1H, cmdLines, cmdLine2) {
    return topPad + titleH + cmd1H + (cmdLines - 1) * cmdLine2
}

; Is the command worth an Expand affordance? True when the full command holds text
; the collapsed line drops — either it differs from the collapsed string (lost to
; the 200-cap or to whitespace/newline collapse) OR it needs more than the
; collapsed line budget. The SAME predicate gates the affordance and Ctrl+Win+E
; (Codex iter2: a command truncated at 200 but fitting 2 lines must still expand).
P1_CmdTruncated(cmd, cmdFull, fullLines, collapsedMax) {
    return (cmdFull != cmd) || (fullLines > collapsedMax)
}

P1_FillRR(GR, color, x, y, w, h, r) {
    b := Gdip_BrushCreateSolid(color)
    Gdip_FillRoundedRectangle(GR, b, x, y, w, h, r)
    Gdip_DeleteBrush(b)
}

P1_FillRRGrad(GR, c1, c2, x, y, w, h, r) {
    b := Gdip_CreateLineBrushFromRect(x, y, w, h, c1, c2, 1)
    Gdip_FillRoundedRectangle(GR, b, x, y, w, h, r)
    Gdip_DeleteBrush(b)
}

P1_StrokeRR(GR, color, width, x, y, w, h, r) {
    p := Gdip_CreatePen(color, width)
    Gdip_DrawRoundedRectangle(GR, p, x, y, w, h, r)
    Gdip_DeletePen(p)
}

P1_Txt(GR, text, x, y, ww, opts, color, cw, ch, align := "", font := "Segoe UI") {
    o := "x" x " y" y " w" ww " " opts " " (align ? align " " : "") "c" Format("{:08X}", color)
    Gdip_TextToGraphics(GR, text, o, font, cw, ch)
}

; Natural single-line pixel width of text at the given style opts (Measure mode).
P1_TextW(GR, text, opts, font, cw, ch) {
    ret := Gdip_TextToGraphics(GR, text, "x0 y0 w99999 " opts, font, cw, ch, 1)
    parts := StrSplit(ret, "|")
    return parts.Length >= 3 ? parts[3] + 0 : 0
}

; Like P1_Txt but truncates with a trailing ellipsis to fit ww (single line).
; Binary-searches the longest prefix whose "prefix…" still fits the field.
P1_TxtClip(GR, text, x, y, ww, opts, color, cw, ch, align := "", font := "Segoe UI") {
    if text = ""
        return
    if P1_TextW(GR, text, opts, font, cw, ch) <= ww {
        P1_Txt(GR, text, x, y, ww, opts, color, cw, ch, align, font)
        return
    }
    ell := Chr(0x2026)
    lo := 0, hi := StrLen(text), best := ""
    while lo <= hi {
        mid := (lo + hi) // 2
        cand := (mid = 0 ? "" : SubStr(text, 1, mid)) ell
        if P1_TextW(GR, cand, opts, font, cw, ch) <= ww {
            best := cand, lo := mid + 1
        } else {
            hi := mid - 1
        }
    }
    P1_Txt(GR, (best = "" ? ell : best), x, y, ww, opts, color, cw, ch, align, font)
}

; Two-line variant of P1_TxtClip. Wraps onto a second line at the last word
; boundary that fits the width; the remainder is ellipsis-clipped on line 2.
; lineH = vertical offset of line 2 from line 1. Falls back to a char break if
; a single word overflows the field.
P1_TxtClip2(GR, text, x, y, ww, lineH, opts, color, cw, ch, font := "Segoe UI") {
    if text = ""
        return
    no := opts " NoWrap"
    if P1_TextW(GR, text, no, font, cw, ch) <= ww {
        P1_Txt(GR, text, x, y, ww, no, color, cw, ch, "", font)
        return
    }
    ; longest character prefix that fits on line 1
    lo := 1, hi := StrLen(text), fit := 1
    while lo <= hi {
        mid := (lo + hi) // 2
        if P1_TextW(GR, SubStr(text, 1, mid), no, font, cw, ch) <= ww
            fit := mid, lo := mid + 1
        else
            hi := mid - 1
    }
    brk := fit
    sp := InStr(SubStr(text, 1, fit), " ", , -1)   ; last space within the fit → word break
    if sp > 1
        brk := sp - 1
    line1 := SubStr(text, 1, brk)
    rest := LTrim(SubStr(text, brk + 1))
    P1_Txt(GR, line1, x, y, ww, no, color, cw, ch, "", font)
    P1_TxtClip(GR, rest, x, y + lineH, ww, no, color, cw, ch, "", font)
}

; Visual line count of `text` wrapped at width ww with WRAP ON (opts must NOT
; carry NoWrap): GDI+ both honours literal "`n" line breaks AND word-wraps long
; lines. Reads Gdip_MeasureString field 6 (Lines) via measure-mode. Capped at
; `cap`; never < 1. Used for the expand card's height + truncation predicate.
P1_TextLines(GR, text, ww, opts, font, cap) {
    if text = ""
        return 1
    ret := Gdip_TextToGraphics(GR, text, "x0 y0 w" ww " h99999 " opts, font, 64, 64, 1)
    parts := StrSplit(ret, "|")
    lines := parts.Length >= 6 ? Integer(parts[6]) : 1
    if lines < 1
        lines := 1
    return lines > cap ? cap : lines
}

; Draw `text` wrapped at width ww across up to `maxLines` lines — native GDI+
; wrap (opts WITHOUT NoWrap) so it honours "`n" and word-wraps. If the full text
; needs MORE than maxLines, binary-search the longest raw-text prefix whose
; "prefix…" still fits in maxLines and draw that (graceful overflow ellipsis).
P1_TxtWrapN(GR, text, x, y, ww, maxLines, opts, color, cw, ch, font := "Segoe UI") {
    if text = ""
        return
    if P1_TextLines(GR, text, ww, opts, font, maxLines + 1) <= maxLines {
        P1_Txt(GR, text, x, y, ww, opts, color, cw, ch, "", font)
        return
    }
    ell := Chr(0x2026)
    lo := 0, hi := StrLen(text), best := ell
    while lo <= hi {
        mid := (lo + hi) // 2
        cand := (mid = 0 ? "" : SubStr(text, 1, mid)) ell
        if P1_TextLines(GR, cand, ww, opts, font, maxLines + 1) <= maxLines
            best := cand, lo := mid + 1
        else
            hi := mid - 1
    }
    P1_Txt(GR, best, x, y, ww, opts, color, cw, ch, "", font)
}

P1_CloseIcon(GR, cx, cy, size, color) {
    pen := Gdip_CreatePen(color, Max(2, size // 7))
    h := size / 2
    Gdip_DrawLine(GR, pen, cx-h, cy-h, cx+h, cy+h)
    Gdip_DrawLine(GR, pen, cx-h, cy+h, cx+h, cy-h)
    Gdip_DeletePen(pen)
}

P1_Magnifier(GR, cx, cy, size, color) {
    pen := Gdip_CreatePen(color, Max(2, size // 9))
    d := size * 0.6
    ox := cx - size * 0.12, oy := cy - size * 0.12
    Gdip_DrawEllipse(GR, pen, ox - d/2, oy - d/2, d, d)
    hx := ox + (d/2) * 0.707, hy := oy + (d/2) * 0.707
    Gdip_DrawLine(GR, pen, hx, hy, hx + size * 0.34, hy + size * 0.34)
    Gdip_DeletePen(pen)
}

; Registration mark (типографская метка приводки): circle + crosshair. On the
; active card it prints magenta («в приводке»); queued cards fade to faint cream.
P1_RegMark(GR, cx, cy, r, color, penW) {
    pen := Gdip_CreatePen(color, penW)
    Gdip_DrawEllipse(GR, pen, cx-r, cy-r, 2*r, 2*r)
    ext := r * 1.55
    Gdip_DrawLine(GR, pen, cx-ext, cy, cx+ext, cy)
    Gdip_DrawLine(GR, pen, cx, cy-ext, cx, cy+ext)
    Gdip_DeletePen(pen)
}

; NNV brand fonts (redesign «Тихая стена»): private-load every TTF from the
; fonts\ dir next to THIS file (A_LineFile — survives #Include from tests\).
; FR_PRIVATE (0x10) = visible to this process only, nothing installed system-wide;
; Windows unloads them automatically at process exit.
P1_LoadBrandFonts() {
    n := 0
    Loop Files RegExReplace(A_LineFile, "[^\\]+$") "fonts\*.ttf"
        n += DllCall("Gdi32\AddFontResourceExW", "wstr", A_LoopFileFullPath, "uint", 0x10, "ptr", 0) ? 1 : 0
    return n
}

; Resolve brand families with per-family system fallbacks. GDI+ has NO silent
; font fallback — an unknown family kills that text draw entirely (returns -3),
; so every family is verified via Gdip_FontFamilyCreate before use.
P1_ResolveFonts() {
    pick(name, fb) {
        hf := Gdip_FontFamilyCreate(name)
        if hf {
            Gdip_DeleteFontFamily(hf)
            return name
        }
        return fb
    }
    return { sans: pick("IBM Plex Sans", "Segoe UI")
        , sansSemi: pick("IBM Plex Sans SemiBold", "Segoe UI Semibold")
        , mono: pick("IBM Plex Mono", "Consolas")
        , monoMed: pick("IBM Plex Mono Medium", "Consolas")
        , monoSemi: pick("IBM Plex Mono SemiBold", "Consolas")
        , disp: pick("Unbounded Black", "Segoe UI") }
}

class PromptPopup {
    static selectedIndex := 1
    static promptData := []
    static _refreshFn := ""
    static visible := false
    ; Signature of the prompt set that was visible when the user dismissed the
    ; popup. AutoShowCheck refuses to re-open while the current prompt set
    ; matches — otherwise `Ctrl+Win+Esc` flickers: popup closes, AutoShowCheck
    ; re-opens it 500ms later because the underlying prompt is still live.
    ; Cleared whenever Show() runs (fresh intent) or when the prompt set
    ; changes (different prompts = user expects a re-notify).
    static dismissedSignature := ""
    ; Per-key dismissal set (CX6): suppression by SUBSET — survives rows of the
    ; dismissed set dying off (pass-released hooks), while any new prompt id
    ; still re-opens. dismissedSignature is kept as the legacy exact-set marker.
    static dismissedKeys := Map()

    ; --- v6 GDI+ renderer (BACKLOG 11) ---
    static peakAlpha := 255       ; resting popup opacity — fully opaque (Егор, живой фидбек
                                  ; 2026-07-17: любой просвет подложки убивает читаемость текста)
    static cards := []            ; live GDI+ card objects (includes fading ones)
    static expandedKeys := Map()  ; prompt keys (by _KeyOf) whose card shows the full command
    static _reconciling := false  ; re-entrancy guard: _RebuildCard/_BuildCard g.Show pumps messages
    static _reconcilePending := false ; a reconcile arrived mid-flight → re-run after (coalesce, never drop)
    static _displayReloadPending := false ; topology changed inside g.Show → reload after reconcile owns no cards
    static _epoch := 0            ; teardown generation; Hide() bumps it → cancels in-flight _BuildCard
    static _gdipToken := 0        ; lazy Gdip_Startup token; 0 = not started / failed
    static _gdipReady := false    ; one-time init guard (token + OnMessage + OnExit)
    static _animFn := ""          ; bound 16ms _AnimStep timer (self-arming)
    static _measGR := 0           ; scratch graphics for text measurement pre-DIB
    static brandF := 0            ; resolved NNV font families (P1_ResolveFonts)
    static _measHdc := 0
    static _measHbm := 0
    static _measObm := 0
    static _gdipBeeped := false   ; fail-loud error beep fired once per session
    static _gdipFailSig := ""     ; prompt-set signature already fail-loud'd (anti-respam)

    static IsVisible() {
        return this.visible
    }

    static _TargetDisplays() {
        global P1_DISPLAY_CATALOG, P1_POPUP_DISPLAY_PREFS
        if P1_DISPLAY_CATALOG.Length = 0
            P1_DISPLAY_CATALOG := P1_GetDisplayCatalog()
        return P1_ResolvePopupTargets(P1_DISPLAY_CATALOG, P1_POPUP_DISPLAY_PREFS)
    }

    ; A topology/preference change invalidates every window's physical geometry.
    ; Rebuild without Hide(): prompt selection and shared expand state survive.
    static ReloadDisplays() {
        if !this.visible
            return
        if this._reconciling {
            this._displayReloadPending := true
            this._reconcilePending := true
            return
        }
        this._epoch += 1
        if this._animFn {
            SetTimer(this._animFn, 0)
            this._animFn := ""
        }
        for card in this.cards
            this._FreeCard(card)
        this.cards := []
        this._Reconcile()
    }

    ; Stable string signature of the current (or given) prompt set, used to
    ; suppress re-opening the EXACT set the user just dismissed (anti-flicker).
    ; Keyed on prompt_id — the same identity the cards use (_KeyOf) — so a
    ; re-asked prompt (fresh pending id from the hook) always busts the
    ; dismissal and re-opens. The id is unique per hook invocation, which makes
    ; this robust without depending on detected_at (two prompts can land in the
    ; same millisecond). Falls back to project|terminal_index|detected_at for
    ; rows without a prompt_id.
    static ComputeSignature(prompts) {
        sig := ""
        for p in prompts {
            if p.HasOwnProp("prompt_id") && p.prompt_id != "" {
                sig .= p.prompt_id "`n"
            } else {
                ti := p.HasOwnProp("terminal_index") ? p.terminal_index : -1
                da := p.HasOwnProp("detected_at") ? p.detected_at : 0
                sig .= p.project_name "|" ti "|" da "`n"
            }
        }
        return sig
    }

    static Show(prompts) {
        this.promptData := prompts
        this.selectedIndex := 1
        ; Explicit Show() = clear any lingering dismissal (user wants popup).
        this.dismissedSignature := ""
        this.dismissedKeys := Map()
        if !this.EnsureGdip() {
            ; GDI+ unavailable (≈never — gdiplus.dll is a core Windows component).
            ; Fail loud instead of a blind no-op: the hook's arrival ding still
            ; plays, but the popup itself would silently never appear otherwise.
            this._FailLoud(this.ComputeSignature(prompts))
            return                       ; stay !visible, no timer → Refresh/MoveSelection inert
        }
        this._SyncCards()
        this.visible := true

        ; Start auto-refresh timer (200ms) — store bound fn for cancellation
        this._refreshFn := ObjBindMethod(this, "AutoRefresh")
        SetTimer(this._refreshFn, 200)
    }

    ; Natural close — called when Refresh detects no more prompts (answer
    ; delivered, hook pending gone). NO dismiss-suppression; a new prompt
    ; arriving right after should pop the UI fresh.
    static Hide() {
        this.visible := false
        ; Bump the teardown generation so any _BuildCard suspended in g.Show right
        ; now (its message pump let this Hide run) aborts on return instead of
        ; pushing/presenting a card into the torn-down stack (ghost-after-hide).
        this._epoch += 1
        if this._refreshFn {
            SetTimer(this._refreshFn, 0)
            this._refreshFn := ""
        }
        ; gdip: stop the animation tick + destroy/free all card GDI resources
        if this._animFn {
            SetTimer(this._animFn, 0)
            this._animFn := ""
        }
        for card in this.cards
            this._FreeCard(card)
        this.cards := []
        this.expandedKeys := Map()   ; expand state is per-showing; never leak across opens
    }

    ; Explicit user dismissal (Escape / popup close). Records current signature
    ; so AutoShowCheck won't re-open the exact same set — but a new detected_at
    ; from any subsequent prompt registration busts the suppression. Attention
    ; rows are notifications with no answer channel: dismiss acknowledges and
    ; deletes them. Picker rows remain hook-owned and are only suppressed.
    ; Decision rows (panel AND standalone since v5.4) get an early-release
    ; "pass": dismissing the popup means "I'll answer in the window myself",
    ; so release the waiting hook right away instead of letting it burn the
    ; rest of its bounded wait. The prompt itself keeps waiting in its UI.
    static DismissByUser() {
        if this.visible {
            this.dismissedSignature := this.ComputeSignature(this.promptData)
            ; Per-key suppression set (live smoke CX6, 2026-07-02): decision rows
            ; die right after the "pass" below (their hook exits and deletes the
            ; pending), so the exact-signature match above never holds again and
            ; the popup used to re-open with the surviving native rows — Esc
            ; looked like it "closed only the top card". Suppress by SUBSET
            ; instead: stay hidden while every live prompt was part of the
            ; dismissed set; any NEW prompt id still busts the suppression.
            this.dismissedKeys := Map()
            for p in this.promptData
                this.dismissedKeys[this._KeyOf(p)] := true
            for p in this.promptData {
                if p.HasOwnProp("decision_file") && p.decision_file != ""
                    WriteHookDecision(p, "pass", true)
                if p.HasOwnProp("kind") && p.kind = "attention"
                    && p.HasOwnProp("pending_file") && p.pending_file != ""
                    try FileDelete(p.pending_file)
            }
        }
        this.Hide()
    }

    ; True while the dismissal suppression holds: the user Esc-dismissed a set
    ; and every currently-live prompt belongs to it (rows may have died since —
    ; a shrinking subset stays suppressed). Empty prompt list never suppresses.
    static AllDismissed(prompts) {
        if this.dismissedKeys.Count = 0 || prompts.Length = 0
            return false
        for p in prompts {
            if !this.dismissedKeys.Has(this._KeyOf(p))
                return false
        }
        return true
    }

    static Refresh() {
        if !this.visible
            return
        ; visible is only ever set after EnsureGdip() succeeded, so _gdipReady is
        ; true and _gdipToken != 0 here — the gdip refresh is always the path.
        this._RefreshGdip()
    }

    static AutoRefresh() {
        this.Refresh()
    }

    ; Move the selected-row highlight up/down (wraps around). Bound to
    ; Ctrl+Win+Up/Down while the popup is visible — plain arrows are NOT
    ; intercepted: the popup is +NoActivate, focus stays in the user's app,
    ; where bare arrow keys have their own meaning (incl. Claude's TUI).
    static MoveSelection(delta) {
        n := this.promptData.Length
        if !this.visible || n = 0
            return
        this.selectedIndex := Mod(this.selectedIndex - 1 + delta + n, n) + 1
        this._ApplySelection()
    }

    ; Toggle the ACTIVE card's full-command view (Ctrl+Win+E). Expanding is gated
    ; on the same `truncated` predicate as the affordance — a short command that
    ; fully fits has nothing to expand, so the hotkey is a no-op there. Collapsing
    ; an already-expanded card is always allowed.
    static ToggleExpandActive() {
        if !this.visible || this.selectedIndex < 1 || this.selectedIndex > this.promptData.Length
            return
        key := this._KeyOf(this.promptData[this.selectedIndex])
        if this.expandedKeys.Has(key) {
            this.expandedKeys.Delete(key)             ; collapse (always allowed)
        } else {
            card := this._FindCard(key)
            if !card || !card.truncated               ; nothing hidden → no-op
                return
            this.expandedKeys[key] := true
        }
        this._Reconcile()
    }


    static OnButtonClick(promptIndex, optionIndex) {
        if promptIndex > this.promptData.Length
            return
        target := this.promptData[promptIndex]
        kind := target.HasOwnProp("kind") && target.kind != ""
            ? target.kind
            : "permission"
        if optionIndex = 0 || kind != "permission" {
            ; Focus action — user answers in TUI / panel
            FocusPrompt(target)
        } else {
            ; prevWin=0: popup is +NoActivate, focus never left the user's window
            DispatchByKind(target, String(optionIndex), 0, 0)
        }
        ; Refresh — the answered prompt's pending is removed by the hook on exit
        SetTimer(ObjBindMethod(this, "Refresh"), -500)
    }

    ; =================== v6 GDI+ renderer methods (BACKLOG 11) ===================
    ; The popup's renderer. Routing/dispatch stays in
    ; SendToPrompt/OnButtonClick/DispatchByKind — these methods are presentation
    ; only (build/draw/animate/hit-test the card stack).

    ; Lazy one-time GDI+ init. Returns true if GDI+ is usable; on failure Show()
    ; fails loud (sound + tooltip) instead of rendering. Registers the click
    ; handler + exit cleanup exactly once.
    static EnsureGdip() {
        if this._gdipReady
            return this._gdipToken != 0
        this._gdipReady := true
        this._gdipToken := Gdip_Startup()
        if !this._gdipToken
            return false
        ; scratch graphics for measuring text before a card's own DIB exists
        ; (the card height is derived from how many lines the command needs).
        this._measHbm := CreateDIBSection(64, 64)
        this._measHdc := CreateCompatibleDC()
        this._measObm := SelectObject(this._measHdc, this._measHbm)
        this._measGR := Gdip_GraphicsFromHDC(this._measHdc)
        Gdip_SetTextRenderingHint(this._measGR, 4)
        ; brand fonts BEFORE the first font lookup: GDI+ snapshots the process
        ; font table on first use, so FR_PRIVATE loads must precede it.
        P1_LoadBrandFonts()
        this.brandF := P1_ResolveFonts()
        OnMessage(0x0201, ObjBindMethod(this, "_OnLClick"))   ; WM_LBUTTONDOWN
        OnExit(ObjBindMethod(this, "_GdipCleanup"))
        return true
    }

    ; GDI+ init failed (≈never — gdiplus.dll is a core Windows component). Make the
    ; degraded state legible instead of a silent no-op: one error beep per session
    ; + a tooltip, keyed by prompt-set signature so AutoShowCheck's 500ms Show()
    ; retries don't re-fire the tooltip every tick. The hook's per-prompt arrival
    ; ding still plays independently, so the user is never left fully in silence.
    static _FailLoud(sig) {
        if sig = this._gdipFailSig
            return
        this._gdipFailSig := sig
        if !this._gdipBeeped {
            this._gdipBeeped := true
            SoundPlay "*48"
        }
        ToolTip "press-1: popup unavailable (GDI+ init failed) — answer in the terminal / panel"
        SetTimer((*) => ToolTip(), -6000)
    }

    static _GdipCleanup(*) {
        if this._measGR {
            try Gdip_DeleteGraphics(this._measGR)   ; GR holds the HDC — delete it FIRST
            try SelectObject(this._measHdc, this._measObm)
            try DeleteObject(this._measHbm)
            try DeleteDC(this._measHdc)
            this._measGR := 0
        }
        if this._gdipToken {
            Gdip_Shutdown(this._gdipToken)
            this._gdipToken := 0
        }
    }

    ; Compose the card's command/subject line: permission rows read as a command
    ; "Bash(cmd)"; picker/attention rows show their prompt text alone.
    static _ComposeCmd(info, kind) {
        hasInput := info.HasOwnProp("tool_input_short") && info.tool_input_short != ""
        if kind = "permission"
            s := hasInput ? info.tool_name "(" info.tool_input_short ")" : info.tool_name
        else
            s := hasInput ? info.tool_input_short : info.tool_name
        ; Collapse embedded newlines/tabs to a single space: NoWrap stops WORD
        ; wrapping but still honours literal "`n" (a multi-line bash command would
        ; render 3+ lines under the buttons). One logical line → _CmdLines measure
        ; + the 2-line word-wrap fully control card height.
        return Trim(RegExReplace(s, "\s+", " "))
    }

    ; Full command source for the EXPANDED card: same shape as _ComposeCmd but
    ; from tool_input_full (newlines PRESERVED — the expanded render honours them)
    ; with NO whitespace collapse. Falls back to the short field when full is
    ; absent (legacy rows). Only outer whitespace is trimmed; interior kept.
    static _ComposeCmdFull(info, kind) {
        full := (info.HasOwnProp("tool_input_full") && info.tool_input_full != "")
            ? info.tool_input_full
            : (info.HasOwnProp("tool_input_short") ? info.tool_input_short : "")
        hasInput := full != ""
        if kind = "permission"
            s := hasInput ? info.tool_name "(" full ")" : info.tool_name
        else
            s := hasInput ? full : info.tool_name
        return Trim(s, " `t`r`n")
    }

    ; How many lines the command needs at width ww — 1 or 2 (capped; line 2 ellipsizes).
    static _CmdLines(cmd, ww, opts, font) {
        if cmd = "" || !this._measGR
            return 1
        return P1_TextW(this._measGR, cmd, opts, font, 64, 64) > ww ? 2 : 1
    }

    ; Prompt identity key: prompt_id when present (addressable, immune to index
    ; shift), else the signature atom. Cards reconcile by this, NOT by position.
    static _KeyOf(info) {
        if info.HasOwnProp("prompt_id") && info.prompt_id != ""
            return info.prompt_id
        ti := info.HasOwnProp("terminal_index") ? info.terminal_index : -1
        da := info.HasOwnProp("detected_at") ? info.detected_at : 0
        return info.project_name "|" ti "|" da
    }

    static _FindCard(key, displayId := "") {
        for c in this.cards
            if c.key = key && (displayId = "" || c.displayId = displayId)
                && c.phase != "dead" && c.phase != "dismiss"
                return c
        return ""
    }

    static _SyncCards() {
        this._Reconcile()
    }

    ; Key-based reconciliation (drives both Show and Refresh): fade gone prompts,
    ; add new ones, redraw changed ones in place, re-slot survivors, and remap the
    ; active selection by key. Never rebuilds the whole stack.
    ;
    ; Re-entrancy guard (Fix 1): _RebuildCard/_BuildCard call g.Show(), which pumps
    ; the Windows message queue — that can let the 200ms refresh timer or a rapid
    ; second click re-enter here mid-rebuild, splice against a card we're about to
    ; replace, and orphan a shown-but-untracked duplicate (seen live: expand spam →
    ; ghost card). Serialize — but COALESCE, don't drop: a re-entrant call sets a
    ; pending flag and the outer call re-runs the body once it finishes. Dropping
    ; instead lost the AutoRefresh dismiss-pass during continuous Expand toggling,
    ; so a Codex card lingered after its hook released (seen live). Covers both
    ; yields (g.Show, gui.Destroy), as both run inside _Reconcile.
    static _Reconcile() {
        if this._reconciling {
            this._reconcilePending := true       ; arrived mid-flight → don't lose it
            return
        }
        this._reconciling := true
        try {
            guard := 0
            loop {
                this._reconcilePending := false
                ep := this._epoch
                this._ReconcileBody()
                ; Hide() ran inside the body (teardown) → do NOT re-run, or we'd
                ; resurrect the just-torn-down stack. epoch bump is the signal.
            } until !this._reconcilePending || this._epoch != ep || ++guard >= 5
        } finally {
            this._reconciling := false
        }
        if this._displayReloadPending {
            this._displayReloadPending := false
            this.ReloadDisplays()
        }
    }

    static _ReconcileBody() {
        ; Teardown generation (Fix 3): if Hide() runs inside a _BuildCard g.Show
        ; pump below (Hide is NOT routed through _Reconcile, so the guard above
        ; can't catch it), the epoch changes and we abort instead of pushing a
        ; card into the torn-down stack (ghost-after-hide).
        epoch0 := this._epoch
        prompts := this.promptData
        displays := this._TargetDisplays()
        selKey := (this.selectedIndex >= 1 && this.selectedIndex <= prompts.Length)
            ? this._KeyOf(prompts[this.selectedIndex]) : ""

        liveKeys := Map()
        for info in prompts
            liveKeys[this._KeyOf(info)] := true
        liveInstances := Map()
        for display in displays
            for info in prompts
                liveInstances[P1_CardInstanceKey(this._KeyOf(info), display.id)] := true

        ; prune expand state for prompts that are gone (leak guard — the map would
        ; otherwise accumulate keys for every command ever expanded this session)
        staleExp := []
        for k in this.expandedKeys
            if !liveKeys.Has(k)
                staleExp.Push(k)
        for k in staleExp
            this.expandedKeys.Delete(k)

        ; fade cards whose prompt vanished from the protocol (answered/dead hook)
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            if !liveInstances.Has(c.instanceKey)
                this._StartDismiss(c)
        }

        ; add / update live prompts; newest (last) = slot 0 = bottom, oldest on top
        n := prompts.Length
        for display in displays {
            for i, info in prompts {
                key := this._KeyOf(info)
                slot := n - i
                existing := this._FindCard(key, display.id)
                if existing {
                    ; expand toggle flipped → rebuild at the new height (in-place
                    ; redraw can't resize the DIB). Must precede content changes.
                    if existing.expanded != this.expandedKeys.Has(key) {
                        existing := this._RebuildCard(existing, info, slot)
                        if this._epoch != epoch0
                            return                   ; Hide tore down during the rebuild
                    } else if this._RenderFieldsDiffer(existing.info, info) {
                        existing.info := info
                        this._SetCardContent(existing, info)
                        existing.dirty := true
                    } else {
                        existing.info := info
                    }
                    if existing.slot != slot
                        this._Reslot(existing, slot)
                } else {
                    card := this._BuildCard(info, slot, display)
                    if this._epoch != epoch0 {
                        this._FreeCard(card)         ; Hide tore down during the build
                        return
                    }
                    this.cards.Push(card)
                    this._StartAppear(card)
                }
            }
        }

        ; Dedup safety (Fix 2): at most one non-fading card per key. A rebuild or
        ; refresh race could leave two cards sharing a key — the extra would float
        ; forever (its key is live, so the vanish-loop above never fades it). Keep
        ; the first, dismiss the rest. Skips fading cards, so a legit
        ; dismiss-then-re-add (same key, one dismissing + one appearing) is untouched.
        seenKeys := Map()
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            if seenKeys.Has(c.instanceKey)
                this._StartDismiss(c)
            else
                seenKeys[c.instanceKey] := true
        }

        ; Position the whole stack with a clean fixed gap (height-safe) — must run
        ; synchronously here, AFTER cards are added/reslotted and BEFORE _ArmAnim,
        ; so appear/reflow animations start from the true target.
        this._Restack()
        this._RemapSelection(selKey)
        this._ApplySelection()
        this._ArmAnim()
    }

    static _RenderFieldsDiffer(a, b) {
        ak := a.HasOwnProp("kind") ? a.kind : "permission"
        bk := b.HasOwnProp("kind") ? b.kind : "permission"
        if ak != bk
            return true
        ao := a.HasOwnProp("options") ? a.options.Length : 0
        bo := b.HasOwnProp("options") ? b.options.Length : 0
        if ao != bo
            return true
        if a.tool_name != b.tool_name || a.tool_input_short != b.tool_input_short
            return true
        ah := a.HasOwnProp("host") ? a.host : ""
        bh := b.HasOwnProp("host") ? b.host : ""
        return ah != bh
    }

    static _RemapSelection(selKey) {
        n := this.promptData.Length
        if n = 0 {
            this.selectedIndex := 0
            return
        }
        if selKey != "" {
            for i, info in this.promptData
                if this._KeyOf(info) = selKey {
                    this.selectedIndex := i
                    return
                }
        }
        if this.selectedIndex < 1
            this.selectedIndex := 1
        else if this.selectedIndex > n
            this.selectedIndex := n
    }

    ; Mark which card is active (selected) and redraw cards that changed.
    static _ApplySelection() {
        activeKey := (this.selectedIndex >= 1 && this.selectedIndex <= this.promptData.Length)
            ? this._KeyOf(this.promptData[this.selectedIndex]) : ""
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            wantActive := (c.key = activeKey)
            if (c.HasOwnProp("dirty") && c.dirty) || c.active != wantActive {
                c.active := wantActive
                c.dirty := false
                this._RedrawIdle(c)
            }
        }
    }

    ; Update a card's DIB and present it if it's at rest (appear/dismiss frames
    ; are presented by _AnimStep, so don't fight them mid-flight).
    static _RedrawIdle(card) {
        this._DrawCard(card, "")
        if card.phase = "idle"
            P1_Present(card, card.x, card.ytar, this.peakAlpha)
    }

    static _RefreshGdip() {
        global POPUP_MIN_PROMPTS
        prompts := ReadAllPrompts()
        this.promptData := prompts
        if prompts.Length = 0 || prompts.Length < POPUP_MIN_PROMPTS {
            ; don't hard-Hide — fade each card; _AnimStep calls Hide on the last
            for c in this.cards
                this._StartDismiss(c)
            this._ArmAnim()
            if this.cards.Length = 0
                this.Hide()
            return
        }
        this._Reconcile()
    }

    static _StartAppear(card) {
        card.phase := "appear", card.dur := 360, card.t0 := A_TickCount
    }

    static _StartDismiss(card) {
        if card.phase = "dead" || card.phase = "dismiss"
            return
        card.phase := "dismiss", card.dur := 300, card.t0 := A_TickCount
    }

    ; Slot changed (a card above was answered) → just record the new slot.
    ; Positioning is owned by _Restack (clean fixed-gap layout, height-safe); it
    ; starts the reflow animation when a card's true target actually moves.
    static _Reslot(card, slot) {
        card.slot := slot
    }

    ; Re-anchor the whole live stack with a FIXED gap between cards — clean
    ; separation immune to differing card heights (fixes the overlap bug where a
    ; taller card below a shorter one drove the gap negative). Slot-ordered
    ; geometry → P1_StackYTargets → move each card: an idle card animates via the
    ; existing reflow; a card mid-flight (appear/reflow) gets ytar rewritten in
    ; place (the 16ms tick reads ytar live, so it lands correctly). Called from
    ; _Reconcile synchronously BEFORE _ArmAnim.
    static _Restack() {
        groups := Map()
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            if !groups.Has(c.displayId)
                groups[c.displayId] := []
            groups[c.displayId].Push(c)
        }
        for displayId, live in groups {
            if live.Length = 0
                continue
            ; insertion sort by slot ascending (slot 0 = bottom-most)
            Loop live.Length - 1 {
                i := A_Index
                Loop live.Length - i {
                    j := A_Index
                    if live[j].slot > live[j + 1].slot {
                        tmp := live[j], live[j] := live[j + 1], live[j + 1] := tmp
                    }
                }
            }
            S := live[1].d.S
            gap := S(8), anchorBottom := live[1].display.workBottom - S(8)
            outerYs := [], outerHs := []
            for c in live {
                outerYs.Push(c.d.outerY)
                outerHs.Push(c.d.outerH)
            }
            ytars := P1_StackYTargets(outerYs, outerHs, anchorBottom, gap)
            for idx, c in live {
                newY := ytars[idx]
                if c.ytar = newY
                    continue
                if c.phase = "idle" {
                    c.fromY := c.ytar
                    c.ytar := newY
                    c.phase := "reflow", c.dur := 200, c.t0 := A_TickCount
                } else {
                    c.ytar := newY    ; tick reads ytar live → appear/reflow re-lands
                }
            }
        }
    }

    ; Start the 16ms tick if any card is moving (idempotent, self-disarming).
    static _ArmAnim() {
        for c in this.cards {
            if c.phase = "appear" || c.phase = "hold" || c.phase = "dismiss" || c.phase = "reflow" {
                if !this._animFn {
                    this._animFn := ObjBindMethod(this, "_AnimStep")
                    SetTimer(this._animFn, 16)
                }
                return
            }
        }
    }

    static _AnimStep() {
        now := A_TickCount
        moving := false
        dead := []
        for c in this.cards {
            if c.phase = "idle" || c.phase = "dead"
                continue
            t := (now - c.t0) / c.dur
            t := t < 0 ? 0 : t > 1 ? 1 : t
            if c.phase = "appear" {
                e := P1_Smooth(t)
                P1_Present(c, c.x, c.ytar + c.slide * (1 - e), Round(this.peakAlpha * e))
                if t >= 1
                    c.phase := "idle"
                else
                    moving := true
            } else if c.phase = "reflow" {
                e := P1_Smooth(t)
                P1_Present(c, c.x, c.fromY + (c.ytar - c.fromY) * e, this.peakAlpha)
                if t >= 1
                    c.phase := "idle"
                else
                    moving := true
            } else if c.phase = "hold" {
                if t >= 1 {
                    c.phase := "idle"
                    this._DrawCard(c, "")
                    P1_Present(c, c.x, c.ytar, this.peakAlpha)
                } else
                    moving := true
            } else if c.phase = "dismiss" {
                e := P1_Smooth(t)
                P1_Present(c, c.x, c.ytar + c.slide2 * e, Round(this.peakAlpha * (1 - e)))
                if t >= 1 {
                    c.phase := "dead"
                    dead.Push(c)
                } else
                    moving := true
            }
        }
        for c in dead {
            this._FreeCard(c)
            Loop this.cards.Length
                if this.cards[A_Index] = c {
                    this.cards.RemoveAt(A_Index)
                    break
                }
        }
        if !moving {
            if this._animFn {
                SetTimer(this._animFn, 0)
                this._animFn := ""
            }
            if this.cards.Length = 0 && this.visible
                this.Hide()
        }
    }

    static _FreeCard(card) {
        try Gdip_DeleteGraphics(card.G)       ; GR holds the HDC — delete it FIRST
        try SelectObject(card.hdc, card.obm)
        try DeleteObject(card.hbm)
        try DeleteDC(card.hdc)
        try card.gui.Destroy()
    }

    ; Rebuild a card in place at a new height (the only way to resize its DIB) when
    ; its expand state toggled. Order is LOAD-BEARING: draw + present the FRESH card
    ; FIRST, free the OLD one LAST — so there is never a blank frame. The fresh card
    ; starts at the old card's resting Y as phase=idle (NOT appear — a fade on every
    ; toggle would be wrong); _Restack then nudges it + neighbours to the clean
    ; fixed-gap layout via the reflow animation.
    ;
    ; Cancellation (Fix 3): _BuildCard's g.Show pumps messages, so Hide() (NOT
    ; routed through the _Reconcile guard) can tear everything down mid-build. After
    ; the build, BEFORE the visible present (fresh still at alpha 0), bail if the
    ; teardown epoch changed or `old` is gone: free fresh, return old — never push
    ; or present a card into a torn-down stack (would be a ghost-after-hide).
    static _RebuildCard(old, info, slot) {
        ep := this._epoch
        fresh := this._BuildCard(info, slot, old.display) ; shared display, new height; g.Show pumps
        oldIdx := 0
        Loop this.cards.Length
            if this.cards[A_Index] = old {
                oldIdx := A_Index
                break
            }
        if this._epoch != ep || oldIdx = 0 {
            this._FreeCard(fresh)                  ; torn down (or old vanished) during build → abort
            return old
        }
        fresh.ytar := old.ytar
        fresh.fromY := old.ytar
        fresh.phase := "idle"
        fresh.active := old.active
        this._DrawCard(fresh, "")
        P1_Present(fresh, fresh.x, fresh.ytar, this.peakAlpha)
        this.cards[oldIdx] := fresh               ; no yield since the check → index stable
        this._FreeCard(old)
        return fresh
    }

    static _SetCardContent(card, info) {
        d := card.d
        d.kind := (info.HasOwnProp("kind") && info.kind != "") ? info.kind : "permission"
        d.options := info.HasOwnProp("options") ? info.options : []
        if d.kind = "permission" && d.options.Length = 0
            d.options := ["Allow", "Deny"]      ; native fallback parity
        d.n := (d.kind = "permission") ? d.options.Length : 0
        d.subj := info.project_name
        ; BACKLOG 13: standalone terminals prefer the claude tab topic over
        ; basename(cwd). VS Code hosts (B/C) keep project_name — there the
        ; basename is the meaningful project name, not a home-folder artifact.
        if info.HasOwnProp("host") && (info.host = "windows-terminal" || info.host = "conhost") {
            topic := StandaloneCardTitle(info)
            if topic != ""
                d.subj := topic
        }
        d.cmd := this._ComposeCmd(info, d.kind)
        d.cmdFull := this._ComposeCmdFull(info, d.kind)
        d.host := info.HasOwnProp("host") ? info.host : ""
        d.agent := info.HasOwnProp("agent") ? info.agent : ""
    }

    ; Build one physical-pixel layered card on one resolved target display.
    static _BuildCard(info, slot, display) {
        wl := display.workLeft, wt := display.workTop
        wr := display.workRight, wb := display.workBottom
        sc := P1_PopupScale(display.dpi, wr - wl)
        fsc := sc
        S := (px) => Round(px * sc)
        FS := (px) => Round(px * fsc)

        W := S(640), M := S(34)
        outerX := M, outerY := S(26), outerW := W - 2*M
        outerR := S(22), bezel := S(6)
        cardX := outerX + bezel, cardY := outerY + bezel
        cardW := outerW - 2*bezel, cardR := outerR - bezel
        cpad := S(28), contentX := cardX + cpad, contentW := cardW - 2*cpad
        ; logo is smaller than the old Segoe wordmark: Unbounded Black runs wide.
        ; footer 11→12 (живой фидбек: хинт и чип агента читались на грани)
        fz := { logo:FS(13), subj:FS(21), cmd:FS(16), digit:FS(24), label:FS(14), footer:FS(12) }
        F := this.brandF ? this.brandF
           : { sans:"Segoe UI", sansSemi:"Segoe UI Semibold", mono:"Consolas"
             , monoMed:"Consolas", monoSemi:"Consolas", disp:"Segoe UI" }

        ; Command line(s): measure how many lines the command needs at the content
        ; width so the card height GROWS for a long command (wraps) instead of
        ; clipping to one line (E). Collapsed = 1–2 lines (line 2 ellipsizes);
        ; expanded (Change 2) = the FULL command across up to 10 lines.
        kind0 := (info.HasOwnProp("kind") && info.kind != "") ? info.kind : "permission"
        cmdLine2 := Round(fz.cmd * 1.25)        ; per-line vertical step
        cmd0 := this._ComposeCmd(info, kind0)
        cmdFull0 := this._ComposeCmdFull(info, kind0)
        expanded := this.expandedKeys.Has(this._KeyOf(info))
        collapsedMax := 2, expandedMax := 10
        ; truncated gates BOTH the Expand affordance and the Ctrl+Win+E toggle:
        ; true when the full command holds text the collapsed line drops (200-cap
        ; or collapsed whitespace/newlines) OR needs more than the 2 collapsed
        ; lines. Measure full at content width (wrap ON, honours "`n").
        fullLines := this._measGR
            ? P1_TextLines(this._measGR, cmdFull0, contentW, "s" fz.cmd, F.mono, expandedMax + 1)
            : 1
        truncated := P1_CmdTruncated(cmd0, cmdFull0, fullLines, collapsedMax)
        if expanded {
            cmdLines := Min(fullLines, expandedMax)
            cmdMaxLines := expandedMax
        } else {
            cmdLines := this._CmdLines(cmd0, contentW, "s" fz.cmd " NoWrap", F.mono)
            cmdMaxLines := collapsedMax
        }

        ; header: top pad + project-name line (hero) + command line(s). The old
        ; eyebrow line (NEEDS ATTENTION / PERMISSION REQUEST) is gone in v6 — the
        ; project name is the title, the host moves into a small leading pill, and
        ; the prompt kind already reads from the buttons (digits vs Focus).
        headerBottom := P1_HeaderBottom(S(22), Round(fz.subj*1.5), Round(fz.cmd*1.35), cmdLines, cmdLine2)
        ; Expand/Collapse affordance row (Fix 4): a slim, right-aligned row directly
        ; under the command — shown only when truncated/expanded. It partly replaces
        ; the command→button gap so the card grows only ~12px when present.
        hasAfford := truncated || expanded
        affRowH := hasAfford ? Round(fz.cmd * 1.5) : 0
        affY := cardY + headerBottom                  ; card-coord top of the affordance row
        blockH := fz.digit + Round(fz.digit*0.18) + fz.label
        btnH := blockH + FS(18)
        gapHB := S(20), footerGap := S(14), botPad := S(16)
        preBtn := hasAfford ? affRowH + S(8) : gapHB  ; command(+affordance) → buttons spacing
        cardH := headerBottom + preBtn + btnH + footerGap + fz.footer + botPad
        outerH := cardH + 2*bezel
        H := outerY + outerH + S(34)
        btnR := S(14), bgap := S(14), fbw := S(50)
        btnTop := cardY + headerBottom + preBtn

        ; NNV «Тихая стена» (redesign 2026-07): ink-wall environment, two inks,
        ; strictly dosed — magenta = action (digit 1, reg mark, wordmark dot),
        ; violet = state (agent chip, active ring). Cream text on the wall
        ; (#ddd4bd on #1e1640 = 11.4:1, verified in klava). Buttons are outline
        ; keycaps, no gradients; no glow anywhere — plain fills and strokes.
        ; fills are FULLY OPAQUE (Егор, живой фидбек 2026-07-17): на layered-окне
        ; полупрозрачная заливка пропускает текст подложки внутрь карточки и
        ; кнопок — читаемость умирает. Плашка кейкапа (keyFill) на ступень
        ; светлее стены гасит просвет там, где раньше был только контур.
        co := { shell:0xFF141031, shellRim:0x1AECE3CD, card:0xFF1E1640, cardRim:0x12ECE3CD
              , heading:0xFFDDD4BD, body:0xFFC8BDA1, muted:0x8CDDD4BD, faint:0xA8DDD4BD
              , keyFill:0xFF2A2158, keyRim:0x38ECE3CD, k1Rim:0xA6E11B76, k1Tx:0xFFFF2F88
              , chipBg:0xFF2C1A72, chipTx:0xFFDDD4BD
              , mag:0xFFE11B76, magGhost:0x80E11B76
              , shadow:0x04080C14
              , ring:0x8C452BA6 }                ; active-card ring = violet ink, dimmed alpha

        oldCtx := 0
        try oldCtx := DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        try g := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x80000 +E0x08000000 +OwnDialogs -DPIScale")
        finally {
            if oldCtx
                try DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldCtx, "Ptr")
        }
        hbm := CreateDIBSection(W, H), hdc := CreateCompatibleDC()
        obm := SelectObject(hdc, hbm), GR := Gdip_GraphicsFromHDC(hdc)
        Gdip_SetSmoothingMode(GR, 4), Gdip_SetTextRenderingHint(GR, 4)

        x := wr - S(24) - (outerX + outerW)
        step := outerH + S(8)
        baseY := wb - S(8) - (outerY + outerH)
        ytar := baseY - slot * step

        key := this._KeyOf(info)
        card := { gui:g, hwnd:g.Hwnd, hdc:hdc, hbm:hbm, obm:obm, G:GR, w:W, h:H
                , x:x, ytar:ytar, fromY:ytar, baseY:baseY, step:step, slide:S(8), slide2:S(8)
                , phase:"idle", t0:0, dur:0, rects:[]
                , key:key, instanceKey:P1_CardInstanceKey(key, display.id)
                , displayId:display.id, display:display, info:info, slot:slot, active:false, dirty:false
                , expanded:expanded, truncated:truncated
                , d:{ sc:sc, S:S, W:W, H:H, outerX:outerX, outerY:outerY, outerW:outerW, outerH:outerH, outerR:outerR
                    , cardX:cardX, cardY:cardY, cardW:cardW, cardH:cardH, cardR:cardR
                    , contentX:contentX, contentW:contentW, contentR:contentX+contentW
                    , btnTop:btnTop, btnH:btnH, btnR:btnR, bgap:bgap, fbw:fbw, footerGap:footerGap
                    , fz:fz, fonts:F, co:co
                    , cmdLines:cmdLines, cmdLine2:cmdLine2, cmdMaxLines:cmdMaxLines
                    , expanded:expanded, truncated:truncated, affY:affY, affRowH:affRowH, hasAfford:hasAfford
                    , subj:"", cmd:"", cmdFull:"", n:0, host:"", agent:"", kind:"permission", options:[] } }
        this._SetCardContent(card, info)

        oldCtx := 0
        try oldCtx := DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        try g.Show("NoActivate x" x " y" Round(ytar + card.slide) " w" W " h" H)
        finally {
            if oldCtx
                try DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldCtx, "Ptr")
        }
        this._DrawCard(card, "")
        P1_Present(card, x, ytar + card.slide, 0)
        return card
    }

    static _DrawCard(card, pressed := "") {
        d := card.d, GR := card.G, co := d.co, fz := d.fz, F := d.fonts
        W := d.W, H := d.H, sc := d.sc, S := d.S
        ; resting mis-registration offset (NNV signature). ≤1.2px по бренду; на
        ; сабпиксель GDI+ не способен — клампится к 1px до sc<1.25 (klava: 0.7px
        ; физически не отображается, потому не эмулируем дробь).
        misOff := Max(1, Round(1.2 * sc))
        card.rects := []

        Gdip_GraphicsClear(GR, 0x00000000)

        Loop 6 {
            ex := A_Index * 1.0 * sc
            P1_FillRR(GR, co.shadow, d.outerX-ex, d.outerY-ex+S(5), d.outerW+2*ex, d.outerH+2*ex, d.outerR+ex)
        }
        P1_FillRR(GR, co.shell, d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        if card.active
            P1_StrokeRR(GR, co.ring, Max(1, S(1)), d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        else
            P1_StrokeRR(GR, co.shellRim, 1, d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        P1_FillRR(GR, co.card, d.cardX, d.cardY, d.cardW, d.cardH, d.cardR)
        P1_StrokeRR(GR, co.cardRim, 1, d.cardX, d.cardY, d.cardW, d.cardH, d.cardR)

        ; --- header ---
        ; Top line: project name as the title (hero). Right corner: the close ✕
        ; (the "press-1" wordmark moved to a quiet bottom-right corner on every
        ; card — see the footer row). Second line: the command / question.
        ; Agent identity rides as a small leading pill before the title (see the
        ; pill block below). The host (panel/WT/console) is NOT on the card — it
        ; surfaces in the answer toast (ShowTip) and the Focus-button label.
        ty := d.cardY + S(22)                    ; project-name (title) line top
        nameCY := ty + fz.subj / 2               ; its vertical center — corner items align here

        ; right corner: just the ✕ close (wordmark lives in the footer row now).
        xc := d.contentR - S(5)
        P1_CloseIcon(GR, xc, nameCY, S(11), co.faint)
        card.rects.Push({x:xc - S(15), y:Round(nameCY) - S(15), w:S(30), h:S(30), type:"close"})
        rightEdge := xc - S(13)                  ; project title runs up to just before the ✕

        ; Leading agent pill (placement B): a small "Claude"/"Codex" chip before
        ; the project title so the agent is unmistakable and stacked cards from
        ; different agents read apart. Symmetric — both agents get it (D1: agent
        ; only; the host lives in the answer toast). Neutral fill, no per-agent
        ; colour (D2). Blank/unknown agent → no pill.
        titleX := d.contentX
        agentLbl := P1_AgentLabel(d.agent)
        if agentLbl != "" {
            lbl := StrUpper(agentLbl)                    ; mono uppercase — печатная плашка
            pfz := fz.footer
            ; SemiBold: Medium на фиолетовой плашке читался тонко (живой фидбек)
            tw := P1_TextW(GR, lbl, "s" pfz " NoWrap", F.monoSemi, W, H)
            ph := S(8), pillH := Round(pfz * 1.7)
            pillW := Round(tw) + 2*ph
            ; +S(2): чистая центровка по nameCY сажала плашку ВЫШЕ оптического
            ; центра заголовка (кегль-центр ≠ глиф-центр); живой фидбек Егора
            pillY := Round(nameCY - pillH/2) + S(2)
            ; Fill only — NO stroke. A full-radius (r=pillH/2) Gdip_DrawRoundedRectangle
            ; draws the rectangle's vertical edges INSIDE the rounded caps as faint
            ; "lines"; the solid violet fill alone separates the chip from the card.
            P1_FillRR(GR, co.chipBg, d.contentX, pillY, pillW, pillH, S(4))
            ; Label cell centred on the title's optical centre (nameCY) — same centre
            ; the title cell uses, so they read on one line. (No GDI+ vCenter: this
            ; vendored Gdip_TextToGraphics crashes on a Float text height there.)
            P1_Txt(GR, lbl, d.contentX + ph, Round(nameCY - pfz/2) + S(2), Round(tw) + S(4), "s" pfz " NoWrap", co.chipTx, W,H, "", F.monoSemi)
            titleX := d.contentX + pillW + S(10)
        }

        ; project name (title) — from after any pill, up to the ✕. The ghost sits
        ; on the ACTIVE card (2026-08-03, was inverted): the magenta
        ; mis-registration is the loudest mark on the card, so on a queued row it
        ; read AS the selection — Егор живьём: «нижняя как будто активная». NNV
        ; signature belongs to the hero; queued rows print one quiet layer.
        if card.active
            P1_TxtClip(GR, d.subj, titleX + misOff, ty + misOff, rightEdge - titleX, "s" fz.subj " NoWrap", co.magGhost, W,H, "", F.sansSemi)
        P1_TxtClip(GR, d.subj, titleX, ty, rightEdge - titleX, "s" fz.subj " NoWrap", card.active ? co.heading : co.faint, W,H, "", F.sansSemi)

        ; command / question line(s). Expanded → the full command (newlines
        ; preserved) word-wrapped across up to cmdMaxLines; else the 1–2 line
        ; collapsed summary.
        cy := ty + Round(fz.subj*1.5)
        if d.expanded
            P1_TxtWrapN(GR, d.cmdFull, d.contentX, cy, d.contentW, d.cmdMaxLines, "s" fz.cmd, co.body, W,H, F.mono)
        else if d.cmdLines = 2
            P1_TxtClip2(GR, d.cmd, d.contentX, cy, d.contentW, d.cmdLine2, "s" fz.cmd, co.body, W,H, F.mono)
        else
            P1_TxtClip(GR, d.cmd, d.contentX, cy, d.contentW, "s" fz.cmd " NoWrap", co.body, W,H, "", F.mono)

        ; Expand / Collapse affordance (Fix 4) — right-aligned, in its own slim row
        ; directly UNDER the command (proximity to what it acts on). Clickable (rect
        ; type:"expand") + Ctrl+Win+E. Shown only when truncated/expanded. Chevron via
        ; Chr() (matches the Chr(0x2026) ellipsis pattern — encoding-independent).
        if d.hasAfford {
            ; label = кремовый SemiBold, только стрелка — маджентой: сплошной
            ; тонкий magenta-текст на стене вибрировал (живой фидбек)
            chev := d.expanded ? Chr(0x25B4) : Chr(0x25BE)         ; ▴ collapse / ▾ expand
            aTxt := d.expanded ? "Collapse" : "Expand"
            aOpts := "s" fz.footer " NoWrap"                       ; NoWrap → chevron stays inline
            chevFz := fz.footer + S(3)                             ; стрелка крупнее подписи —
            cOpts := "s" chevFz " NoWrap"                          ; ей и достаётся акцент
            tW := Round(P1_TextW(GR, aTxt, aOpts, F.monoSemi, W, H))
            cW := Round(P1_TextW(GR, chev, cOpts, F.monoSemi, W, H))
            aW := tW + S(4) + cW
            aX := d.contentX + d.contentW - aW
            aTy := Round(d.affY + (d.affRowH - fz.footer) / 2)
            P1_Txt(GR, aTxt, aX, aTy, tW + S(4), aOpts, co.heading, W, H, "", F.monoSemi)
            P1_Txt(GR, chev, aX + tW + S(4), aTy - S(2), cW + S(4), cOpts, co.mag, W, H, "", F.monoSemi)
            card.rects.Push({x:aX - S(8), y:aTy - S(6), w:aW + S(16), h:fz.footer + S(12), type:"expand"})
        }

        ; --- actions ---
        if d.n = 0 {
            bx := d.contentX, bw := d.contentW
            P1_FillRR(GR, co.keyFill, bx, d.btnTop, bw, d.btnH, d.btnR)
            P1_StrokeRR(GR, co.keyRim, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
            pof := (pressed = "focus") ? S(2) : 0
            if pressed = "focus"
                P1_FillRR(GR, 0x22FFFFFF, bx, d.btnTop, bw, d.btnH, d.btnR)
            icx := bx + S(30), icy := d.btnTop + d.btnH // 2 + pof
            P1_Magnifier(GR, icx, icy, S(22), co.body)
            flabel := IsPanelHost(d.host) ? "Focus panel" : "Focus terminal"
            P1_Txt(GR, flabel, icx + S(22), d.btnTop + (d.btnH - fz.cmd)//2 - S(1) + pof, bw - S(70), "s" fz.cmd " NoWrap", co.body, W,H, "", F.sansSemi)
            card.rects.Push({x:bx, y:d.btnTop, w:bw, h:d.btnH, type:"focus"})
        } else {
            items := d.options
            nb := items.Length
            bw := (d.contentW - d.fbw - d.bgap - (nb-1)*d.bgap) // nb
            Loop nb {
                k := A_Index
                bx := d.contentX + (k-1)*(bw + d.bgap)
                ; keycaps on a solid plate (keyFill): digit 1 carries the action
                ; ink (magenta rim + digit), the rest are quiet cream rims.
                P1_FillRR(GR, co.keyFill, bx, d.btnTop, bw, d.btnH, d.btnR)
                if k = 1 {
                    P1_StrokeRR(GR, co.k1Rim, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
                    cD := co.k1Tx, cL := co.body
                } else {
                    P1_StrokeRR(GR, co.keyRim, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
                    cD := co.heading, cL := co.body
                }
                if k = pressed
                    P1_FillRR(GR, 0x22FFFFFF, bx, d.btnTop, bw, d.btnH, d.btnR)
                gapDL := Round(fz.digit*0.18)
                pof := (k = pressed) ? S(2) : 0
                bdy := d.btnTop + Round((d.btnH - (fz.digit+gapDL+fz.label))*0.40) + pof
                P1_Txt(GR, String(k), bx, bdy, bw, "s" fz.digit, cD, W,H, "Center", F.monoSemi)
                ; label semibold: 400 на тёмной плашке читался тонко (живой фидбек)
                P1_Txt(GR, items[k], bx, bdy+fz.digit+gapDL, bw, "s" fz.label " NoWrap", cL, W,H, "Center", F.sansSemi)
                card.rects.Push({x:bx, y:d.btnTop, w:bw, h:d.btnH, type:"press", idx:k})
            }
            fx := d.contentX + d.contentW - d.fbw
            P1_FillRR(GR, co.keyFill, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            P1_StrokeRR(GR, co.keyRim, 1, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            fpof := (pressed = "focus") ? S(2) : 0
            if pressed = "focus"
                P1_FillRR(GR, 0x22FFFFFF, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            P1_Magnifier(GR, fx + d.fbw//2, d.btnTop + d.btnH//2 + fpof, S(20), co.muted)
            card.rects.Push({x:fx, y:d.btnTop, w:d.fbw, h:d.btnH, type:"focus"})
        }

        ; --- footer row (every card reserves this space) ---
        fy := d.btnTop + d.btnH + d.footerGap
        ; NNV wordmark «press-1·»: Unbounded Black with the resting magenta ghost
        ; and a magenta registration dot — the card's single display-face element.
        ; Stable bottom-right signature that doesn't hop as the stack grows (Task 5).
        ; one shared optical centre for the whole footer row: wordmark, reg mark
        ; and hint sit on the SAME line (живой фидбек: хинт «висел» выше вордмарка)
        rowCY := fy + Round(fz.logo * 0.75)
        wmOpts := "s" fz.logo " NoWrap"
        wmW := Round(P1_TextW(GR, "press-1", wmOpts, F.disp, W, H))
        dotW := Round(P1_TextW(GR, "·", wmOpts, F.disp, W, H))
        wmX := d.contentX + d.contentW - wmW - dotW
        wmY := Round(rowCY - fz.logo * 0.7)
        P1_Txt(GR, "press-1", wmX + misOff, wmY + misOff, wmW + S(4), wmOpts, co.magGhost, W, H, "", F.disp)
        P1_Txt(GR, "press-1", wmX, wmY, wmW + S(4), wmOpts, co.heading, W, H, "", F.disp)
        ; the dot tucks in by S(3): GDI+ MeasureString pads each cell, and two
        ; padded cells side by side read as a detached dot otherwise
        P1_Txt(GR, "·", wmX + wmW - S(3), wmY, dotW + S(4), wmOpts, co.mag, W, H, "", F.disp)
        ; corner registration mark: prints magenta on the active card, fades on
        ; queued ones — the second half of the «активная = сведённая» signature.
        P1_RegMark(GR, d.cardX + S(18), rowCY, S(5)
            , card.active ? 0xD9E11B76 : 0x40DDD4BD, Max(1, S(1)))
        ; hotkey hint — on the ACTIVE card: digits answer the selected card, so
        ; the hint belongs where the answer goes (was slot 0 — рассинхрон с меткой
        ; приводки, живой фидбек «у верхней карточки нет строки»). Ctrl+Win+E is
        ; appended when the card can expand (the affordance itself lives in its
        ; own row directly under the command — see Fix 4 block above).
        if card.active {
            ; константная строка: суффикс «Ctrl+Win+E expand» убран — не влезал
            ; после укрупнения (живой фидбек), а кликабельный Expand и так виден
            hint := "click or Ctrl+Win+1 / 2 / 3   ·   Ctrl+Win+Esc to hide"
            ; clip to the wordmark's left edge — mono runs wider than the old
            ; Segoe hint and collided with «press-1·» on the expandable card
            hy := Round(rowCY - fz.footer * 0.68)
            P1_TxtClip(GR, hint, d.contentX, hy, wmX - misOff - d.contentX - S(10), "s" fz.footer " NoWrap", co.faint, W,H, "", F.monoSemi)
        }
    }

    ; WM_LBUTTONDOWN hit-test across cards. A click and a hotkey on the same
    ; button take the IDENTICAL OnButtonClick→DispatchByKind path (single source
    ; of truth for "never send a digit to the wrong window").
    static _OnLClick(wParam, lParam, msg, hwnd) {
        if this.cards.Length = 0
            return
        cx := lParam & 0xFFFF, cy := (lParam >> 16) & 0xFFFF
        for card in this.cards {
            if card.hwnd != hwnd || card.phase = "dead" || card.phase = "dismiss"
                continue
            for r in card.rects {
                if cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h {
                    if r.type = "close" {
                        this.DismissByUser()
                        return 0
                    }
                    if r.type = "expand" {
                        ; toggle THIS card's expansion (by key) and re-reconcile to
                        ; rebuild it at the new height. Never answers the prompt.
                        if this.expandedKeys.Has(card.key)
                            this.expandedKeys.Delete(card.key)
                        else
                            this.expandedKeys[card.key] := true
                        this._Reconcile()
                        return 0
                    }
                    pidx := 0
                    for i, info in this.promptData
                        if this._KeyOf(info) = card.key {
                            pidx := i
                            break
                        }
                    if pidx = 0
                        return 0                       ; card fading / not live → ignore
                    this._Press(card, (r.type = "focus") ? "focus" : r.idx)
                    if r.type = "focus"
                        this.OnButtonClick(pidx, 0)
                    else
                        this.OnButtonClick(pidx, r.idx)
                    return 0
                }
            }
        }
    }

    ; Mouse-local press feedback (flash + 2px sink). The card's dismissal comes
    ; from the teardown reconciler once the answered prompt clears the protocol.
    static _Press(card, which) {
        if card.phase != "idle"
            return
        this._DrawCard(card, which)
        P1_Present(card, card.x, card.ytar, this.peakAlpha)
        card.phase := "hold", card.dur := 120, card.t0 := A_TickCount
        this._ArmAnim()
    }

    ; True when the cursor is over a live card. Plain Esc is gated on this so it
    ; hides the popup only while you're pointing at it; otherwise Esc belongs to
    ; the focused app (e.g. cancels the prompt in the VS Code terminal).
    static _MouseOverPopup() {
        CoordMode("Mouse", "Screen")   ; card pos is screen coords; v2 default is Client
        MouseGetPos(&mx, &my)
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            rx := c.x + c.d.outerX, ry := c.ytar + c.d.outerY
            if mx >= rx && mx <= rx + c.d.outerW && my >= ry && my <= ry + c.d.outerH
                return true
        }
        return false
    }
}

; Global hotkey for closing popup (user-intent dismissal).
^#Escape::PromptPopup.DismissByUser()

; Plain Escape hides the popup ONLY while it's visible AND the cursor is over a
; card — so Esc reaches the focused app (e.g. cancels the prompt in the VS Code
; terminal, which then auto-clears the card) when you're not pointing at the
; popup. Ctrl+Win+Esc (above) always hides regardless. The popup is +NoActivate,
; so its own Escape handler never fires — these hotkeys fill that gap.
#HotIf PromptPopup.IsVisible() && PromptPopup._MouseOverPopup()
Escape::PromptPopup.DismissByUser()
#HotIf
#HotIf PromptPopup.IsVisible()
^#Up::PromptPopup.MoveSelection(-1)
^#Down::PromptPopup.MoveSelection(1)
^#e::PromptPopup.ToggleExpandActive()
#HotIf

; ---- Debug ----

DebugPending() {
    global PENDING_DIR, PROXY_DIR, PERM_DIR, P1_LAST_FOCUS_DIAGNOSTIC
    msg := "PENDING_DIR: " PENDING_DIR "`n"
    msg .= "DirExist pending: " (DirExist(PENDING_DIR) ? "YES" : "NO") "`n"

    ; Count pending files
    fileCount := 0
    try {
        Loop Files, PENDING_DIR "\*.json"
            fileCount++
    }
    msg .= "Pending files: " fileCount "`n"

    ; Experimental Codex proxy channel pendings — cheap visibility.
    proxyCount := 0
    try {
        Loop Files, PROXY_DIR "\*.json"
            if RegExMatch(A_LoopFileName, "\.pending\.json$")
                proxyCount++
    }
    msg .= "Proxy pending files: " proxyCount "`n"

    reviewerSummary := P1_CodexReviewerStatusSummary(
        PERM_DIR "\codex-reviewer-last.json", EpochMs())
    if reviewerSummary != ""
        msg .= reviewerSummary "`n"
    if P1_LAST_FOCUS_DIAGNOSTIC != ""
        msg .= P1_LAST_FOCUS_DIAGNOSTIC "`n"

    ; Show all prompts
    allPrompts := ReadAllPrompts()
    msg .= "Active prompts: " allPrompts.Length "`n"
    for p in allPrompts {
        opts := ""
        if p.options.Length > 0 {
            for o in p.options
                opts .= o ", "
        }
        kindLabel := p.HasOwnProp("kind") && p.kind != "" ? p.kind : "?"
        hostLabel := p.HasOwnProp("host") && p.host != "" ? p.host : "?"
        msg .= "  <" kindLabel "/" hostLabel "> " p.project_name ": " p.tool_name
        if p.tool_input_short != ""
            msg .= "(" p.tool_input_short ")"
        if opts != ""
            msg .= " [" opts "]"
        if p.terminal_index >= 0
            msg .= " pane:" p.terminal_index
        msg .= "`n"
    }

    ; List editor windows (VS Code / Cursor / Windsurf)
    msg .= "--- Editor windows ---`n"
    try {
        wins := EditorWindowList()
        for hwnd in wins {
            try {
                title := WinGetTitle(hwnd)
                if title != ""
                    msg .= SubStr(title, 1, 70) "`n"
            }
        }
    }

    ToolTip(msg)
    SetTimer(() => ToolTip(), -15000)
}

; ---- Auto-show popup when a hook pending appears ----

AutoShowCheck() {
    global POPUP_MIN_PROMPTS
    if PromptPopup.IsVisible()
        return
    ; ReadAllPrompts = live hook pendings (editor terminals B, panel C,
    ; standalone A). No phantom gate needed: S1 proved the hook fires only on
    ; real prompts, and rows are filtered to the hook's live wait window.
    allPrompts := ReadAllPrompts()
    if allPrompts.Length < POPUP_MIN_PROMPTS
        return
    ; Respect dismissal: if the user explicitly closed the popup and every live
    ; prompt still belongs to the dismissed set, don't re-open — otherwise
    ; Ctrl+Win+Esc "flickers" (close → AutoShowCheck → re-open 500ms later).
    ; SUBSET, not exact-set (CX6): pass-released decision rows die right after
    ; the dismissal, and the shrunken set used to LOOK new and re-open the popup
    ; with the surviving native rows. A genuinely NEW prompt id re-opens.
    if PromptPopup.AllDismissed(allPrompts)
        return
    PromptPopup.Show(allPrompts)
    ; NOTE: don't auto-hide here — popup's own Refresh() (200ms) handles hiding
    ; based on ReadAllPrompts() returning empty. AutoShowCheck only triggers SHOW.
}

; Check for new prompts every 500ms (lighter than popup's 200ms refresh)
SetTimer(AutoShowCheck, 500)

; ---- Tray menu ----

muteFlag := EnvGet("USERPROFILE") "\.press-1-mute"   ; persistent mute pref; the hook reads the same path

; Resolve persisted physical-display choices before the first popup can appear.
; No file = dynamic Windows primary. Both calls are fail-safe and return arrays.
P1_POPUP_DISPLAY_PREFS := P1_ReadPopupDisplayPrefs(P1_POPUP_DISPLAY_PREFS_PATH)
P1_DISPLAY_CATALOG := P1_GetDisplayCatalog()

; Per-agent kill switches — flag-file existence = press-1 OFF for that agent (the
; agent's hook reads the same path and gets out of the way: native prompt, no
; popup/sound). The "Active for" submenu below toggles them. Checkmark = ENABLED
; (flag ABSENT) — inverse of the mute item. Default: both enabled (no flags).
offClaudeFlag := EnvGet("USERPROFILE") "\.press-1-off-claude"
offCodexFlag := EnvGet("USERPROFILE") "\.press-1-off-codex"
; Legacy filename retained so an existing opt-out survives the scope expansion
; from Desktop-only to every standard Codex hook surface.
offCodexAutoReviewFlag := EnvGet("USERPROFILE") "\.press-1-off-codex-desktop-auto-review"
agentMenu := Menu()
agentMenu.Add("Claude Code", ToggleAgentClaude)
agentMenu.Add("Codex", ToggleAgentCodex)
if P1_AgentChecked(FileExist(offClaudeFlag))
    agentMenu.Check("Claude Code")
if P1_AgentChecked(FileExist(offCodexFlag))
    agentMenu.Check("Codex")

; Guarded rollout-based reviewer detection is positive UX but experimental:
; checked means "let exact auto_review decide" on every non-proxy hook route
; (default); the backing file is an opt-OUT so upgrades preserve preferences.
codexAutoReviewItem := "Let Auto-review decide (experimental)"
codexMenu := Menu()
codexMenu.Add(codexAutoReviewItem, ToggleCodexAutoReview)
if P1_AgentChecked(FileExist(offCodexAutoReviewFlag))
    codexMenu.Check(codexAutoReviewItem)

A_TrayMenu.Delete()
A_TrayMenu.Add("Show Popup", (*) => PromptPopup.Show(ReadAllPrompts()))
try P1_RebuildDisplayMenu(false)
catch as e {
    ToolTip("press-1: display menu unavailable — popup will use Windows primary")
    SetTimer((*) => ToolTip(), -6000)
}
A_TrayMenu.Add("Active for", agentMenu)
A_TrayMenu.Add("Codex", codexMenu)
A_TrayMenu.Add("Mute prompt sound", ToggleMute)
if FileExist(muteFlag)
    A_TrayMenu.Check("Mute prompt sound")
A_TrayMenu.Add("Exit", (*) => ExitApp())

; Display changes can fire in bursts while Windows applies a new topology/DPI.
; Debounce before reading it and rebuilding physical-pixel popup windows.
OnMessage(0x007E, P1_OnDisplayChange)  ; WM_DISPLAYCHANGE

; Custom tray icon — deployed next to this script (~\scripts\press-1.ico).
; A_LineFile-relative so it resolves in the repo, in the deployed copy, and from
; the tests/ harness alike; guarded so a missing file just keeps the default icon.
trayIcon := A_LineFile "\..\press-1.ico"
if FileExist(trayIcon)
    TraySetIcon(trayIcon)
A_IconTip := "press-1 v8.1"

; Toggle the persistent mute flag-file the hook checks before playing its sound.
; Existence = muted. One-click alternative to the PRESS1_NO_SOUND env var.
ToggleMute(*) {
    global muteFlag
    if FileExist(muteFlag) {
        FileDelete muteFlag
        A_TrayMenu.Uncheck("Mute prompt sound")
    } else {
        FileAppend "", muteFlag
        A_TrayMenu.Check("Mute prompt sound")
    }
}

; Per-agent toggles. INVERSE checkmark vs mute: flag present (currently OFF) →
; delete + check (now ENABLED); flag absent (currently ON) → create + uncheck
; (now DISABLED = press-1 stays out of the way; the agent shows its native prompt).
ToggleAgentClaude(*) {
    global agentMenu, offClaudeFlag
    ToggleAgentFlag(agentMenu, "Claude Code", offClaudeFlag)
}
ToggleAgentCodex(*) {
    global agentMenu, offCodexFlag
    ToggleAgentFlag(agentMenu, "Codex", offCodexFlag)
}
ToggleCodexAutoReview(*) {
    global codexMenu, codexAutoReviewItem, offCodexAutoReviewFlag
    ToggleAgentFlag(codexMenu, codexAutoReviewItem, offCodexAutoReviewFlag)
}
ToggleAgentFlag(menu, item, flag) {
    if FileExist(flag) {
        FileDelete flag
        menu.Check(item)
    } else {
        FileAppend "", flag
        menu.Uncheck(item)
    }
}

P1_RebuildDisplayMenu(replaceExisting := true) {
    global P1_DISPLAY_MENU, P1_DISPLAY_MENU_IDS, P1_DISPLAY_CATALOG
        , P1_POPUP_DISPLAY_PREFS
    subMenu := Menu(), ids := Map()
    primaryItem := "Windows primary (default)"
    subMenu.Add(primaryItem, (*) => P1_SelectPrimaryDisplay())
    if P1_POPUP_DISPLAY_PREFS.Length = 0
        subMenu.Check(primaryItem)
    if P1_DISPLAY_CATALOG.Length > 0
        subMenu.Add()

    selected := Map()
    for pref in P1_POPUP_DISPLAY_PREFS
        selected[pref.id] := true
    connected := Map()
    for ordinal, display in P1_DISPLAY_CATALOG {
        label := P1_DisplayLabel(display, ordinal)
        ids[label] := display.id
        connected[display.id] := true
        subMenu.Add(label, (itemName, itemPos, myMenu) => P1_TogglePopupDisplay(itemName, itemPos, myMenu))
        if selected.Has(display.id)
            subMenu.Check(label)
    }
    missingOrdinal := 0
    for pref in P1_POPUP_DISPLAY_PREFS {
        if connected.Has(pref.id)
            continue
        missingOrdinal++
        label := "Not connected · " (pref.label != "" ? pref.label : "Unknown display")
        if missingOrdinal > 1
            label .= " · " missingOrdinal
        ids[label] := pref.id
        subMenu.Add(label, (itemName, itemPos, myMenu) => P1_TogglePopupDisplay(itemName, itemPos, myMenu))
        subMenu.Check(label)
    }

    P1_DISPLAY_MENU := subMenu
    P1_DISPLAY_MENU_IDS := ids
    if replaceExisting {
        try A_TrayMenu.Delete("Exit")
        try A_TrayMenu.Delete("Popup displays")
        A_TrayMenu.Add("Popup displays", subMenu)
        A_TrayMenu.Add("Exit", (*) => ExitApp())
    } else {
        A_TrayMenu.Add("Popup displays", subMenu)
    }
}

P1_SelectPrimaryDisplay(*) {
    global P1_POPUP_DISPLAY_PREFS, P1_POPUP_DISPLAY_PREFS_PATH
    P1_POPUP_DISPLAY_PREFS := []
    P1_WritePopupDisplayPrefs(P1_POPUP_DISPLAY_PREFS_PATH, P1_POPUP_DISPLAY_PREFS)
    P1_RebuildDisplayMenu()
    PromptPopup.ReloadDisplays()
}

P1_TogglePopupDisplay(itemName, itemPos, menu) {
    global P1_DISPLAY_MENU_IDS, P1_POPUP_DISPLAY_PREFS, P1_DISPLAY_CATALOG
        , P1_POPUP_DISPLAY_PREFS_PATH
    if !P1_DISPLAY_MENU_IDS.Has(itemName)
        return
    id := P1_DISPLAY_MENU_IDS[itemName]
    next := [], removed := false
    for pref in P1_POPUP_DISPLAY_PREFS {
        if pref.id = id
            removed := true
        else
            next.Push(pref)
    }
    if !removed {
        label := ""
        for display in P1_DISPLAY_CATALOG
            if display.id = id {
                label := display.name
                break
            }
        next.Push({id:id, label:label})
    }
    ; Zero explicit displays is represented by no file and means dynamic primary.
    P1_POPUP_DISPLAY_PREFS := next
    P1_WritePopupDisplayPrefs(P1_POPUP_DISPLAY_PREFS_PATH, next)
    P1_RebuildDisplayMenu()
    PromptPopup.ReloadDisplays()
}

P1_OnDisplayChange(*) {
    global P1_DISPLAY_CHANGE_FN
    if P1_DISPLAY_CHANGE_FN
        SetTimer(P1_DISPLAY_CHANGE_FN, 0)
    P1_DISPLAY_CHANGE_FN := (*) => P1_RefreshDisplays()
    SetTimer(P1_DISPLAY_CHANGE_FN, -350)
}

P1_RefreshDisplays(*) {
    global P1_DISPLAY_CATALOG, P1_DISPLAY_CHANGE_FN
    P1_DISPLAY_CHANGE_FN := ""
    P1_DISPLAY_CATALOG := P1_GetDisplayCatalog()
    P1_RebuildDisplayMenu()
    PromptPopup.ReloadDisplays()
}
