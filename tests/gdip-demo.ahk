; GDI+ renderer VISUAL demo (BACKLOG 11). Shows a 3-card stack with the real
; renderer for ~20 s so the design can be eyeballed / screenshotted, then exits.
; Auto-targets a 1080p monitor if present (to check relative scaling), else the
; primary. Suspends this process's hotkeys + hides its tray icon so it never
; clashes with a running daily-driver press-1.
; Run: AutoHotkey64.exe tests\gdip-demo.ahk   (note chosen monitor in gdip-demo.txt)
#NoTrayIcon
#Include %A_ScriptDir%\..\press-1.ahk

Suspend True                    ; this demo's hotkeys must not fight the live tool
SetTimer(AutoShowCheck, 0)

DirCreate(A_Temp "\press-1-tests")
OUT := A_Temp "\press-1-tests\gdip-demo.txt"
try FileDelete(OUT)

if !PromptPopup.EnsureGdip() {
    FileAppend("GDI+ failed to start`n", OUT)
    ExitApp(1)
}

; Prefer a 1080p monitor (full-bounds height = 1080) so we can see the smaller
; relative scale; fall back to the primary monitor otherwise.
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
fsc := Min(1.0, 0.64 + 0.40 * sc)
FileAppend("monitor=" target "/" MonitorGetCount() " workarea=" (wr-wl) "x" (wb-wt)
    . " sc=" Round(sc, 3) " fsc=" Round(fsc, 3) "`n", OUT)

; oldest = index 1 = top of stack = active ring by default. Long command → 2-line wrap.
p1 := { project_name:"my-api-server", tool_name:"Bash",
        tool_input_short:"docker compose -f docker-compose.prod.yml up -d --build --remove-orphans --scale worker=4",
        kind:"permission", options:["Allow","Always allow","Deny"], host:"windows-terminal",
        prompt_id:"demo-1", terminal_index:-1, detected_at:1718592000000 }
; short command → single line (height contrast against the 2-line cards)
p2 := { project_name:"web-frontend", tool_name:"Edit", tool_input_short:"vite.config.ts",
        kind:"permission", options:["Allow","Deny"], host:"vscode-extension",
        prompt_id:"demo-2", terminal_index:-1, detected_at:1718592001000 }
; newest = bottom of stack = footer hint. Long picker question → 2-line wrap, no wrapper.
p3 := { project_name:"claude-approve", tool_name:"AskUserQuestion",
        tool_input_short:"Ты ж знаешь, что я совсем недавно начал разбираться с этим — какой вариант выберем?",
        kind:"picker", options:[], host:"vscode-extension",
        prompt_id:"demo-3", terminal_index:-1, detected_at:1718592002000 }

PromptPopup.Show([p1, p2, p3])
SetTimer(PromptPopup._refreshFn, 0)    ; freeze reconcile so the demo cards persist

Sleep 20000
PromptPopup.Hide()
ExitApp(0)
