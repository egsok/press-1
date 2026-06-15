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

; Prefer a 1080p monitor (smaller relative scale) else primary.
target := MonitorGetPrimary()
Loop MonitorGetCount() {
    MonitorGet(A_Index, &ml, &mt, &mr, &mb)
    if (mb - mt) = 1080 {
        target := A_Index
        break
    }
}
PromptPopup.monitorIndex := target
MonitorGetWorkArea(target, &wl, &wt, &wr, &wb)
sc := Min(1.30, Max(0.62, (wr - wl) / 2560))

; oldest = index 1 = top of stack = active ring. Long command → 2-line wrap.
p1 := { project_name:"my-api-server", tool_name:"Bash",
        tool_input_short:"docker compose -f docker-compose.prod.yml up -d --build --remove-orphans --scale worker=4",
        kind:"permission", options:["Allow","Always allow","Deny"], host:"windows-terminal",
        prompt_id:"demo-1", terminal_index:-1, detected_at:1718592000000 }
; the user's exact live case: panel Write, now a readable path (was raw JSON)
p2 := { project_name:"claude-approve", tool_name:"Write", tool_input_short:"новый_файл.txt",
        kind:"permission", options:["Allow","Always allow","Deny"], host:"vscode-extension",
        prompt_id:"demo-2", terminal_index:-1, detected_at:1718592001000 }
; newest = bottom = footer hint. Long picker question (panel host) → must clip
; to 2 lines with a trailing "…", not a hard cut mid-thought.
p3 := { project_name:"claude-approve", tool_name:"AskUserQuestion",
        tool_input_short:"Это очень длинный вопрос, который занимает несколько строк и содержит много информации о том, что нужно выбрать правильный вариант ответа из списка, учитывая все факторы",
        kind:"picker", options:[], host:"vscode-extension",
        prompt_id:"demo-3", terminal_index:-1, detected_at:1718592002000 }

PromptPopup.Show([p1, p2, p3])
SetTimer(PromptPopup._refreshFn, 0)    ; freeze reconcile so the cards persist

Sleep 950    ; let the appear animation settle to peak alpha

; Capture only the bottom-right popup column (privacy + focus on the cards).
capW := Round(640 * sc) + Round(56 * sc)
capX := wr - capW
capH := Min(820, Round((wb - wt) * 0.78))
capY := wb - capH
region := capX "|" capY "|" capW "|" capH
pBM := Gdip_BitmapFromScreen(region)
if (pBM > 0) {
    Gdip_SaveBitmapToFile(pBM, OUT)
    try Gdip_DisposeImage(pBM)
    FileAppend("saved " OUT "`nregion=" region " monitor=" target "/" MonitorGetCount()
        . " sc=" Round(sc, 3) "`n", SHOTLOG)
} else {
    FileAppend("capture failed ret=" pBM " region=" region "`n", SHOTLOG)
}

PromptPopup.Hide()
ExitApp(0)
