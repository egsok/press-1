# press-1 — installer (installs missing prerequisites via winget, then restarts AHK).
#
#   .\install.ps1        prompts before installing a missing prerequisite
#   .\install.ps1 -Yes   installs missing prerequisites without prompting

param([switch]$Yes)
$ErrorActionPreference = "Stop"

# Resolve every relative path below against the script's own directory, not the
# caller's CWD. The one-line bootstrap runs `powershell -File <repo>\install.ps1`
# without cd'ing into the repo, so a bare `.\file` would look in the wrong place.
Set-Location -LiteralPath $PSScriptRoot

# AutoHotkey v2 lands in Program Files when winget installs it machine-wide, but
# in %LOCALAPPDATA% when winget installs per-user (the default without elevation).
# Resolve whichever actually exists instead of assuming one hardcoded path.
function Resolve-AhkExe {
    # Candidate AutoHotkey roots. Build from non-empty base vars only —
    # ${env:ProgramFiles(x86)} is empty on 32-bit Windows and would otherwise
    # root a candidate at the current drive ("\AutoHotkey\...").
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ 'AutoHotkey' }
    $roots += (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey')
    # AutoHotkey64.exe / AutoHotkey32.exe are v2-specific names (v1.1 uses
    # AutoHotkeyU64.exe etc.), so matching them keeps us on v2. Prefer 64-bit.
    foreach ($exe in @('AutoHotkey64.exe', 'AutoHotkey32.exe')) {
        foreach ($root in $roots) {
            $c = Join-Path $root "v2\$exe"
            if (Test-Path $c) { return $c }
        }
    }
    # Fallback: only recurse roots that exist (a missing root under
    # ErrorActionPreference=Stop would otherwise throw instead of returning null).
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter AutoHotkey64.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

# Merge the registry PATH (Machine + User) into the current process PATH WITHOUT
# discarding entries that exist only in the inherited process environment. A
# freshly winget-installed CLI is on PATH only in the registry, not yet in this
# already-running session — and a wholesale replace could drop an inherited entry
# (e.g. node) that this session needs.
function Add-MissingPathSegments {
    $existing = $env:Path -split ';'
    $fromRegistry = (@(
        [Environment]::GetEnvironmentVariable('Path','Machine'),
        [Environment]::GetEnvironmentVariable('Path','User')
    ) -join ';') -split ';'
    foreach ($seg in $fromRegistry) {
        if ($seg -and ($existing -notcontains $seg)) {
            $env:Path += ';' + $seg
            $existing += $seg
        }
    }
}

function Ensure-Dependency {
    param([string]$Name, [scriptblock]$Test, [string]$WingetId)
    if (& $Test) { return $true }
    Write-Host "$Name is required but wasn't found." -ForegroundColor Yellow
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning "winget isn't available - install $Name manually, then re-run install.ps1."
        return $false
    }
    if (-not $Yes) {
        $ans = Read-Host "Install $Name now via winget? [Y/n]"
        if ($ans -and $ans -notmatch '^(y|yes)$') {
            Write-Warning "Skipped $Name - install it manually, then re-run."
            return $false
        }
    }
    Write-Host "Installing $Name via winget..."
    # | Out-Host so winget's output is shown but does NOT pollute this function's
    # return value (otherwise the result is an array, which is always truthy).
    winget install --id $WingetId --silent --accept-package-agreements --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget exited with code $LASTEXITCODE while installing $Name."
    }
    Add-MissingPathSegments
    return [bool](& $Test)
}

# Remove the dropped companion extension from one editor's extensions dir. The
# extension is gone: the proposed scrape API it relied on is blocked for
# sideloaded extensions in the VS Code forks (Cursor/Windsurf-Devin), so every
# editor terminal now rides the hook-decision channel. Best-effort: a leftover
# dir (e.g. locked while the editor is open) is a warning, not a hard failure —
# the final reload step unloads any still-running copy.
function Remove-Companion {
    param([string]$ExtensionsRoot)
    $extDir = Join-Path $ExtensionsRoot "press-1-companion"
    if (-not (Test-Path $extDir)) { return }
    try {
        Remove-Item -Recurse -Force $extDir
        Write-Host "Removed old companion extension from $ExtensionsRoot."
    } catch {
        Write-Warning "Couldn't remove old companion extension at ${extDir}: $($_.Exception.Message)"
        Write-Warning "  Close that editor and re-run install.ps1, or delete the folder manually."
    }
}

$problems = @()

# --- Prerequisites: offer to install whatever's missing ---
$okAhk  = Ensure-Dependency "AutoHotkey v2" { [bool](Resolve-AhkExe) } "AutoHotkey.AutoHotkey"
$okNode = Ensure-Dependency "Node.js" { [bool](Get-Command node -ErrorAction SilentlyContinue) } "OpenJS.NodeJS"
$ahkExe = Resolve-AhkExe
if (-not ($okAhk -and $ahkExe)) {
    $problems += "AutoHotkey v2 not found - the popup and hotkeys won't run. Install it, then re-run install.ps1."
}

# --- Copy files (directories may be absent on a clean machine) ---
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\hooks" | Out-Null
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\scripts" | Out-Null
Copy-Item ".\permission-request.js" "$env:USERPROFILE\.claude\hooks\permission-request.js" -Force
Copy-Item ".\session-teardown.js" "$env:USERPROFILE\.claude\hooks\session-teardown.js" -Force
Copy-Item ".\press-1.ahk" "$env:USERPROFILE\scripts\press-1.ahk" -Force
Copy-Item ".\Gdip_All.ahk" "$env:USERPROFILE\scripts\Gdip_All.ahk" -Force
Copy-Item ".\press-1.ico" "$env:USERPROFILE\scripts\press-1.ico" -Force
Write-Host "Files copied."

# --- Merge hooks into ~\.claude\settings.json (safe) ---
if (Get-Command node -ErrorAction SilentlyContinue) {
    node "$PSScriptRoot\merge-hooks.js"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "merge-hooks.js couldn't update settings.json - add hooks manually (see README)."
        $problems += "Hooks NOT registered in settings.json (merge-hooks.js failed) - add them manually (see README)."
    }
} else {
    Write-Warning "node not on PATH - add hooks to ~\.claude\settings.json manually (see README)."
    $problems += "Node.js not available - hooks NOT registered in settings.json. Install Node.js, then re-run install.ps1."
}

# --- Startup shortcut (only if AutoHotkey is actually present).
#     Always (re)write it so a stale target from an earlier run is corrected. ---
if ($okAhk -and $ahkExe) {
    try {
        $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\press-1.lnk"
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($startupPath)
        $Shortcut.TargetPath = $ahkExe
        $Shortcut.Arguments = "`"$env:USERPROFILE\scripts\press-1.ahk`""
        $Shortcut.WorkingDirectory = "$env:USERPROFILE\scripts"
        $Shortcut.Description = "press-1 - permission prompt hotkeys"
        $Shortcut.Save()
        Write-Host "Startup shortcut written."
    } catch {
        Write-Warning "Couldn't write startup shortcut: $($_.Exception.Message)"
        $problems += "Couldn't write startup shortcut (press-1 won't auto-start on login): $($_.Exception.Message)"
    }
} else {
    Write-Warning "Skipping startup shortcut - AutoHotkey v2 isn't installed."
}

# --- Sweep the dropped companion extension from every editor (VS Code plus the
#     Cursor/Windsurf forks). Removing the folder stops the editor from re-loading
#     it; the final reload step unloads any copy still running in memory. ---
$companionRoots = @(
    "$env:USERPROFILE\.vscode\extensions",
    "$env:USERPROFILE\.cursor\extensions",
    "$env:USERPROFILE\.windsurf\extensions"
)
foreach ($root in $companionRoots) {
    Remove-Companion $root
}

# --- (Re)start the resident script so the new version is live.
#     SingleInstance Force replaces any running instance. Path is quoted because
#     the user profile can contain spaces (e.g. "C:\Users\First Last"). ---
if ($okAhk -and $ahkExe) {
    try {
        Start-Process -FilePath $ahkExe -ArgumentList "`"$env:USERPROFILE\scripts\press-1.ahk`""
        Write-Host "AutoHotkey (re)started."
    } catch {
        Write-Warning "Couldn't start AutoHotkey: $($_.Exception.Message)"
        $problems += "Couldn't start AutoHotkey ($ahkExe): $($_.Exception.Message)"
    }
}

Write-Host ""
if ($problems.Count) {
    Write-Warning "press-1 install finished WITH PROBLEMS:"
    foreach ($p in $problems) { Write-Warning "  - $p" }
    Write-Host "Fix the above, then re-run install.ps1."
    exit 1
}
Write-Host "Done. One thing left:"
Write-Host "  Reload (or close) your editor windows once (VS Code / Cursor / Windsurf) - this unloads the"
Write-Host "  old companion extension. Until you do, an upgraded install may keep the old extension running,"
Write-Host "  which sweeps terminal prompts early and breaks the hotkey window. New installs can skip this."
