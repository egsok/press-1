; GDI+ renderer runtime smoke (BACKLOG 11). Unlike ahk-harness.ahk (headless,
; asserts protocol logic), this one DRIVES the gdip renderer: starts GDI+, builds
; a 3-card stack, moves the active ring, then tears down — catching runtime errors
; the syntax-only harness can't. It briefly shows real cards bottom-right (~2 s).
; Run: AutoHotkey64.exe tests\gdip-smoke.ahk → %TEMP%\press-1-tests\gdip-smoke.txt
#Include %A_ScriptDir%\..\press-1.ahk

SetTimer(AutoShowCheck, 0)   ; don't let the auto-show timer interfere

DirCreate(A_Temp "\press-1-tests")
OUT := A_Temp "\press-1-tests\gdip-smoke.txt"
try FileDelete(OUT)

report := "START`n"
try {
    ok := PromptPopup.EnsureGdip()
    report .= "EnsureGdip=" ok " token=" PromptPopup._gdipToken "`n"
    if !ok {
        FileAppend(report "FAIL: GDI+ did not start`n", OUT)
        ExitApp(1)
    }

    p1 := { project_name:"my-api-server", tool_name:"Bash", tool_input_short:"docker compose -f docker-compose.prod.yml up -d --build --remove-orphans --scale worker=4",
            tool_input_full:"docker compose -f docker-compose.prod.yml up -d`n  --build`n  --remove-orphans`n  --scale worker=4`n  --scale web=2",
            kind:"permission", options:["Allow","Always allow","Deny"], host:"windows-terminal",
            prompt_id:"smoke-1", terminal_index:-1, detected_at:1718592000000 }
    p2 := { project_name:"web-frontend", tool_name:"Edit", tool_input_short:"src/components/AppShell.tsx",
            kind:"permission", options:["Allow","Deny"], host:"vscode-extension",
            prompt_id:"smoke-2", terminal_index:-1, detected_at:1718592001000 }
    p3 := { project_name:"docs-site", tool_name:"", tool_input_short:"",
            kind:"picker", options:[], host:"conhost",
            prompt_id:"smoke-3", terminal_index:-1, detected_at:1718592002000 }

    PromptPopup.Show([p1, p2, p3])
    ; freeze the data-reconcile timer so our fake cards aren't torn down by the
    ; real (empty) ReadAllPrompts() on the next 200ms tick.
    SetTimer(PromptPopup._refreshFn, 0)
    report .= "Show ok: cards=" PromptPopup.cards.Length " visible=" PromptPopup.visible " sel=" PromptPopup.selectedIndex "`n"
    Sleep 600                                  ; let the appear animation finish

    ; Focus feedback runtime: draw the same four click-through outline windows
    ; used around a selected editor HWND, then let their one-shot teardown fire.
    P1_PulseWindowOutline(PromptPopup.cards[1].hwnd)
    report .= "focus outline pulse ok`n"
    Sleep 1000

    PromptPopup.MoveSelection(1)               ; ring -> next card (redraw 2 cards)
    report .= "MoveSelection ok: sel=" PromptPopup.selectedIndex "`n"
    Sleep 400
    PromptPopup.MoveSelection(-1)
    Sleep 400

    ; expand exercise (Change 2): toggle p1's full-command view → _RebuildCard at a
    ; taller height, P1_TxtWrapN draws the multi-line full command, _Restack shifts
    ; the cards above. Then collapse back. Catches runtime errors the pure T26 can't.
    PromptPopup.expandedKeys["smoke-1"] := true
    PromptPopup._Reconcile()
    report .= "expand ok: cards=" PromptPopup.cards.Length "`n"
    Sleep 400
    PromptPopup.expandedKeys.Delete("smoke-1")
    PromptPopup._Reconcile()
    report .= "collapse ok: cards=" PromptPopup.cards.Length "`n"
    Sleep 400

    ; dedup regression (Fix 2): inject a SECOND card for smoke-1's key (simulates a
    ; rebuild/refresh race that orphaned a duplicate), reconcile, and confirm the
    ; dedup pass leaves exactly one non-fading card for that key.
    dup := PromptPopup._BuildCard(p1, 1)
    PromptPopup.cards.Push(dup)
    PromptPopup._Reconcile()
    liveDup := 0
    for c in PromptPopup.cards
        if c.key = "smoke-1" && c.phase != "dismiss" && c.phase != "dead"
            liveDup++
    report .= "dedup ok: live cards for smoke-1 = " liveDup (liveDup = 1 ? "" : "  <<< EXPECTED 1") "`n"
    Sleep 400

    ; coalescing-guard check (Fix A): a reconcile arriving while one is in flight
    ; must be REMEMBERED (pending), not dropped — else a dismiss-pass is lost and a
    ; card lingers after its hook released. Simulate the in-flight state, confirm
    ; the re-entrant call marks pending, then a real call runs and clears it.
    PromptPopup._reconciling := true
    PromptPopup._reconcilePending := false
    PromptPopup._Reconcile()                       ; re-entrant → marks pending, returns
    coalMark := PromptPopup._reconcilePending
    PromptPopup._reconciling := false
    PromptPopup._Reconcile()                       ; runs the body, clears pending
    report .= "coalesce ok: marked=" coalMark " cleared=" (!PromptPopup._reconcilePending)
        . " reconciling=" PromptPopup._reconciling
        . ((coalMark && !PromptPopup._reconcilePending && !PromptPopup._reconciling) ? "" : "  <<< UNEXPECTED") "`n"
    Sleep 200

    ; simulate answering the front card: dismiss it, expect fade + reap
    front := ""
    for c in PromptPopup.cards
        if c.slot = 0
            front := c
    if front {
        PromptPopup._StartDismiss(front)
        PromptPopup._ArmAnim()
        report .= "StartDismiss front ok`n"
    }
    Sleep 500
    report .= "after dismiss: cards=" PromptPopup.cards.Length "`n"

    PromptPopup.Hide()
    report .= "Hide ok: cards=" PromptPopup.cards.Length " visible=" PromptPopup.visible "`n"

    ; issue-2 renderer check: Show must work again after a Hide
    PromptPopup.Show([p2])
    SetTimer(PromptPopup._refreshFn, 0)
    report .= "Re-Show ok: cards=" PromptPopup.cards.Length " visible=" PromptPopup.visible "`n"
    Sleep 300
    PromptPopup.Hide()
    report .= "Re-Hide ok: cards=" PromptPopup.cards.Length "`n"
    report .= "PASS`n"
} catch as e {
    report .= "EXCEPTION: " e.Message " | what=" e.What " | line=" e.Line "`n"
    try report .= "extra=" e.Extra "`n"
}
FileAppend(report, OUT)
ExitApp(0)
