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
    if (-not (Test-Path $extDir)) { return $false }
    try {
        Remove-Item -Recurse -Force $extDir
        Write-Host "Removed old companion extension from $ExtensionsRoot."
    } catch {
        Write-Warning "Couldn't remove old companion extension at ${extDir}: $($_.Exception.Message)"
        Write-Warning "  Close that editor and re-run install.ps1, or delete the folder manually."
    }
    return $true
}

# Match only AutoHotkey processes whose FIRST operand is the exact absolute
# press-1 script path. A helper script may receive that same path as data; it
# must never be stopped during an upgrade.
function Get-ResidentPress1Ahk {
    param([string]$ScriptPath)
    $fullScriptPath = [IO.Path]::GetFullPath($ScriptPath)
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.Name -notmatch '^AutoHotkey(?:32|64)?\.exe$' -or
            -not $_.ExecutablePath -or -not $_.CommandLine) {
            return $false
        }

        $escapedExe = [Regex]::Escape([IO.Path]::GetFullPath($_.ExecutablePath))
        $exeAtStart = [Regex]::Match($_.CommandLine, '(?i)^\s*(?:"' + $escapedExe + '"|' + $escapedExe + ')(?=\s|$)')
        if (-not $exeAtStart.Success) { return $false }

        $remaining = $_.CommandLine.Substring($exeAtStart.Length).TrimStart()
        $quotedScript = '"' + $fullScriptPath + '"'
        if ($remaining.StartsWith($quotedScript, [StringComparison]::OrdinalIgnoreCase)) {
            return $remaining.Length -eq $quotedScript.Length -or
                   [char]::IsWhiteSpace($remaining[$quotedScript.Length])
        }
        if ($fullScriptPath -notmatch '\s' -and
            $remaining.StartsWith($fullScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $remaining.Length -eq $fullScriptPath.Length -or
                   [char]::IsWhiteSpace($remaining[$fullScriptPath.Length])
        }
        return $false
    })
}

function Start-ResidentPress1Ahk {
    param([string]$AhkExe, [string]$ScriptPath)
    $process = Start-Process -FilePath $AhkExe -ArgumentList "`"$ScriptPath`"" -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 300
    if ($process.HasExited) {
        throw "AutoHotkey exited immediately with code $($process.ExitCode) while starting '$ScriptPath'."
    }
}

# AddFontResourceEx keeps deployed TTFs open while press-1 is resident. Avoid
# touching byte-identical files (the common reinstall path). If an existing file
# genuinely differs, stop only the exact resident before copying, then restart
# it in finally even when the copy fails. New files never require a stop.
function Copy-BrandFonts {
    param([string]$SourceDir, [string]$DestinationDir, [string]$AhkExe, [string]$ScriptPath)
    if (-not (Test-Path -LiteralPath $SourceDir)) { return }

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    $pending = @()
    foreach ($source in @(Get-ChildItem -LiteralPath $SourceDir -File)) {
        $destination = Join-Path $DestinationDir $source.Name
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        $same = $false
        if ($exists) {
            $same = $source.Length -eq (Get-Item -LiteralPath $destination).Length -and
                    (Get-FileHash -Algorithm SHA256 -LiteralPath $source.FullName).Hash -eq
                    (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
        }
        if (-not $same) {
            $pending += [pscustomobject]@{
                Source = $source.FullName
                Destination = $destination
                ReplacesExisting = $exists
            }
        }
    }

    if (-not $pending.Count) {
        Write-Host 'Brand fonts already current; identical files skipped.'
        return
    }

    $changedExisting = @($pending | Where-Object { $_.ReplacesExisting })
    $resident = if ($changedExisting.Count) { @(Get-ResidentPress1Ahk $ScriptPath) } else { @() }
    if (-not $resident.Count) {
        foreach ($file in $pending) {
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
        }
        Write-Host 'Brand fonts updated.'
        return
    }
    if (-not ($AhkExe -and (Test-Path -LiteralPath $AhkExe -PathType Leaf))) {
        throw "Bundled fonts changed while press-1 is running, but AutoHotkey could not be resolved for a guaranteed restart. Close press-1 and re-run install.ps1."
    }

    $updateError = $null
    $restartError = $null
    $stoppedAny = $false
    try {
        foreach ($process in $resident) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            $stoppedAny = $true
            Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
        }
        Write-Host 'Stopped resident press-1 AutoHotkey to update changed fonts.'
        foreach ($file in $pending) {
            Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
        }
    } catch {
        $updateError = $_
    } finally {
        if ($stoppedAny) {
            try {
                Start-ResidentPress1Ahk $AhkExe $ScriptPath
                Write-Host 'Resident AutoHotkey restarted after font update.'
            } catch {
                $restartError = $_
            }
        }
    }

    if ($updateError -and $restartError) {
        throw "Font update failed and press-1 could not be restarted. Update error: $($updateError.Exception.Message) Restart error: $($restartError.Exception.Message)"
    }
    if ($updateError -and -not $stoppedAny) {
        throw "Font update failed before press-1 was stopped; no restart was needed. Error: $($updateError.Exception.Message)"
    }
    if ($updateError) {
        throw "Font update failed; the resident press-1 process was restarted. Error: $($updateError.Exception.Message)"
    }
    if ($restartError) {
        throw "Fonts were updated, but press-1 could not be restarted: $($restartError.Exception.Message)"
    }
    Write-Host 'Brand fonts updated.'
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
# Update process-private fonts before overwriting the resident script. If a font
# copy fails after we stop press-1, finally can still restart the old known-good
# script rather than a half-upgraded one.
if (Test-Path ".\fonts") {
    Copy-BrandFonts ".\fonts" "$env:USERPROFILE\scripts\fonts" $ahkExe "$env:USERPROFILE\scripts\press-1.ahk"
}
Copy-Item ".\permission-request.js" "$env:USERPROFILE\.claude\hooks\permission-request.js" -Force
Copy-Item ".\session-teardown.js" "$env:USERPROFILE\.claude\hooks\session-teardown.js" -Force
Copy-Item ".\press-1.ahk" "$env:USERPROFILE\scripts\press-1.ahk" -Force
Copy-Item ".\Gdip_All.ahk" "$env:USERPROFILE\scripts\Gdip_All.ahk" -Force
Copy-Item ".\press-1.ico" "$env:USERPROFILE\scripts\press-1.ico" -Force
# Codex CLI hook (scenario A/B/C for Codex users), deployed under ~\.codex\hooks
# so the Codex Stop/PostToolUse commands resolve there too. codex-reviewer.js is
# the auto-review detector module required by the hook (same dir).
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.codex\hooks" | Out-Null
Copy-Item ".\codex-permission-request.js" "$env:USERPROFILE\.codex\hooks\codex-permission-request.js" -Force
Copy-Item ".\codex-reviewer.js" "$env:USERPROFILE\.codex\hooks\codex-reviewer.js" -Force
Copy-Item ".\codex-attention.js" "$env:USERPROFILE\.codex\hooks\codex-attention.js" -Force
Copy-Item ".\codex-gsd-context-monitor.js" "$env:USERPROFILE\.codex\hooks\codex-gsd-context-monitor.js" -Force
Copy-Item ".\session-teardown.js" "$env:USERPROFILE\.codex\hooks\session-teardown.js" -Force
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

# --- Merge hooks into ~\.codex\hooks.json (Codex CLI/Desktop, wrapper schema + auto-trust) ---
# Exit 1 = hooks.json merge failed. Exit 2 = hooks were registered safely, but
# trust could not be verified. Exit 3 = Codex is not installed (optional surface).
if (Get-Command node -ErrorAction SilentlyContinue) {
    node "$PSScriptRoot\merge-codex-hooks.js"
    $codexMergeExit = $LASTEXITCODE
    if ($codexMergeExit -eq 2) {
        Write-Warning "Codex hooks were registered, but their trust could not be verified. Run 'codex', enter '/hooks', and approve the press-1 entries (install/update Codex CLI first if the command is unavailable)."
        $problems += "Codex hooks installed but NOT TRUSTED - run 'codex', enter '/hooks', approve press-1, then re-run install.ps1 (install/update Codex CLI first if needed)."
    } elseif ($codexMergeExit -eq 3) {
        Write-Warning "Codex support was skipped because Codex CLI/Desktop was not found. Claude Code support is installed; install Codex later and re-run install.ps1 to enable Codex support."
    } elseif ($codexMergeExit -ne 0) {
        Write-Warning "merge-codex-hooks.js couldn't update ~\.codex\hooks.json - add the Codex hooks manually (see README)."
        $problems += "Codex hooks NOT registered in ~\.codex\hooks.json (merge-codex-hooks.js failed) - add them manually (see README)."
    }
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
$companionFound = $false
foreach ($root in $companionRoots) {
    if (Remove-Companion $root) { $companionFound = $true }
}

# --- (Re)start the resident script so the new version is live.
#     SingleInstance Force replaces any running instance. Path is quoted because
#     the user profile can contain spaces (e.g. "C:\Users\First Last"). ---
if ($okAhk -and $ahkExe) {
    try {
        Start-ResidentPress1Ahk $ahkExe "$env:USERPROFILE\scripts\press-1.ahk"
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
# The reload reminder only applies to upgrades from the pre-v6.2 companion era —
# a fresh install (every public-repo user) never had the extension.
if ($companionFound) {
    Write-Host "Done. One thing left:"
    Write-Host "  Reload (or close) your editor windows once (VS Code / Cursor / Windsurf) - this unloads the"
    Write-Host "  old companion extension. Until you do, it may keep running, sweeping terminal prompts early"
    Write-Host "  and breaking the hotkey window."
} else {
    Write-Host "Done."
}
