; GDI+ renderer SCREENSHOT harness (design iteration). Renders the 3-card demo
; stack with the REAL renderer, captures just the bottom-right popup column to a
; PNG, then exits — no 20 s live popup. Coexists with a running daily-driver
; press-1 (different script path → #SingleInstance doesn't replace it); suspends
; its own hotkeys and hides its tray icon.
; Run: AutoHotkey64.exe tests\gdip-shot.ahk  →  %TEMP%\press-1-tests\gdip-shot.png
#NoTrayIcon
#Include %A_ScriptDir%\..\press-1.ahk

Suspend True
SetTimer(AutoShowCheck, 0)

DirCreate(A_Temp "\press-1-tests")
OUT := A_Temp "\press-1-tests\gdip-shot.png"
SHOTLOG := A_Temp "\press-1-tests\gdip-shot.txt"
try FileDelete(OUT)
try FileDelete(SHOTLOG)

if !PromptPopup.EnsureGdip() {
    FileAppend("GDI+ failed to start`n", SHOTLOG)
    ExitApp(1)
}

; Screenshot is deterministic and ignores the user's multi-display preference.
targetDisplay := ""
for display in P1_DISPLAY_CATALOG
    if display.primary {
        targetDisplay := display
        break
    }
P1_POPUP_DISPLAY_PREFS := [{id:targetDisplay.id, label:targetDisplay.name}]
wl := targetDisplay.workLeft, wt := targetDisplay.workTop
wr := targetDisplay.workRight, wb := targetDisplay.workBottom
sc := P1_PopupScale(targetDisplay.dpi, wr - wl)

; Put a deterministic neutral plate behind the popup so the public screenshot
; never captures the user's wallpaper or open applications.
capW := Round(640 * sc) + Round(56 * sc)
capX := wr - capW
capH := Min(Round(820 * sc), Round((wb - wt) * 0.78))
capY := wb - capH
plate := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
plate.BackColor := "1D1F20"
plate.Show("x" capX " y" capY " w" capW " h" capH " NoActivate")

; oldest = index 1 = top of stack = active ring. Long command → 2-line wrap.
p1 := { project_name:"my-api-server", tool_name:"Bash",
        tool_input_short:"docker compose -f docker-compose.prod.yml up -d --build --remove-orphans --scale worker=4",
        kind:"permission", options:["Allow","Always allow","Deny"], host:"windows-terminal",
        agent:"codex", prompt_id:"demo-1", terminal_index:-1, detected_at:1718592000000 }
; panel Write, shown with a readable path instead of raw JSON.
p2 := { project_name:"docs-site", tool_name:"Write", tool_input_short:"docs/api.md",
        kind:"permission", options:["Allow","Always allow","Deny"], host:"vscode-extension",
        agent:"claude", prompt_id:"demo-2", terminal_index:-1, detected_at:1718592001000 }
; newest = bottom = the v8 headline: Codex is waiting for an ordinary answer,
; not a permission decision. It is intentionally focus-only.
p3 := { project_name:"release-dashboard", tool_name:"",
        tool_input_short:"Deployment is ready. Continue with the production rollout?",
        kind:"attention", options:[], host:"vscode-terminal", agent:"codex",
        editor_exe:"Code.exe", prompt_id:"demo-3", terminal_index:-1,
        detected_at:1718592002000 }

PromptPopup.Show([p1, p2, p3])
SetTimer(PromptPopup._refreshFn, 0)    ; freeze reconcile so the cards persist

Sleep 950    ; let the appear animation settle to peak alpha

; Capture only the bottom-right popup column (privacy + focus on the cards).
region := capX "|" capY "|" capW "|" capH
pBM := Gdip_BitmapFromScreen(region)
if (pBM > 0) {
    Gdip_SaveBitmapToFile(pBM, OUT)
    try Gdip_DisposeImage(pBM)
    FileAppend("saved " OUT "`nregion=" region " monitor=" targetDisplay.index "/" MonitorGetCount()
        . " sc=" Round(sc, 3) "`n", SHOTLOG)
} else {
    FileAppend("capture failed ret=" pBM " region=" region "`n", SHOTLOG)
}

PromptPopup.Hide()
plate.Destroy()
ExitApp(0)
