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
        badge := promptInfo.host = "vscode-extension" ? "panel"
            : promptInfo.host = "windows-terminal" ? "WT"
            : promptInfo.host = "conhost" ? "console" : ""
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
;                hook (editor terminal B, panel C, standalone A — every host is
;                on the hook-decision channel, S8/S10). Focus never moves, no
;                synthetic keyboard; Claude Code core applies the hook decision.
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

FocusPrompt(promptInfo) {
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
    ; Editor focus (panel C, editor-terminal B pickers): gentle activation —
    ; single WinActivate, no Alt-dance, no escalation — so the 🔍/Focus button
    ; can't start a focus war across many open editor windows. The Ctrl+Alt+F10
    ; chord (claude-vscode.focus) used to follow here but WAS the focus-war
    ; driver for AskUserQuestion — confirmed by trace 2026-06-14: it bounced
    ; focus between panes, and repeated 🔍 clicks raced it past stopping.
    ; WinActivate alone surfaces the window; answer in the editor.
    ; Prefer the editor the hook captured (editor_exe) so a Cursor/Devin prompt
    ; focuses that editor, not a VS Code window sharing the project name.
    editorExe := promptInfo.HasOwnProp("editor_exe") ? promptInfo.editor_exe : ""
    FocusWorkspace(promptInfo.project_name, true, editorExe)
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

    global STANDALONE_BACKSTOP_MS
    nowMs := EpochMs()
    ; FIFO: ReadAllPending sorts newest-first (legacy LIFO consumers like
    ; ReadNewestPending), but popup rows queue oldest-first — [A] is the prompt
    ; that has waited longest, new arrivals join the bottom (until v5.2 panel
    ; rows were inconsistent and the first hotkey answered the NEWEST prompt).
    allPending := ReadAllPending()
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
        if pi.hook_pid && HookPidStale(pi.hook_pid, pi.timestamp)
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
            if pi.kind = "permission" && pi.decision_file != "" {
                ; The pending lives exactly as long as the hook waits for a
                ; decision (the hook deletes it on exit), so file presence ≈
                ; still answerable; wait_until is the cutoff for a crashed
                ; hook's orphan file.
                if pi.wait_until && nowMs > pi.wait_until + 2000
                    continue
                result.Push({
                    project_name: pi.project_name,
                    workspace_path: "",
                    tool_name: pi.tool_name,
                    tool_input_short: pi.tool_input_short,
                    terminal_index: -1,
                    terminal_name: "",
                    prompt_id: pi.id,
                    decision_file: pi.decision_file,
                    pending_file: pi.file_path,
                    host: pi.host_type,
                    editor_exe: pi.editor_exe,
                    ; v5.2: render the box's REAL layout from the hook's options
                    ; hint — 2-option boxes ("1 Yes / 2 No") exist here too, and
                    ; showing 3 buttons would miscommunicate digit 2.
                    options: pi.options.Length > 0 ? pi.options : ["Allow", "Always allow", "Deny"],
                    kind: "permission",
                    detected_at: pi.timestamp,
                })
            } else if pi.kind != "" && pi.kind != "permission" {
                ; Attention-only row (picker — AskUserQuestion / ExitPlanMode):
                ; a hook decision can't answer these; user answers in the editor.
                ; Teardown removes the pending when answered; the long cap is
                ; only the crash backstop, so unanswered questions stay visible.
                if pi.timestamp && nowMs - pi.timestamp > STANDALONE_BACKSTOP_MS
                    continue
                result.Push({
                    project_name: pi.project_name,
                    workspace_path: "",
                    tool_name: pi.tool_name,
                    tool_input_short: pi.tool_input_short,
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
            if pi.kind = "permission" && pi.wait_until && nowMs > pi.wait_until + 2000
                continue
            rowKind := pi.kind != "" ? pi.kind : "permission"
            ; Missing options hint (pre-v5.2 hook) → assume 3-option layout:
            ; its worst mismatch is Deny instead of Always allow (safe); the
            ; 2-option default could turn Deny into Always allow (never).
            opts := pi.options.Length > 0 ? pi.options : ["Allow", "Always allow", "Deny"]
            result.Push({
                project_name: pi.project_name,
                workspace_path: "",
                tool_name: pi.tool_name,
                tool_input_short: pi.tool_input_short,
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
                options: rowKind = "permission" ? opts : [],
                kind: rowKind,
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

        entry := {id: "", project_name: "", tool_name: "", tool_input_short: "", file_path: f.path,
            host_type: "", kind: "", decision_file: "", wait_until: 0, timestamp: 0,
            hook_pid: 0, hwnd: 0, top_level_pid: 0, top_level_exe: "", editor_exe: "",
            options: [], ancestry_pids: []}
        if RegExMatch(raw, JsonStrPattern("id"), &m)
            entry.id := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("project_name"), &m)
            entry.project_name := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("tool_name"), &m)
            entry.tool_name := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("tool_input_short"), &m)
            entry.tool_input_short := JsonUnescape(m[1])
        ; v3 panel fields (scenario C). host.type is nested — anchor the search
        ; at the "host" object so a literal "type" inside tool_input_short
        ; can't shadow it.
        if RegExMatch(raw, JsonStrPattern("kind"), &m)
            entry.kind := JsonUnescape(m[1])
        if RegExMatch(raw, JsonStrPattern("decision_file"), &m)
            entry.decision_file := JsonUnescape(m[1])
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
    return result
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

; Find an editor window for a workspace by title (fuzzy: hyphens ↔ spaces).
; Prefers a specific editor exe (Code.exe / Cursor.exe / Devin.exe) when the hook
; captured one in editor_exe — so a Cursor/Devin prompt focuses that editor, not
; a VS Code window that happens to share the project name. Falls back to the full
; cross-editor list when no exe is given or the preferred exe has no match.
FindEditorByName(projectName, editorExe := "") {
    variants := BuildNameVariants(projectName)
    if editorExe != "" {
        try {
            for hwnd in WinGetList("ahk_exe " editorExe) {
                title := ""
                try title := WinGetTitle(hwnd)
                for variant in variants {
                    if InStr(title, variant)
                        return hwnd
                }
            }
        }
    }
    return FindVSCodeByName(projectName)
}

FindVSCodeByName(projectName) {
    wins := EditorWindowList()
    variants := BuildNameVariants(projectName)

    for hwnd in wins {
        try {
            title := WinGetTitle(hwnd)
            if !IsEditorTitle(title)
                continue
            for variant in variants {
                if InStr(title, variant)
                    return hwnd
            }
        }
    }
    return 0
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
FocusWorkspace(projectName, gentle := false, editorExe := "") {
    hwnd := FindEditorByName(projectName, editorExe)
    if !hwnd {
        SoundPlay "*48"
        return false
    }
    ActivateHwnd(hwnd, gentle)
    return true
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
    UpdateLayeredWindow(card.hwnd, card.hdc, Round(x), Round(y), card.w, card.h, alpha)
}

P1_HostBadge(host) =>
    host = "windows-terminal" ? "WT"
    : host = "conhost" ? "console"
    : host = "vscode-extension" ? "panel" : ""

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

    ; --- v6 GDI+ renderer (BACKLOG 11) ---
    static monitorIndex := 1      ; monitor the gdip stack renders on (1 = primary; our default)
    static peakAlpha := 240       ; resting popup opacity (0-255); <255 = slight translucency
    static cards := []            ; live GDI+ card objects (includes fading ones)
    static _gdipToken := 0        ; lazy Gdip_Startup token; 0 = not started / failed
    static _gdipReady := false    ; one-time init guard (token + OnMessage + OnExit)
    static _animFn := ""          ; bound 16ms _AnimStep timer (self-arming)
    static _measGR := 0           ; scratch graphics for text measurement pre-DIB
    static _measHdc := 0
    static _measHbm := 0
    static _measObm := 0
    static _gdipBeeped := false   ; fail-loud error beep fired once per session
    static _gdipFailSig := ""     ; prompt-set signature already fail-loud'd (anti-respam)

    static IsVisible() {
        return this.visible
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
    }

    ; Explicit user dismissal (Escape / tray close). Records current signature
    ; so AutoShowCheck won't re-open the exact same set — but a new detected_at
    ; from any subsequent prompt registration busts the suppression.
    ; Decision rows (panel AND standalone since v5.4) get an early-release
    ; "pass": dismissing the popup means "I'll answer in the window myself",
    ; so release the waiting hook right away instead of letting it burn the
    ; rest of its bounded wait. The prompt itself keeps waiting in its UI.
    static DismissByUser() {
        if this.visible {
            this.dismissedSignature := this.ComputeSignature(this.promptData)
            for p in this.promptData {
                if p.HasOwnProp("decision_file") && p.decision_file != ""
                    WriteHookDecision(p, "pass", true)
            }
        }
        this.Hide()
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

    static _FindCard(key) {
        for c in this.cards
            if c.key = key && c.phase != "dead" && c.phase != "dismiss"
                return c
        return ""
    }

    static _SyncCards() {
        this._Reconcile()
    }

    ; Key-based reconciliation (drives both Show and Refresh): fade gone prompts,
    ; add new ones, redraw changed ones in place, re-slot survivors, and remap the
    ; active selection by key. Never rebuilds the whole stack.
    static _Reconcile() {
        prompts := this.promptData
        selKey := (this.selectedIndex >= 1 && this.selectedIndex <= prompts.Length)
            ? this._KeyOf(prompts[this.selectedIndex]) : ""

        liveKeys := Map()
        for info in prompts
            liveKeys[this._KeyOf(info)] := true

        ; fade cards whose prompt vanished from the protocol (answered/dead hook)
        for c in this.cards {
            if c.phase = "dead" || c.phase = "dismiss"
                continue
            if !liveKeys.Has(c.key)
                this._StartDismiss(c)
        }

        ; add / update live prompts; newest (last) = slot 0 = bottom, oldest on top
        n := prompts.Length
        for i, info in prompts {
            key := this._KeyOf(info)
            slot := n - i
            existing := this._FindCard(key)
            if existing {
                if this._RenderFieldsDiffer(existing.info, info) {
                    existing.info := info
                    this._SetCardContent(existing, info)
                    existing.dirty := true
                } else {
                    existing.info := info
                }
                if existing.slot != slot {
                    existing.slot := slot
                    this._Reslot(existing)
                }
            } else {
                card := this._BuildCard(info, slot)
                this.cards.Push(card)
                this._StartAppear(card)
            }
        }

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

    ; Slot changed (a card above was answered) → slide to the new target.
    static _Reslot(card) {
        oldY := card.ytar
        card.ytar := card.baseY - card.slot * card.step
        if card.phase = "idle" && oldY != card.ytar {
            card.fromY := oldY
            card.phase := "reflow", card.dur := 200, card.t0 := A_TickCount
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
        d.host := info.HasOwnProp("host") ? info.host : ""
    }

    ; Build one layered card window on the PRIMARY monitor (user choice: stack
    ; stays on primary; other-monitor prompts answered via F16-F21).
    static _BuildCard(info, slot) {
        MonitorGetWorkArea(this.monitorIndex, &wl, &wt, &wr, &wb)
        sc := Min(1.30, Max(0.62, (wr - wl) / 2560))
        fsc := Min(1.0, 0.64 + 0.40 * sc)
        S := (px) => Round(px * sc)
        FS := (px) => Round(px * fsc)

        W := S(640), M := S(34)
        outerX := M, outerY := S(26), outerW := W - 2*M
        outerR := S(22), bezel := S(6)
        cardX := outerX + bezel, cardY := outerY + bezel
        cardW := outerW - 2*bezel, cardR := outerR - bezel
        cpad := S(28), contentX := cardX + cpad, contentW := cardW - 2*cpad
        fz := { logo:S(16), subj:FS(21), cmd:FS(16), digit:FS(24), label:FS(14), footer:FS(11) }

        ; Command line(s): measure how many lines the command needs at the content
        ; width so the card height GROWS for a long command (wraps to a 2nd line)
        ; instead of clipping to one line (E). Capped at 2 — line 2 ellipsizes.
        kind0 := (info.HasOwnProp("kind") && info.kind != "") ? info.kind : "permission"
        cmdLines := this._CmdLines(this._ComposeCmd(info, kind0), contentW, "s" fz.cmd " NoWrap", "Segoe UI Semibold")
        cmdLine2 := Round(fz.cmd * 1.25)        ; baseline offset of the 2nd line

        ; header: top pad + project-name line (hero) + command line(s). The old
        ; eyebrow line (NEEDS ATTENTION / PERMISSION REQUEST) is gone in v6 — the
        ; project name is the title, the host moves into a small leading pill, and
        ; the prompt kind already reads from the buttons (digits vs Focus).
        headerBottom := S(22) + Round(fz.subj*1.5) + Round(fz.cmd*1.35) + (cmdLines = 2 ? cmdLine2 : 0)
        blockH := fz.digit + Round(fz.digit*0.18) + fz.label
        btnH := blockH + FS(18)
        gapHB := S(20), footerGap := S(14), botPad := S(16)
        cardH := headerBottom + gapHB + btnH + footerGap + fz.footer + botPad
        outerH := cardH + 2*bezel
        H := outerY + outerH + S(34)
        btnR := S(14), bgap := S(14), fbw := S(50)
        btnTop := cardY + headerBottom + gapHB

        co := { shell:0xF00F172A, shellRim:0x1A00D97E, card:0xF51E293B, cardRim:0x14FFFFFF
              , heading:0xFFF0FCFF, body:0xFFE0E4E6, muted:0xFF94A3B8, faint:0xFF6B7689
              , tintTop:0x2620C480, tintBot:0x1A20C480, tintBd:0x5520C480, tintTx:0xFF45D399
              , neuTop:0xFF343F4E, neuBot:0xFF2E3744, neuRim:0x12FFFFFF, shadow:0x04080C14
              , ring:0xCC8AB4F8 }                ; active-card ring = accent blue, dimmed alpha (was 0xFF — read as a dense frame at full alpha)

        g := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x80000 +E0x08000000 +OwnDialogs")
        hbm := CreateDIBSection(W, H), hdc := CreateCompatibleDC()
        obm := SelectObject(hdc, hbm), GR := Gdip_GraphicsFromHDC(hdc)
        Gdip_SetSmoothingMode(GR, 4), Gdip_SetTextRenderingHint(GR, 4)

        x := wr - S(24) - (outerX + outerW)
        step := outerH + S(8)
        baseY := wb - S(8) - (outerY + outerH)
        ytar := baseY - slot * step

        card := { gui:g, hwnd:g.Hwnd, hdc:hdc, hbm:hbm, obm:obm, G:GR, w:W, h:H
                , x:x, ytar:ytar, fromY:ytar, baseY:baseY, step:step, slide:S(8), slide2:S(8)
                , phase:"idle", t0:0, dur:0, rects:[]
                , key:this._KeyOf(info), info:info, slot:slot, active:false, dirty:false
                , d:{ sc:sc, S:S, W:W, H:H, outerX:outerX, outerY:outerY, outerW:outerW, outerH:outerH, outerR:outerR
                    , cardX:cardX, cardY:cardY, cardW:cardW, cardH:cardH, cardR:cardR
                    , contentX:contentX, contentW:contentW, contentR:contentX+contentW
                    , btnTop:btnTop, btnH:btnH, btnR:btnR, bgap:bgap, fbw:fbw, footerGap:footerGap
                    , fz:fz, font:"Segoe UI", co:co
                    , cmdLines:cmdLines, cmdLine2:cmdLine2
                    , subj:"", cmd:"", n:0, host:"", kind:"permission", options:[] } }
        this._SetCardContent(card, info)

        g.Show("NoActivate x" x " y" Round(ytar + card.slide) " w" W " h" H)
        this._DrawCard(card, "")
        P1_Present(card, x, ytar + card.slide, 0)
        return card
    }

    static _DrawCard(card, pressed := "") {
        d := card.d, GR := card.G, co := d.co, fz := d.fz, font := d.font
        W := d.W, H := d.H, sc := d.sc, S := d.S
        card.rects := []

        Gdip_GraphicsClear(GR, 0x00000000)

        Loop 6 {
            ex := A_Index * 1.0 * sc
            P1_FillRR(GR, co.shadow, d.outerX-ex, d.outerY-ex+S(5), d.outerW+2*ex, d.outerH+2*ex, d.outerR+ex)
        }
        P1_FillRR(GR, co.shell, d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        if card.active
            P1_StrokeRR(GR, co.ring, S(2), d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        else
            P1_StrokeRR(GR, co.shellRim, 1, d.outerX, d.outerY, d.outerW, d.outerH, d.outerR)
        P1_FillRR(GR, co.card, d.cardX, d.cardY, d.cardW, d.cardH, d.cardR)
        P1_StrokeRR(GR, co.cardRim, 1, d.cardX, d.cardY, d.cardW, d.cardH, d.cardR)

        ; --- header ---
        ; Top line: project name as the title (hero). Right corner: the close ✕
        ; (the "press-1" wordmark moved to a quiet bottom-right corner on every
        ; card — see the footer row). Second line: the command / question.
        ; The host badge (panel/WT/console) used to sit in a leading pill here but
        ; read as near-constant noise for a panel-first user ("panel" every time);
        ; it now only labels the Focus button below — badge is still resolved for it.
        badge := P1_HostBadge(d.host)
        ty := d.cardY + S(22)                    ; project-name (title) line top
        nameCY := ty + fz.subj / 2               ; its vertical center — corner items align here

        ; right corner: just the ✕ close (wordmark lives in the footer row now).
        xc := d.contentR - S(5)
        P1_CloseIcon(GR, xc, nameCY, S(11), co.faint)
        card.rects.Push({x:xc - S(15), y:Round(nameCY) - S(15), w:S(30), h:S(30), type:"close"})
        rightEdge := xc - S(13)                  ; project title runs up to just before the ✕

        ; project name (title) — full left width up to the ✕
        P1_TxtClip(GR, d.subj, d.contentX, ty, rightEdge - d.contentX, "Bold s" fz.subj " NoWrap", co.heading, W,H, "", font)

        ; command / question line
        cy := ty + Round(fz.subj*1.5)
        if d.cmdLines = 2
            P1_TxtClip2(GR, d.cmd, d.contentX, cy, d.contentW, d.cmdLine2, "s" fz.cmd, co.body, W,H, "Segoe UI Semibold")
        else
            P1_TxtClip(GR, d.cmd, d.contentX, cy, d.contentW, "s" fz.cmd " NoWrap", co.body, W,H, "", "Segoe UI Semibold")

        ; --- actions ---
        if d.n = 0 {
            bx := d.contentX, bw := d.contentW
            P1_FillRRGrad(GR, co.neuTop, co.neuBot, bx, d.btnTop, bw, d.btnH, d.btnR)
            P1_StrokeRR(GR, co.neuRim, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
            pof := (pressed = "focus") ? S(2) : 0
            if pressed = "focus"
                P1_FillRR(GR, 0x22FFFFFF, bx, d.btnTop, bw, d.btnH, d.btnR)
            icx := bx + S(30), icy := d.btnTop + d.btnH // 2 + pof
            P1_Magnifier(GR, icx, icy, S(22), co.body)
            flabel := badge = "panel" ? "Focus panel" : "Focus terminal"
            P1_Txt(GR, flabel, icx + S(22), d.btnTop + (d.btnH - fz.cmd)//2 - S(1) + pof, bw - S(70), "s" fz.cmd " NoWrap", co.body, W,H, "", "Segoe UI Semibold")
            card.rects.Push({x:bx, y:d.btnTop, w:bw, h:d.btnH, type:"focus"})
        } else {
            items := d.options
            nb := items.Length
            bw := (d.contentW - d.fbw - d.bgap - (nb-1)*d.bgap) // nb
            Loop nb {
                k := A_Index
                bx := d.contentX + (k-1)*(bw + d.bgap)
                if k = 1 {
                    P1_FillRRGrad(GR, co.tintTop, co.tintBot, bx, d.btnTop, bw, d.btnH, d.btnR)
                    P1_StrokeRR(GR, co.tintBd, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
                    cD := co.tintTx, cL := co.tintTx
                } else {
                    P1_FillRRGrad(GR, co.neuTop, co.neuBot, bx, d.btnTop, bw, d.btnH, d.btnR)
                    P1_StrokeRR(GR, co.neuRim, 1, bx, d.btnTop, bw, d.btnH, d.btnR)
                    cD := co.body, cL := co.muted
                }
                if k = pressed
                    P1_FillRR(GR, 0x22FFFFFF, bx, d.btnTop, bw, d.btnH, d.btnR)
                gapDL := Round(fz.digit*0.18)
                pof := (k = pressed) ? S(2) : 0
                bdy := d.btnTop + Round((d.btnH - (fz.digit+gapDL+fz.label))*0.40) + pof
                P1_Txt(GR, String(k), bx, bdy, bw, "Bold s" fz.digit, cD, W,H, "Center", font)
                P1_Txt(GR, items[k], bx, bdy+fz.digit+gapDL, bw, "s" fz.label " NoWrap", cL, W,H, "Center", "Segoe UI Semibold")
                card.rects.Push({x:bx, y:d.btnTop, w:bw, h:d.btnH, type:"press", idx:k})
            }
            fx := d.contentX + d.contentW - d.fbw
            P1_FillRRGrad(GR, co.neuTop, co.neuBot, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            P1_StrokeRR(GR, co.neuRim, 1, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            fpof := (pressed = "focus") ? S(2) : 0
            if pressed = "focus"
                P1_FillRR(GR, 0x22FFFFFF, fx, d.btnTop, d.fbw, d.btnH, d.btnR)
            P1_Magnifier(GR, fx + d.fbw//2, d.btnTop + d.btnH//2 + fpof, S(20), co.muted)
            card.rects.Push({x:fx, y:d.btnTop, w:d.fbw, h:d.btnH, type:"focus"})
        }

        ; --- footer row (every card reserves this space) ---
        fy := d.btnTop + d.btnH + d.footerGap
        ; quiet 'press-1' wordmark, bottom-right of every card — a stable signature
        ; that doesn't hop as the newest-at-bottom stack grows/shrinks (Task 5).
        mW := P1_TextW(GR, "press-1", "s" fz.logo, font, W, H)
        P1_Txt(GR, "press-1", d.contentX + d.contentW - mW, Round(fy + fz.footer/2 - fz.logo/2), mW + S(4)
            , "s" fz.logo, co.muted, W, H, "", font)
        ; hotkey hint — only on the front card (slot 0)
        if card.slot = 0
            P1_Txt(GR, "click or Ctrl+Win+1 / 2 / 3   ·   Ctrl+Win+Esc to hide", d.contentX, fy, d.contentW, "s" fz.footer, co.faint, W,H, "", font)
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
#HotIf

; ---- Debug ----

DebugPending() {
    global PENDING_DIR
    msg := "PENDING_DIR: " PENDING_DIR "`n"
    msg .= "DirExist pending: " (DirExist(PENDING_DIR) ? "YES" : "NO") "`n"

    ; Count pending files
    fileCount := 0
    try {
        Loop Files, PENDING_DIR "\*.json"
            fileCount++
    }
    msg .= "Pending files: " fileCount "`n"

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
    ; Respect dismissal: if the user explicitly closed the popup and the exact
    ; same prompt set is still active, don't re-open — otherwise Ctrl+Win+Esc
    ; "flickers" (close → AutoShowCheck → re-open 500ms later, repeat).
    ; When any prompt is added or removed, signature changes and popup re-opens.
    currentSig := PromptPopup.ComputeSignature(allPrompts)
    if currentSig == PromptPopup.dismissedSignature
        return
    PromptPopup.Show(allPrompts)
    ; NOTE: don't auto-hide here — popup's own Refresh() (200ms) handles hiding
    ; based on ReadAllPrompts() returning empty. AutoShowCheck only triggers SHOW.
}

; Check for new prompts every 500ms (lighter than popup's 200ms refresh)
SetTimer(AutoShowCheck, 500)

; ---- Tray menu ----

muteFlag := EnvGet("USERPROFILE") "\.press-1-mute"   ; persistent mute pref; the hook reads the same path
A_TrayMenu.Delete()
A_TrayMenu.Add("Show Popup", (*) => PromptPopup.Show(ReadAllPrompts()))
A_TrayMenu.Add("Mute prompt sound", ToggleMute)
if FileExist(muteFlag)
    A_TrayMenu.Check("Mute prompt sound")
A_TrayMenu.Add("Exit", (*) => ExitApp())

; Custom tray icon — deployed next to this script (~\scripts\press-1.ico).
; A_LineFile-relative so it resolves in the repo, in the deployed copy, and from
; the tests/ harness alike; guarded so a missing file just keeps the default icon.
trayIcon := A_LineFile "\..\press-1.ico"
if FileExist(trayIcon)
    TraySetIcon(trayIcon)
A_IconTip := "press-1 v6.0"

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
