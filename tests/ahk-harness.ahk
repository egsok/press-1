; AHK tests: editor-terminal (B) + standalone (A) + panel (C) rows carry
; decision_file, wait_until cutoff, liveness gate, editor_exe for picker focus,
; DecisionWordForKey + WriteHookDecision regression, FIFO.
; Includes the real script, then redirects its dirs to an isolated sandbox.
; Run: AutoHotkey64.exe tests\ahk-harness.ahk → results in %TEMP%\press-1-tests\ahk-out.txt
#Include %A_ScriptDir%\..\press-1.ahk

; Stop the popup machinery — tests must not flash GUIs.
SetTimer(AutoShowCheck, 0)

TESTROOT := A_Temp "\press-1-tests\ahk-sandbox"
try DirDelete(TESTROOT, 1)
DirCreate(TESTROOT "\pending")
DirCreate(TESTROOT "\prompts")
DirCreate(TESTROOT "\proxy")
PERM_DIR := TESTROOT
PENDING_DIR := TESTROOT "\pending"
PROMPTS_DIR := TESTROOT "\prompts"
PROXY_DIR := TESTROOT "\proxy"
; Redirect the tray's master Codex kill-switch too. Proxy rows are produced by
; the wrapper (not the hook), so ReadAllPrompts must enforce this flag itself.
offCodexFlag := TESTROOT "\.press-1-off-codex"
; Keep the Codex reviewer toggle fully isolated too: T48 invokes the real tray
; callback, but it may only touch this sandbox flag (never the user's setting).
offCodexAutoReviewFlag := TESTROOT "\.press-1-off-codex-desktop-auto-review"

OUT := A_Temp "\press-1-tests\ahk-out.txt"
try FileDelete(OUT)

passCount := 0
failCount := 0
Check(name, cond, extra := "") {
    global passCount, failCount, OUT
    if cond {
        passCount++
        FileAppend("  OK   " name "`n", OUT)
    } else {
        failCount++
        FileAppend("  FAIL " name (extra != "" ? " — " extra : "") "`n", OUT)
    }
}

nowMs := EpochMs()
ownPid := ProcessExist()

; NOTE: continuation sections are LITERAL (no interpolation) — placeholders
; are substituted afterwards via StrReplace.
standaloneTemplate := '
(
{
  "schema": 2,
  "id": "__ID__",
  "agent": "__AGENT__",
  "timestamp": __NOW__,
  "project_name": "__PROJ__",
  "cwd": "D:/dev/__PROJ__",
  "session_id": "sess-1",
  "tool_name": "Bash",
  "tool_input_short": "echo {\"decision_file\": \"decoy\", \"type\": \"bogus\"}",
  "kind": "__KIND__",
  "options": __OPTIONS__,
  "native_control": __NATIVECONTROL__,
  "decision_file": "__DECFILE__",
  "wait_until": __WAITUNTIL__,
  "claude_pid": 1234,
  "hook_pid": __HOOKPID__,
  "host": {
    "type": "__HOSTTYPE__",
    "entrypoint": "cli",
    "term_program": "",
    "wt_session": "guid-1",
    "ancestry": [{ "pid": 50164, "exe": "bash.exe" }, { "pid": __PID__, "exe": "WindowsTerminal.exe" }],
    "top_level_pid": __PID__,
    "top_level_exe": "WindowsTerminal.exe",
    "editor_exe": "__EDITOREXE__",
    "hwnd": 0,
    "title": "",
    "walk_ms": 534
  }
}
)'

WritePending(id, proj, hostType, kind, optionsJson, waitUntil, pid, hookPid := -1, editorExe := "", agent := "claude", nativeControl := "false") {
    global standaloneTemplate, PENDING_DIR, TESTROOT, nowMs, ownPid
    if hookPid = -1
        hookPid := ownPid  ; default: hook "alive"
    decFile := waitUntil && nativeControl != "true" ? TESTROOT "\response-hook-" id ".txt" : ""
    s := standaloneTemplate
    s := StrReplace(s, "__ID__", id)
    s := StrReplace(s, "__AGENT__", agent)
    s := StrReplace(s, "__NOW__", nowMs)
    s := StrReplace(s, "__PROJ__", proj)
    s := StrReplace(s, "__HOSTTYPE__", hostType)
    s := StrReplace(s, "__KIND__", kind)
    s := StrReplace(s, "__OPTIONS__", optionsJson)
    s := StrReplace(s, "__NATIVECONTROL__", nativeControl)
    s := StrReplace(s, "__DECFILE__", StrReplace(decFile, "\", "\\"))
    s := StrReplace(s, "__WAITUNTIL__", waitUntil)
    s := StrReplace(s, "__HOOKPID__", hookPid)
    s := StrReplace(s, "__PID__", pid)
    s := StrReplace(s, "__EDITOREXE__", editorExe)
    FileAppend(s, PENDING_DIR "\" id ".json", "UTF-8")
    return decFile
}

ClearPending() {
    global PENDING_DIR
    Loop Files, PENDING_DIR "\*.json"
        try FileDelete(A_LoopFileFullPath)
}

; --- T1: WT permission row carries the decision channel ---
dec1 := WritePending("wt-1", "proj-wt", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid)
rows := ReadAllPrompts()
Check("T1 one row", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T1 host=windows-terminal", r.host = "windows-terminal")
    Check("T1 kind=permission", r.kind = "permission")
    Check("T1 decision_file wired", r.decision_file = dec1, r.decision_file)
    Check("T1 pending_file wired", r.pending_file != "" && FileExist(r.pending_file))
    Check("T1 options parsed (3)", r.options.Length = 3 && r.options[2] = "Always allow")
    Check("T1 host_title prop removed", !r.HasOwnProp("host_title"))
    Check("T1 anchor-guard: decoy decision_file in tool_input ignored", r.decision_file != "decoy")

    ; --- T2: DecisionWordForKey, 3-option layout ---
    Check("T2 key 1 → allow", DecisionWordForKey(r, "1") = "allow")
    Check("T2 key 2 → always", DecisionWordForKey(r, "2") = "always")
    Check("T2 key 3 → deny", DecisionWordForKey(r, "3") = "deny")

    ; --- T3: WriteHookDecision writes the word; refuses after pending gone ---
    ok := WriteHookDecision(r, "deny", true)
    word := ""
    try word := FileRead(dec1, "UTF-8")
    Check("T3 decision written", ok && word = "deny", "ok=" ok " word=" word)
    try FileDelete(r.pending_file)
    Check("T3 refused once pending gone", !WriteHookDecision(r, "allow", true))
}
ClearPending()

; --- T4: 2-option layout maps key 2 to deny ---
WritePending("wt-2opt", "proj-2opt", "windows-terminal", "permission",
    '["Allow", "Deny"]', nowMs + 900000, ownPid)
rows := ReadAllPrompts()
if rows.Length = 1 {
    Check("T4 2-opt key 2 → deny", DecisionWordForKey(rows[1], "2") = "deny")
    Check("T4 2-opt key 3 → deny", DecisionWordForKey(rows[1], "3") = "deny")
} else {
    Check("T4 row present", false, "got " rows.Length)
}
ClearPending()

; --- T5: expired wait_until hides the row but keeps the file (terminal alive) ---
WritePending("wt-expired", "proj-exp", "windows-terminal", "permission",
    '["Allow", "Deny"]', nowMs - 10000, ownPid)
rows := ReadAllPrompts()
Check("T5 expired row hidden", rows.Length = 0, "got " rows.Length)
Check("T5 file kept (liveness ok)", FileExist(PENDING_DIR "\wt-expired.json"))
ClearPending()

; --- T6: dead top-level process → row dropped AND file deleted ---
WritePending("wt-dead", "proj-dead", "windows-terminal", "permission",
    '["Allow", "Deny"]', nowMs + 900000, 999999)
rows := ReadAllPrompts()
Check("T6 dead-host row dropped", rows.Length = 0, "got " rows.Length)
Check("T6 dead pending deleted", !FileExist(PENDING_DIR "\wt-dead.json"))
ClearPending()

; --- T7: FIFO order — oldest standalone prompt is row [A] ---
WritePending("wt-old", "proj-old", "windows-terminal", "permission",
    '["Allow", "Deny"]', nowMs + 900000, ownPid)
Sleep 60
WritePending("wt-new", "proj-new", "conhost", "permission",
    '["Allow", "Deny"]', nowMs + 900000, ownPid)
rows := ReadAllPrompts()
Check("T7 two rows", rows.Length = 2, "got " rows.Length)
if rows.Length = 2 {
    Check("T7 oldest first", rows[1].prompt_id = "wt-old" && rows[2].prompt_id = "wt-new",
        rows[1].prompt_id "," rows[2].prompt_id)
    Check("T7 conhost host parsed", rows[2].host = "conhost")
}
ClearPending()

; --- T8: panel permission regression (decision channel untouched) ---
WritePending("panel-1", "proj-panel", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid)
rows := ReadAllPrompts()
Check("T8 panel row present", rows.Length = 1 && rows[1].host = "vscode-extension")
if rows.Length = 1
    Check("T8 panel decision_file wired", rows[1].decision_file != "")
ClearPending()

; --- T9: standalone picker → attention row, no options ---
WritePending("wt-picker", "proj-pick", "windows-terminal", "picker", "[]", 0, ownPid)
rows := ReadAllPrompts()
Check("T9 picker row present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    Check("T9 kind=picker, no options", rows[1].kind = "picker" && rows[1].options.Length = 0)
    Check("T9 no decision channel", rows[1].decision_file = "")
}
ClearPending()

; --- T10: dead hook (CC killed the race loser) → row dropped, file deleted,
; even though the terminal itself is alive (top_level_pid = own pid) ---
WritePending("wt-orphan", "proj-orph", "windows-terminal", "permission",
    '["Allow", "Deny"]', nowMs + 900000, ownPid, 999999)
rows := ReadAllPrompts()
Check("T10 orphan row dropped", rows.Length = 0, "got " rows.Length)
Check("T10 orphan pending deleted", !FileExist(PENDING_DIR "\wt-orphan.json"))
ClearPending()

; --- T11: same for panel pendings ---
WritePending("panel-orphan", "proj-porph", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid, 999999)
rows := ReadAllPrompts()
Check("T11 panel orphan dropped", rows.Length = 0, "got " rows.Length)
Check("T11 panel orphan deleted", !FileExist(PENDING_DIR "\panel-orphan.json"))
ClearPending()

; --- T12: with the liveness beacon (2026-06-14) a picker's hook stays alive
; while the question is open, so a DEAD hook_pid now means the question was
; resolved (answer cleared it via teardown, or cancel got the hook killed) →
; drop the row and the orphaned file, same as a permission decision row.
; (A LIVE-hook picker still shows — covered by T9, default hook_pid = own pid.) ---
WritePending("wt-picker2", "proj-pick2", "windows-terminal", "picker", "[]", 0, ownPid, 999999)
rows := ReadAllPrompts()
Check("T12 picker with dead hook_pid dropped", rows.Length = 0, "got " rows.Length)
Check("T12 picker orphan file deleted", !FileExist(PENDING_DIR "\wt-picker2.json"))
ClearPending()

; --- T16: editor terminal (scenario B) permission row. The companion extension
; is gone; vscode-terminal now rides the same hook-decision channel as the panel.
; The row carries decision_file, host=vscode-terminal (no badge), and editor_exe
; (focuses the right editor for a picker). Lifecycle = the panel's: hook_pid
; staleness owns orphans, no window-death gate. ---
dec16 := WritePending("vst-perm", "proj-vst", "vscode-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 3600000, ownPid, ownPid, "Code.exe")
rows := ReadAllPrompts()
Check("T16 vscode-terminal row present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T16 host=vscode-terminal", r.host = "vscode-terminal")
    Check("T16 kind=permission", r.kind = "permission")
    Check("T16 decision_file wired", r.decision_file = dec16, r.decision_file)
    Check("T16 editor_exe carried", r.editor_exe = "Code.exe", r.editor_exe)
    Check("T16 key 2 → always (3-opt)", DecisionWordForKey(r, "2") = "always")
    Check("T16 WriteHookDecision writes word", WriteHookDecision(r, "deny", true))
}
ClearPending()

; --- T17: editor terminal picker (AskUserQuestion / ExitPlanMode) → attention
; row, no decision channel, editor_exe carried for the focus helper. ---
WritePending("vst-pick", "proj-vstp", "vscode-terminal", "picker", "[]", 0, ownPid, ownPid, "Cursor.exe")
rows := ReadAllPrompts()
Check("T17 vscode-terminal picker present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    Check("T17 kind=picker, no decision", rows[1].kind = "picker" && rows[1].decision_file = "")
    Check("T17 picker carries editor_exe", rows[1].editor_exe = "Cursor.exe", rows[1].editor_exe)
}
ClearPending()

; --- T18: dead-hook editor-terminal permission orphan dropped (same as panel/WT:
; CC kills the race-loser hook → pending + dead hook_pid → row+file gone). ---
WritePending("vst-orphan", "proj-vsto", "vscode-terminal", "permission",
    '["Allow", "Deny"]', nowMs + 3600000, ownPid, 999999, "Code.exe")
rows := ReadAllPrompts()
Check("T18 editor-terminal orphan dropped", rows.Length = 0, "got " rows.Length)
Check("T18 editor-terminal orphan deleted", !FileExist(PENDING_DIR "\vst-orphan.json"))
ClearPending()

; --- T13: standalone card title (BACKLOG 13). CC paints the tab/window title as
; "<glyph> <topic>"; the card prefers that topic over basename(cwd), but a generic
; shell title (or empty) must fall back to project_name. Encodes the intent: only
; a real claude topic title replaces the project name. ---
Check("T13 glyph topic → stripped topic",
    StandaloneTitleOrFallback(Chr(0x2733) " Create action for PR", "home-proj") = "Create action for PR")
Check("T13 generic PowerShell title → fallback",
    StandaloneTitleOrFallback("Windows PowerShell", "home-proj") = "home-proj")
Check("T13 cmd.exe title → fallback",
    StandaloneTitleOrFallback("C:\Windows\System32\cmd.exe", "home-proj") = "home-proj")
Check("T13 empty title → fallback",
    StandaloneTitleOrFallback("", "home-proj") = "home-proj")
Check("T13 glyph but no topic → fallback",
    StandaloneTitleOrFallback(Chr(0x2733) "  ", "home-proj") = "home-proj")

; --- T15: PidStaleDecision (dead-session picker). A hook_pid is stale when the
; process is gone OR a live process with that PID started after the pending was
; written (PID reuse). Unreadable start time or missing timestamp → keep the row
; (fail-safe toward showing). ---
ts := 1700000000000
Check("T15 dead process → stale",
    PidStaleDecision(false, 0, ts) = true)
Check("T15 alive, start unreadable → keep",
    PidStaleDecision(true, 0, ts) = false)
Check("T15 alive, started before pending → keep",
    PidStaleDecision(true, ts - 5000, ts) = false)
Check("T15 alive, started well after pending → stale (reused)",
    PidStaleDecision(true, ts + 5000, ts) = true)
Check("T15 alive, start within 2s tolerance → keep",
    PidStaleDecision(true, ts + 1000, ts) = false)
Check("T15 missing timestamp → keep (trust existence)",
    PidStaleDecision(true, ts + 9999, 0) = false)

; --- T19: Codex panel pending — agent parsed onto the row, decision channel
; identical to Claude's panel (Codex rides the same hook-decision channel). ---
dec19 := WritePending("cdx-panel", "proj-cdx", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid, ownPid, "", "codex")
rows := ReadAllPrompts()
Check("T19 codex panel row present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T19 agent=codex parsed", r.agent = "codex", r.agent)
    Check("T19 host=vscode-extension", r.host = "vscode-extension")
    Check("T19 decision_file wired", r.decision_file = dec19, r.decision_file)
    Check("T19 3-opt key 2 → always", DecisionWordForKey(r, "2") = "always")
}
ClearPending()

; --- T19b: Codex native-control panel pending deliberately has no decision_file
; and the hook is already gone, but the row must stay visible until its TTL so
; Press-1 can send 1/2/3 to Codex's native webview. ---
WritePending("cdx-native", "proj-cdx", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T19b native-control row survives dead hook", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T19b native-control parsed", r.native_control = true)
    Check("T19b native-control no decision_file", r.decision_file = "")
    Check("T19b native-control pending kept", FileExist(r.pending_file))
}
ClearPending()

WritePending("cdx-native-expired", "proj-cdx", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs - 1, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T19b expired native-control hidden", rows.Length = 0, "got " rows.Length)
Check("T19b expired native-control file deleted", !FileExist(PENDING_DIR "\cdx-native-expired.json"))
ClearPending()

; --- T20: Codex standalone (WT/conhost) — agent rides through, decision channel
; works the same; a missing-walk conhost pending still shows (no liveness fields). ---
WritePending("cdx-wt", "proj-cdxwt", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid, ownPid, "", "codex")
rows := ReadAllPrompts()
Check("T20 codex WT row present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1
    Check("T20 codex agent on standalone row", rows[1].agent = "codex")
ClearPending()

; --- T21: P1_HostBadge — Codex variants are tagged, Claude badges unchanged. ---
Check("T21 codex panel → codex·panel", P1_HostBadge("codex", "vscode-extension") = "codex·panel")
Check("T21 codex term → codex·term", P1_HostBadge("codex", "vscode-terminal") = "codex·term")
Check("T21 codex WT → codex·WT", P1_HostBadge("codex", "windows-terminal") = "codex·WT")
Check("T21 codex conhost → codex·console", P1_HostBadge("codex", "conhost") = "codex·console")
Check("T21 claude panel → panel (unchanged)", P1_HostBadge("claude", "vscode-extension") = "panel")
Check("T21 claude WT → WT (unchanged)", P1_HostBadge("claude", "windows-terminal") = "WT")
Check("T21 claude conhost → console (unchanged)", P1_HostBadge("claude", "conhost") = "console")
Check("T21 claude editor terminal → no badge", P1_HostBadge("claude", "vscode-terminal") = "")
Check("T21 unknown host → no badge", P1_HostBadge("codex", "mystery") = "")

; --- T22: IsPanelHost drives Focus-label decisions off the host, not the badge
; string (so codex·panel etc. can't break "Focus panel" vs "Focus terminal"). ---
Check("T22 panel host is panel", IsPanelHost("vscode-extension") = 1)
Check("T22 editor terminal not panel", IsPanelHost("vscode-terminal") = 0)
Check("T22 WT not panel", IsPanelHost("windows-terminal") = 0)

; --- T23: P1_AgentLabel — symmetric agent-only card pill (both agents tagged;
; host stays in the toast). Blank/unknown agent → no pill. ---
Check("T23 claude → Claude", P1_AgentLabel("claude") = "Claude")
Check("T23 codex → Codex", P1_AgentLabel("codex") = "Codex")
Check("T23 blank → empty (no pill)", P1_AgentLabel("") = "")
Check("T23 unknown → empty (no pill)", P1_AgentLabel("gemini") = "")

; --- T24: P1_AgentChecked — tray "Active for" checkmark INVERSE of mute:
; checked (= agent enabled) ⇔ off-flag ABSENT. ---
Check("T24 off-flag present → unchecked (disabled)", P1_AgentChecked(true) = 0)
Check("T24 off-flag absent → checked (enabled)", P1_AgentChecked(false) = 1)

; --- T24b: Codex native-control must fail closed unless the matching editor
; window was already active when the hotkey fired. This prevents focus-steal
; followed by typing "1" into an arbitrary VS Code pane. ---
Check("T24b native-control requires active target", NativeControlWindowMatches(123, 123) = true)
Check("T24b native-control rejects no prevWin", NativeControlWindowMatches(123, 0) = false)
Check("T24b native-control rejects different window", NativeControlWindowMatches(123, 456) = false)

; --- T25: P1_StackYTargets — clean fixed-gap stack layout (Change 1). Index 1 =
; slot 0 = bottom-most. anchorBottom 1000, gap 8, outerY 26 for all. ---
oys3 := [26, 26, 26]
; equal heights must reproduce the old baseY − slot·step exactly (no regression)
ytEq := P1_StackYTargets(oys3, [200, 200, 200], 1000, 8)
baseY := 1000 - 26 - 200, step := 200 + 8
Check("T25 equal heights = old baseY (slot 0)", ytEq[1] = baseY, "got " ytEq[1])
Check("T25 equal heights = old (slot 1)", ytEq[2] = baseY - step, "got " ytEq[2])
Check("T25 equal heights = old (slot 2)", ytEq[3] = baseY - 2*step, "got " ytEq[3])
; variable heights, bottom card taller — gap between bottom (slot 0) and the card
; above (slot 1) must be EXACTLY gap, not negative (the overlap bug).
ytVar := P1_StackYTargets(oys3, [300, 200, 200], 1000, 8)
visTop0 := ytVar[1] + oys3[1]
visBot1 := ytVar[2] + oys3[2] + 200
Check("T25 variable (tall bottom): fixed gap, no overlap", visTop0 - visBot1 = 8, "gap " (visTop0 - visBot1))
Check("T25 bottom card anchored at anchorBottom", ytVar[1] + oys3[1] + 300 = 1000, "bottom " (ytVar[1] + oys3[1] + 300))
; tall TOP card (an expanded card at slot 2) — gap between slot 1 and slot 2 holds
ytTop := P1_StackYTargets(oys3, [200, 200, 400], 1000, 8)
visTop1 := ytTop[2] + oys3[2]
visBot2 := ytTop[3] + oys3[3] + 400
Check("T25 variable (tall top/expanded): fixed gap, no overlap", visTop1 - visBot2 = 8, "gap " (visTop1 - visBot2))
; single card — bottom-anchored, no gap math
ytOne := P1_StackYTargets([26], [200], 1000, 8)
Check("T25 single card bottom-anchored", ytOne[1] = 1000 - 26 - 200, "got " ytOne[1])

; --- T26: expand layout + state (Change 2). P1_HeaderBottom extends the header
; for N command lines; P1_CmdTruncated is the affordance/toggle gate; the
; expandedKeys map tracks per-prompt expansion. ---
hb1 := P1_HeaderBottom(22, 30, 22, 1, 20)
Check("T26 header cmdLines=1 (no extra)", hb1 = 22 + 30 + 22, "got " hb1)
hb2 := P1_HeaderBottom(22, 30, 22, 2, 20)
Check("T26 header cmdLines=2 (= old +cmdLine2)", hb2 = 22 + 30 + 22 + 20, "got " hb2)
hb5 := P1_HeaderBottom(22, 30, 22, 5, 20)
Check("T26 header cmdLines=5 (+4·cmdLine2)", hb5 = 22 + 30 + 22 + 4*20, "got " hb5)
Check("T26 each extra line adds exactly cmdLine2", hb5 - hb2 = 3*20, "got " (hb5 - hb2))
; truncation predicate: drives BOTH the affordance and Ctrl+Win+E
Check("T26 not truncated: equal + fits collapsed", P1_CmdTruncated("Bash(ls)", "Bash(ls)", 1, 2) = 0)
Check("T26 truncated: long single line needs >2 lines", P1_CmdTruncated("Bash(ls)", "Bash(ls)", 3, 2) = 1)
Check("T26 truncated: 200-cap loss (full differs)", P1_CmdTruncated("Bash(xxx…)", "Bash(xxx more)", 1, 2) = 1)
Check("T26 truncated: newline collapse (full differs, fits 2 lines)", P1_CmdTruncated("Bash(a b)", "Bash(a`nb)", 2, 2) = 1)
; expandedKeys map round-trip (per-prompt expansion state)
PromptPopup.expandedKeys := Map()
Check("T26 expandedKeys starts empty", PromptPopup.expandedKeys.Count = 0)
PromptPopup.expandedKeys["k1"] := true
Check("T26 expand key tracked", PromptPopup.expandedKeys.Has("k1") = 1)
PromptPopup.expandedKeys.Delete("k1")
Check("T26 collapse removes key", PromptPopup.expandedKeys.Has("k1") = 0)

; --- T27: hybrid phase-1→2 rewrite of the SAME pending file between ticks — the
; row survives with the same prompt_id/signature (no re-show after dismiss, no
; new sound), flips to native_control, loses its decision channel. Also T32:
; the stale phase-1 row object must refuse to write its word once the live file
; switched (transition-race guard in WriteHookDecision).
dec27 := WritePending("cdx-hyb", "proj-hyb", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 19000, ownPid, ownPid, "", "codex")
rows := ReadAllPrompts()
Check("T27 phase-1 row present", rows.Length = 1, "got " rows.Length)
r27a := rows.Length = 1 ? rows[1] : ""
sig27 := rows.Length = 1 ? PromptPopup.ComputeSignature(rows) : ""
try FileDelete(PENDING_DIR "\cdx-hyb.json")
WritePending("cdx-hyb", "proj-hyb", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T27 phase-2 row still present (dead hook ok)", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 && IsObject(r27a) {
    r27b := rows[1]
    Check("T27 flipped to native_control", r27b.native_control = true)
    Check("T27 decision channel gone", r27b.decision_file = "")
    Check("T27 same prompt_id (row morphs in place)", r27b.prompt_id = r27a.prompt_id)
    Check("T27 same signature (dismiss suppression holds)", PromptPopup.ComputeSignature(rows) = sig27)
    Check("T32 WriteHookDecision refuses after the switch", !WriteHookDecision(r27a, "allow", true))
    Check("T32 no decision word written", !FileExist(dec27))
}
ClearPending()

; --- T28: rewritten WT native pending flows through ReadAllPending →
; ReadAllPrompts with native_control INTACT and routes to the focus path — the
; regression class: the standalone push has its own field set (lesson 128) and
; used to drop native_control, sending the row into SendHookDecision to refuse
; on its empty decision_file.
WritePending("cdx-wtn", "proj-wtn", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T28 WT native row present (dead hook ok)", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T28 standalone push carries native_control", r.native_control = true)
    Check("T28 no decision channel on the row", r.decision_file = "")
    Check("T28 route = wt-focus (not the decision path)", NativeRouteForHost(r.host) = "wt-focus")
    Check("T28 decision path would refuse, not misroute", !WriteHookDecision(r, "allow", true))
}
ClearPending()

; --- T28b: same flow for a vscode-terminal native row → editor-focus route,
; editor_exe carried for FindEditorByName.
WritePending("cdx-vtn", "proj-vtn", "vscode-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "Code.exe", "codex", "true")
rows := ReadAllPrompts()
Check("T28b vsterm native row present", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    Check("T28b native_control carried", rows[1].native_control = true)
    Check("T28b route = editor-focus", NativeRouteForHost(rows[1].host) = "editor-focus")
    Check("T28b editor_exe carried", rows[1].editor_exe = "Code.exe")
}
ClearPending()

; --- T29: IsCodexActionTitle — the codex analog of the claude glyph scan.
Check("T29 [ ! ] positive", IsCodexActionTitle("[ ! ] Action Required") = true)
Check("T29 [ . ] positive (blink state)", IsCodexActionTitle("[ . ] Action Required — codex") = true)
Check("T29 leading whitespace positive", IsCodexActionTitle("  [ ! ] Action Required") = true)
Check("T29 generic shell title negative", IsCodexActionTitle("Windows PowerShell") = false)
Check("T29 empty negative", IsCodexActionTitle("") = false)
Check("T29 claude glyph negative", IsCodexActionTitle(Chr(0x2733) " Create action") = false)
Check("T29 [x] negative", IsCodexActionTitle("[x] Action Required") = false)

; --- T30: PickCodexActionHwnd — focus only on an unambiguous action window.
pick1 := PickCodexActionHwnd([{hwnd: 11, title: "cmd"}, {hwnd: 22, title: "[ ! ] Action Required"}])
Check("T30 single action window picked", pick1 = 22, "got " pick1)
Check("T30 zero matches → 0 (tooltip only)", PickCodexActionHwnd([{hwnd: 11, title: "cmd"}]) = 0)
pick2 := PickCodexActionHwnd([{hwnd: 11, title: "[ ! ] Action Required"}, {hwnd: 22, title: "[ . ] Action Required"}])
Check("T30 two matches → 0 (ambiguous, no focus)", pick2 = 0, "got " pick2)

; --- T30b: ResolveCodexStandaloneTarget — action-title window first; else a
; single window of the exe is unambiguous by count (CX8 fallback: the action
; title may never reach the WT window title); 2+ untitled windows → 0.
Check("T30b action title wins", ResolveCodexStandaloneTarget([{hwnd: 1, title: "cmd"}, {hwnd: 2, title: "[ ! ] Action Required"}]) = 2)
Check("T30b single window fallback", ResolveCodexStandaloneTarget([{hwnd: 7, title: "plain title"}]) = 7)
Check("T30b two plain windows → 0", ResolveCodexStandaloneTarget([{hwnd: 1, title: "a"}, {hwnd: 2, title: "b"}]) = 0)
Check("T30b empty list → 0", ResolveCodexStandaloneTarget([]) = 0)

; --- T34: AllDismissed — Esc suppression by SUBSET (CX6): rows of the dismissed
; set dying off must keep the popup hidden; a genuinely new prompt re-opens.
PromptPopup.dismissedKeys := Map("a", true, "b", true, "c", true)
p_ := (id) => {prompt_id: id, project_name: "p", terminal_index: -1, detected_at: 1}
Check("T34 shrunken subset stays suppressed", PromptPopup.AllDismissed([p_("b"), p_("c")]) = true)
Check("T34 full set suppressed", PromptPopup.AllDismissed([p_("a"), p_("b"), p_("c")]) = true)
Check("T34 new id busts suppression", PromptPopup.AllDismissed([p_("b"), p_("NEW")]) = false)
Check("T34 empty dismissed set → no suppression", (PromptPopup.dismissedKeys := Map(), PromptPopup.AllDismissed([p_("a")])) = false)
Check("T34 empty prompt list → no suppression", (PromptPopup.dismissedKeys := Map("a", true), PromptPopup.AllDismissed([])) = false)
PromptPopup.dismissedKeys := Map()

; --- T31: expired WT native pending is DELETED by the standalone branch (the
; editor-branch TTL behavior) — not just hidden until the 90-min backstop.
WritePending("cdx-wtn-exp", "proj-wtnx", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs - 1, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T31 expired WT native row hidden", rows.Length = 0, "got " rows.Length)
Check("T31 expired WT native file DELETED", !FileExist(PENDING_DIR "\cdx-wtn-exp.json"))
ClearPending()

; --- T33: uniqueness guard (critical) — two live panel native pendings on the
; same target window: the digit is NOT row-addressed, so SendCodexNativeDecision
; must refuse and keep both pendings.
WritePending("cdx-multi1", "proj-multi", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "", "codex", "true")
WritePending("cdx-multi2", "proj-multi", "vscode-extension", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 300000, ownPid, 999999, "", "codex", "true")
rows := ReadAllPrompts()
Check("T33 two native rows on one target", rows.Length = 2, "got " rows.Length)
if rows.Length = 2 {
    Check("T33 target count = 2", CountCodexPanelNativeTargets("proj-multi", "") = 2)
    okSend := SendCodexNativeDecision(rows[1], "1", 0)
    Check("T33 uniqueness guard refused the send", !okSend)
    Check("T33 pending 1 kept", FileExist(PENDING_DIR "\cdx-multi1.json"))
    Check("T33 pending 2 kept", FileExist(PENDING_DIR "\cdx-multi2.json"))
}
ClearPending()

; --- T35: stack order is keyed to the hook-written "timestamp", not file
; creation time — the hybrid phase 1→2 rewrite recreates the pending file and
; used to reshuffle the popup stack mid-life (live smoke 2026-07-02).
; ord-old's FILE is the newest (created 1.1 s later; in-place truncate-write
; below preserves creation time), but its JSON timestamp is the oldest.
PatchPendingTimestamp(file, ts) {
    raw := FileRead(file, "UTF-8")
    raw := RegExReplace(raw, '"timestamp"\s*:\s*\d+', '"timestamp": ' ts)
    fo := FileOpen(file, "w", "UTF-8")
    fo.Write(raw)
    fo.Close()
}
; --- T36: ResolveCodexPanelFallback — panel count-of-one fallback (CX4): one
; editor window may be SURFACED when title resolution fails (digit never sent
; on this path); 0 or 2+ windows → 0 (fail-closed tooltip).
Check("T36 single editor window → that hwnd", ResolveCodexPanelFallback([42]) = 42)
Check("T36 two windows → 0", ResolveCodexPanelFallback([1, 2]) = 0)
Check("T36 no windows → 0", ResolveCodexPanelFallback([]) = 0)

WritePending("ord-new", "proj-ord", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid)
Sleep(1100)  ; file-time sort key has 1 s resolution — force distinct seconds
WritePending("ord-old", "proj-ord", "windows-terminal", "permission",
    '["Allow", "Always allow", "Deny"]', nowMs + 900000, ownPid)
PatchPendingTimestamp(PENDING_DIR "\ord-old.json", nowMs - 60000)
pend := ReadAllPending()
Check("T35 two entries", pend.Length = 2, "got " pend.Length)
if pend.Length = 2 {
    Check("T35 newest timestamp first (file time ignored)", pend[1].id = "ord-new", "got " pend[1].id)
    Check("T35 oldest timestamp last", pend[2].id = "ord-old")
}
ClearPending()

; ============================================================================
; Experimental Codex proxy channel (DESIGN-CODEX-PROXY §3) — adapter + writer.
; ============================================================================
;
; Proxy pending template (LITERAL section: "\" and '"' are literal, backtick is
; the escape char). Placeholders substituted via StrReplace afterwards.
proxyTemplate := '
(
{"schema":"press1.codex.proxy/1","pid":__PID__,"agent":"codex","channel":"proxy","requestId":__REQ__,"threadId":"th-1","turnId":"tu-1","itemId":"it-1","command":"__COMMAND__","cwd":"__CWD__","reason":"__REASON__","availableDecisions":__AVAIL__,"proposedExecpolicyAmendment":__AMEND__,"ts":__TS__}
)'

WriteProxyPending(stem, pid, req, command, cwd, reason, availJson, amendJson, ts) {
    global proxyTemplate, PROXY_DIR
    s := proxyTemplate
    s := StrReplace(s, "__PID__", pid)
    s := StrReplace(s, "__REQ__", req)
    s := StrReplace(s, "__COMMAND__", command)
    s := StrReplace(s, "__CWD__", cwd)
    s := StrReplace(s, "__REASON__", reason)
    s := StrReplace(s, "__AVAIL__", availJson)
    s := StrReplace(s, "__AMEND__", amendJson)
    s := StrReplace(s, "__TS__", ts)
    FileAppend(s, PROXY_DIR "\" stem ".pending.json", "UTF-8")
    return PROXY_DIR "\" stem ".pending.json"
}
ClearProxy() {
    global PROXY_DIR
    Loop Files, PROXY_DIR "\*"
        try FileDelete(A_LoopFileFullPath)
}

availWithAmend := '["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["Set-Content","-LiteralPath","x"]}},"cancel"]'
availNoAmend := '["accept","cancel"]'

; --- T37: proxy pending parses to a codex-proxy row with derived project_name,
; agent/channel, the 3-label amendment options, prompt_id and timestamp. ---
WriteProxyPending("17780-0", "17780", "0", "pwsh -Command Set-Content", "D:/dev/claude-approve",
    "Нужны права на запись", availWithAmend, '["Set-Content","-LiteralPath","x"]', 1783586692037)
rows := ReadAllPrompts()
Check("T37 one proxy row", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T37 project_name = basename(cwd)", r.project_name = "claude-approve", r.project_name)
    Check("T37 agent=codex", r.agent = "codex")
    Check("T37 channel=proxy", r.channel = "proxy")
    Check("T37 host=codex-proxy", r.host = "codex-proxy")
    Check("T37 kind=permission", r.kind = "permission")
    Check("T37 tool_name=exec", r.tool_name = "exec")
    Check("T37 prompt_id = pid-requestId", r.prompt_id = "17780-0", r.prompt_id)
    Check("T37 timestamp = ts", r.detected_at = 1783586692037, r.detected_at)
    Check("T37 3-label options (amendment offered)",
        r.options.Length = 3 && r.options[1] = "Allow" && r.options[2] = "Always allow" && r.options[3] = "Deny")
    Check("T37 amendment_offered flag", r.amendment_offered = true)
    Check("T37 tool_input_full = command (no reason)", r.tool_input_full = "pwsh -Command Set-Content", r.tool_input_full)
    Check("T37 reason leads collapsed short",
        r.tool_input_short = "Нужны права на запись " Chr(0x2014) " pwsh -Command Set-Content", r.tool_input_short)
}
ClearProxy()

; --- T38: no amendment offered → 2-label options, digit 2 = Deny path. ---
WriteProxyPending("17780-1", "17780", "1", "rm -rf tmp", "D:/dev/proj-b", "",
    availNoAmend, '[]', 1783586692050)
rows := ReadAllPrompts()
Check("T38 proxy row (no amendment)", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T38 2-label options", r.options.Length = 2 && r.options[2] = "Deny")
    Check("T38 amendment_offered = false", r.amendment_offered = false)
    Check("T38 empty reason → short = command", r.tool_input_short = "rm -rf tmp", r.tool_input_short)
}
ClearProxy()

; --- T39: row dropped when cwd is empty (project_name is a hard requirement). ---
WriteProxyPending("17780-2", "17780", "2", "echo hi", "", "reason", availNoAmend, '[]', 1783586692060)
rows := ReadAllPrompts()
Check("T39 empty-cwd row dropped", rows.Length = 0, "got " rows.Length)
ClearProxy()

; --- T39b: row dropped when the cwd key is missing entirely (torn/partial). ---
FileAppend('{"schema":"press1.codex.proxy/1","pid":17780,"requestId":3,"command":"echo hi","ts":1}',
    PROXY_DIR "\17780-3.pending.json", "UTF-8")
rows := ReadAllPrompts()
Check("T39b missing-cwd row dropped", rows.Length = 0, "got " rows.Length)
ClearProxy()

; --- T40: torn / invalid JSON is skipped without throwing. ---
FileAppend("{ this is not valid json at all", PROXY_DIR "\17780-4.pending.json", "UTF-8")
threw40 := false
rows := []
try rows := ReadAllProxyPending()
catch
    threw40 := true
Check("T40 invalid JSON did not throw", threw40 = false)
Check("T40 invalid JSON skipped (no row)", rows.Length = 0, "got " rows.Length)
ClearProxy()

; --- T41: non-*.pending.json files (decision/tmp) are ignored by the glob. ---
FileAppend('{"decision":"accept"}', PROXY_DIR "\17780-5.decision.json", "UTF-8")
Check("T41 decision file not parsed as pending", ReadAllProxyPending().Length = 0)
ClearProxy()

; --- T42: WriteProxyDecision output — exact JSON for accept / cancel. ---
p42 := WriteProxyPending("17780-6", "17780", "6", "echo hi", "D:/dev/proj-c", "",
    availWithAmend, '["Set-Content","-LiteralPath","x"]', 1783586692070)
dec42 := StrReplace(p42, ".pending.json", ".decision.json")
rows := ReadAllProxyPending()
Check("T42 one row for decision tests", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T42 accept written", WriteProxyDecision(r, "1"))
    word := "", ok := false
    try word := FileRead(dec42, "UTF-8-RAW")
    Check("T42 accept JSON exact", word = '{"decision":"accept"}', word)
    Check("T42 cancel written (digit 3)", WriteProxyDecision(r, "3"))
    try word := FileRead(dec42, "UTF-8-RAW")
    Check("T42 cancel JSON exact", word = '{"decision":"cancel"}', word)
    ; guard: refuse after the pending vanished (already resolved)
    try FileDelete(r.proxy_pending_path)
    Check("T42 refuses once pending gone", !WriteProxyDecision(r, "1"))
}
ClearProxy()

; --- T43: WriteProxyDecision amendment (digit 2) echoes the proposedExecpolicy-
; Amendment array BYTE-EXACT — including non-ASCII path chars, escaped backslashes
; and escaped quotes. The raw array is captured verbatim (never unescaped). ---
amend43 := '["Set-Content","-LiteralPath","D:\\dev\\проект\\a\"b.txt"]'
; Built structurally (braces here, array = amend43) → verifies BOTH the byte-exact
; raw capture and the decision wrapping, without a continuation-section newline.
expect43 := '{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":' amend43 '}}}'
p43 := WriteProxyPending("17780-7", "17780", "7", "Set-Content …", "D:/dev/проект", "",
    availWithAmend, amend43, 1783586692080)
dec43 := StrReplace(p43, ".pending.json", ".decision.json")
rows := ReadAllProxyPending()
Check("T43 one amendment row", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    r := rows[1]
    Check("T43 raw amendment captured verbatim", r.amendment_raw = amend43, r.amendment_raw)
    Check("T43 amendment decision written", WriteProxyDecision(r, "2"))
    got43 := ""
    try got43 := FileRead(dec43, "UTF-8-RAW")
    Check("T43 amendment JSON byte-exact", got43 = expect43, got43)
}
ClearProxy()

; --- T44: no amendment offered → digit 2 maps to cancel (2-option Deny), NOT an
; amendment object. ---
p44 := WriteProxyPending("17780-8", "17780", "8", "echo hi", "D:/dev/proj-d", "",
    availNoAmend, '[]', 1783586692090)
dec44 := StrReplace(p44, ".pending.json", ".decision.json")
rows := ReadAllProxyPending()
if rows.Length = 1 {
    Check("T44 digit 2 written", WriteProxyDecision(rows[1], "2"))
    word := ""
    try word := FileRead(dec44, "UTF-8-RAW")
    Check("T44 digit 2 → cancel (no amendment)", word = '{"decision":"cancel"}', word)
} else {
    Check("T44 row present", false, "got " rows.Length)
}
ClearProxy()

; --- T45: DispatchByKind routes a channel=proxy row to WriteProxyDecision (writes
; the proxy decision file), never to the hook/native writers. ---
p45 := WriteProxyPending("17780-9", "17780", "9", "echo hi", "D:/dev/proj-e", "",
    availWithAmend, '["Set-Content","-LiteralPath","x"]', 1783586692100)
dec45 := StrReplace(p45, ".pending.json", ".decision.json")
rows := ReadAllPrompts()
Check("T45 proxy row via ReadAllPrompts", rows.Length = 1, "got " rows.Length)
if rows.Length = 1 {
    DispatchByKind(rows[1], "1", 0, 0)
    Check("T45 proxy decision file written by DispatchByKind", FileExist(dec45))
    word := ""
    try word := FileRead(dec45, "UTF-8-RAW")
    Check("T45 routed to accept", word = '{"decision":"accept"}', word)
}
ClearProxy()

; --- T46: reconcile — deleting the pending removes the row from the next pass. ---
WriteProxyPending("17780-10", "17780", "10", "echo hi", "D:/dev/proj-f", "",
    availNoAmend, '[]', 1783586692110)
Check("T46 row present before delete", ReadAllProxyPending().Length = 1)
try FileDelete(PROXY_DIR "\17780-10.pending.json")
Check("T46 row gone after delete", ReadAllProxyPending().Length = 0)
ClearProxy()

; --- T47: badge / panel arms for codex-proxy. ---
Check("T47 codex-proxy badge → codex·proxy", P1_HostBadge("codex", "codex-proxy") = "codex·proxy")
Check("T47 codex-proxy is NOT a panel host (no focus routing)", IsPanelHost("codex-proxy") = 0)

; --- T48: Codex auto-review bypass is a positive, checked-by-default setting
; backed by an opt-OUT flag. Pin the public UX and legacy path while reusing the
; inverse checkmark helper (checked = feature enabled = flag absent). ---
prodAhk := FileRead(A_ScriptDir "\..\press-1.ahk", "UTF-8")
Check("T48 release tooltip pinned to v7.1",
    InStr(prodAhk, 'A_IconTip := "press-1 v7.1"') > 0)
Check("T48 legacy auto-review opt-out flag remains wired",
    InStr(prodAhk, ".press-1-off-codex-desktop-auto-review") > 0)
Check("T48 generic Codex auto-review menu label wired",
    InStr(prodAhk, "Let Auto-review decide (experimental)") > 0)
Check("T48 Codex submenu registers the generic callback",
    InStr(prodAhk, "codexMenu.Add(codexAutoReviewItem, ToggleCodexAutoReview)") > 0)
Check("T48 generic Codex submenu is registered",
    InStr(prodAhk, 'A_TrayMenu.Add("Codex", codexMenu)') > 0)
Check("T48 opt-out absent → setting checked by default", P1_AgentChecked(false) = 1)
Check("T48 opt-out present → setting unchecked", P1_AgentChecked(true) = 0)
try FileDelete(offCodexAutoReviewFlag)
toggleOk := true
try ToggleCodexAutoReview()
catch
    toggleOk := false
Check("T48 Codex submenu callback creates legacy opt-out flag",
    toggleOk && FileExist(offCodexAutoReviewFlag))
try ToggleCodexAutoReview()
catch
    toggleOk := false
Check("T48 Codex submenu callback removes legacy opt-out flag",
    toggleOk && !FileExist(offCodexAutoReviewFlag))

; --- T49: the master off-Codex flag suppresses proxy ROWS in AHK. The proxy
; wrapper owns its native pending file, so disabling display must never delete or
; mutate it; removing the flag makes the same request resolvable again. ---
ClearProxy()
try FileDelete(offCodexFlag)
p49 := WriteProxyPending("17780-11", "17780", "11", "echo keep-me", "D:/dev/proj-master-off", "",
    availNoAmend, '[]', 1783586692120)
FileAppend("", offCodexFlag)
Check("T49 master off-Codex suppresses proxy row", ReadAllPrompts().Length = 0)
Check("T49 suppressed proxy pending remains untouched", FileExist(p49))
FileDelete(offCodexFlag)
rows := ReadAllPrompts()
Check("T49 removing master flag reveals same proxy row",
    rows.Length = 1 && rows[1].prompt_id = "17780-11", "got " rows.Length)
Check("T49 revealed proxy pending is still resolvable", FileExist(p49))
ClearProxy()

; Dynamic call keeps this RED phase runnable before the production helper exists:
; a missing helper becomes ordinary assertion failures, not a compile-time abort.
CallReviewerStatusSummary(path, nowMs, &helperFound) {
    global P1_CodexReviewerStatusSummary
    helperFound := IsSet(P1_CodexReviewerStatusSummary)
    if !helperFound
        return "__HELPER_MISSING__"
    try {
        return P1_CodexReviewerStatusSummary(path, nowMs)
    } catch {
        return "__HELPER_MISSING__"
    }
}

WriteReviewerStatus(path, json) {
    try FileDelete(path)
    FileAppend(json, path, "UTF-8")
}

; --- T50: sanitized reviewer status is display-safe. Only the fixed schema and
; enum values may reach DebugPending; missing/malformed/stale/unknown data is
; ignored as "" and arbitrary strings are never echoed. TTL = 10 minutes. ---
statusPath := PERM_DIR "\codex-reviewer-last.json"
statusNow := 1785065000000
try FileDelete(statusPath)
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 reviewer-status helper exists", statusHelperFound)
Check("T50 missing reviewer status ignored", summary = "", summary)

WriteReviewerStatus(statusPath, "{ definitely not json")
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 malformed reviewer status ignored", summary = "", summary)

WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785064399999,"pid":123,"outcome":"popup","reason":"reviewer_user","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 reviewer status older than 10 min ignored", summary = "", summary)

WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785064999000,"pid":123,"outcome":"auto_pass","reason":"exact_auto_review","elapsed_ms":61,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 valid auto-pass status summarized",
    summary = "Last Codex reviewer probe: auto_pass / exact_auto_review (61 ms)", summary)

WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785064999000,"pid":123,"outcome":"popup","reason":"reviewer_user","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 valid popup status summarized",
    summary = "Last Codex reviewer probe: popup / reviewer_user (17 ms)", summary)

; EpochMs() is intentionally second-granular while the hook writes Date.now().
; A status from the current second may therefore appear up to 999 ms "future".
WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785065000999,"pid":123,"outcome":"popup","reason":"reviewer_user","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 same-second JS millisecond lead accepted",
    summary = "Last Codex reviewer probe: popup / reviewer_user (17 ms)", summary)

WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785065001000,"pid":123,"outcome":"popup","reason":"reviewer_user","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 future reviewer status beyond precision window ignored", summary = "", summary)

secretReason := "secret value turn-123"
WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785064999000,"pid":123,"outcome":"popup","reason":"' secretReason '","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 unknown reason ignored", summary = "", summary)
Check("T50 arbitrary reason never echoed", !InStr(summary, "secret") && !InStr(summary, "turn-123"), summary)

WriteReviewerStatus(statusPath,
    '{"schema":1,"ts":1785064999000,"pid":123,"outcome":"auto_pass","reason":"reviewer_user","elapsed_ms":17,"attempts":1,"file_bytes":80,"scanned_bytes":80,"grew":false,"tail_truncated":false}')
summary := CallReviewerStatusSummary(statusPath, statusNow, &statusHelperFound)
Check("T50 invalid outcome/reason pairing ignored", summary = "", summary)
try FileDelete(statusPath)

FileAppend("`n" passCount " passed, " failCount " failed`n", OUT)
ExitApp(failCount)
