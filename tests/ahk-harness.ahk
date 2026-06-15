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
PERM_DIR := TESTROOT
PENDING_DIR := TESTROOT "\pending"
PROMPTS_DIR := TESTROOT "\prompts"

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
  "agent": "claude",
  "timestamp": __NOW__,
  "project_name": "__PROJ__",
  "cwd": "D:/dev/__PROJ__",
  "session_id": "sess-1",
  "tool_name": "Bash",
  "tool_input_short": "echo {\"decision_file\": \"decoy\", \"type\": \"bogus\"}",
  "kind": "__KIND__",
  "options": __OPTIONS__,
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

WritePending(id, proj, hostType, kind, optionsJson, waitUntil, pid, hookPid := -1, editorExe := "") {
    global standaloneTemplate, PENDING_DIR, TESTROOT, nowMs, ownPid
    if hookPid = -1
        hookPid := ownPid  ; default: hook "alive"
    decFile := waitUntil ? TESTROOT "\response-hook-" id ".txt" : ""
    s := standaloneTemplate
    s := StrReplace(s, "__ID__", id)
    s := StrReplace(s, "__NOW__", nowMs)
    s := StrReplace(s, "__PROJ__", proj)
    s := StrReplace(s, "__HOSTTYPE__", hostType)
    s := StrReplace(s, "__KIND__", kind)
    s := StrReplace(s, "__OPTIONS__", optionsJson)
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

FileAppend("`n" passCount " passed, " failCount " failed`n", OUT)
ExitApp(failCount)
