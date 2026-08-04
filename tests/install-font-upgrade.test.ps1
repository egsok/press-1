$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testParent = Join-Path ([IO.Path]::GetTempPath()) 'press-1-tests'
$testRoot = Join-Path $testParent "install-font-upgrade-$PID"
$realAhk = @(
    'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$nodeDir = Split-Path -Parent (Get-Command node -ErrorAction Stop).Source
$passed = 0
$failed = 0
$startedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

if (-not $realAhk) {
    throw 'AutoHotkey v2 is required for the installer font-lock regression.'
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "  PASS $Name"
    } else {
        $script:failed++
        Write-Host "  FAIL $Name${Detail}" -ForegroundColor Red
    }
}

function Stop-TestProcess {
    param([int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $ProcessId -Timeout 5 -ErrorAction SilentlyContinue
}

function Clear-TestRoot {
    $resolvedParent = [IO.Path]::GetFullPath($testParent).TrimEnd('\') + '\'
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $testLeaf = Split-Path -Leaf $resolvedTest
    if (-not $resolvedTest.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $testLeaf -notmatch '^install-font-upgrade-\d+$') {
        throw "Refusing to clean unexpected test path: $resolvedTest"
    }

    $processIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($started in $startedProcesses) {
        $null = $processIds.Add($started.Id)
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^AutoHotkey(?:32|64)?\.exe$' -and $_.CommandLine -and
        $_.CommandLine.IndexOf($resolvedTest, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { $null = $processIds.Add([int]$_.ProcessId) }
    foreach ($processId in $processIds) {
        Stop-TestProcess $processId
    }

    for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $resolvedTest); $attempt++) {
        try {
            Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction Stop
        } catch {
            if ($attempt -eq 20) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    if (Test-Path -LiteralPath $resolvedTest) {
        throw "Test cleanup left its sandbox behind: $resolvedTest"
    }
}

function Get-ExactResident {
    param([string]$ScriptPath)
    $fullScript = [IO.Path]::GetFullPath($ScriptPath)
    @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        if ($_.Name -notmatch '^AutoHotkey(?:32|64)?\.exe$' -or
            -not $_.ExecutablePath -or -not $_.CommandLine) {
            return $false
        }
        $escapedExe = [Regex]::Escape([IO.Path]::GetFullPath($_.ExecutablePath))
        $exeAtStart = [Regex]::Match($_.CommandLine, '(?i)^\s*(?:"' + $escapedExe + '"|' + $escapedExe + ')(?=\s|$)')
        if (-not $exeAtStart.Success) { return $false }
        $remaining = $_.CommandLine.Substring($exeAtStart.Length).TrimStart()
        $quotedScript = '"' + $fullScript + '"'
        $remaining.StartsWith($quotedScript, [StringComparison]::OrdinalIgnoreCase) -and
            ($remaining.Length -eq $quotedScript.Length -or [char]::IsWhiteSpace($remaining[$quotedScript.Length]))
    })
}

function Write-TestResident {
    param([string]$Path, [string]$Marker)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    @"
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; $Marker
fontPath := EnvGet("USERPROFILE") "\scripts\fonts\IBMPlexMono-Medium.ttf"
hFile := DllCall("Kernel32\CreateFileW", "str", fontPath, "uint", 0x80000000, "uint", 1, "ptr", 0, "uint", 3, "uint", 0x80, "ptr", 0, "ptr")
if (hFile = -1)
    ExitApp(2)
readyPath := EnvGet("PRESS1_TEST_READY")
if (readyPath != "" && !FileExist(readyPath))
    FileAppend("ready", readyPath)
"@ | Set-Content -LiteralPath $Path -Encoding utf8
}

function Start-TestResident {
    param([pscustomobject]$Case)
    $savedProfile = $env:USERPROFILE
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    $savedReady = $env:PRESS1_TEST_READY
    try {
        $env:USERPROFILE = $Case.Profile
        $env:TEMP = Join-Path $Case.Profile 'Temp'
        $env:TMP = $env:TEMP
        $env:PRESS1_TEST_READY = $Case.Ready
        New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
        $proc = Start-Process -FilePath $realAhk -ArgumentList "`"$($Case.Script)`"" -WindowStyle Hidden -PassThru
        $script:startedProcesses.Add($proc)
    } finally {
        $env:USERPROFILE = $savedProfile
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
        $env:PRESS1_TEST_READY = $savedReady
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $Case.Ready) -and [DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) { throw "Test resident exited early with code $($proc.ExitCode)." }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $Case.Ready)) { throw 'Timed out waiting for test resident.' }
    return $proc
}

function Start-UnrelatedLocker {
    param([string]$ScriptPath, [string]$FontPath, [string]$ReadyPath, [string]$Press1PathArgument)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ScriptPath) | Out-Null
    $fontLiteral = $FontPath.Replace('`', '``').Replace('"', '`"')
    $readyLiteral = $ReadyPath.Replace('`', '``').Replace('"', '`"')
    @"
#Requires AutoHotkey v2.0
#SingleInstance Off
fontPath := "$fontLiteral"
readyPath := "$readyLiteral"
hFile := DllCall("Kernel32\CreateFileW", "str", fontPath, "uint", 0x80000000, "uint", 1, "ptr", 0, "uint", 3, "uint", 0x80, "ptr", 0, "ptr")
if (hFile = -1)
    ExitApp(2)
FileAppend("ready", readyPath)
Loop
    Sleep(100)
"@ | Set-Content -LiteralPath $ScriptPath -Encoding utf8
    $proc = Start-Process -FilePath $realAhk -ArgumentList "`"$ScriptPath`" `"$Press1PathArgument`"" -WindowStyle Hidden -PassThru
    $script:startedProcesses.Add($proc)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $ReadyPath) -and [DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) { throw "Unrelated locker exited early with code $($proc.ExitCode)." }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $ReadyPath)) { throw 'Timed out waiting for unrelated locker.' }
    return $proc
}

function Invoke-SandboxInstall {
    param([pscustomobject]$Case)
    $saved = @{}
    $overrides = @{
        USERPROFILE = $Case.Profile
        APPDATA = (Join-Path $Case.Profile 'AppData\Roaming')
        LOCALAPPDATA = (Join-Path $Case.Profile 'AppData\Local')
        CODEX_HOME = (Join-Path $Case.Profile '.codex')
        TEMP = (Join-Path $Case.Profile 'Temp')
        TMP = (Join-Path $Case.Profile 'Temp')
        Path = "$nodeDir;C:\Windows\System32;C:\Windows"
        PRESS1_CODEX_BIN = ''
        PRESS1_TEST_READY = $Case.Ready
    }
    foreach ($name in $overrides.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $overrides[$name], 'Process')
    }
    try {
        New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup') | Out-Null
        $output = @(& $pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Case.Installer -Yes 2>&1 | ForEach-Object { $_.ToString() })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function New-CaseSandbox {
    param([string]$Name, [switch]$ChangedFont)
    $root = Join-Path $testRoot $Name
    $source = Join-Path $root 'source'
    $profile = Join-Path $root 'profile'
    $scripts = Join-Path $profile 'scripts'
    $sourceFonts = Join-Path $source 'fonts'
    $destFonts = Join-Path $scripts 'fonts'
    New-Item -ItemType Directory -Force -Path $sourceFonts, $destFonts | Out-Null

    foreach ($file in @('install.ps1', 'permission-request.js', 'session-teardown.js', 'Gdip_All.ahk', 'press-1.ico', 'codex-permission-request.js', 'codex-reviewer.js', 'codex-attention.js', 'codex-gsd-context-monitor.js', 'merge-hooks.js', 'merge-codex-hooks.js')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $source $file) -Force
    }
    Copy-Item -Path (Join-Path $repoRoot 'fonts\*') -Destination $sourceFonts -Force
    Copy-Item -Path (Join-Path $repoRoot 'fonts\*') -Destination $destFonts -Force
    Write-TestResident (Join-Path $source 'press-1.ahk') 'NEW_BUILD'
    Write-TestResident (Join-Path $scripts 'press-1.ahk') 'OLD_BUILD'

    $fontName = 'IBMPlexMono-Medium.ttf'
    $fontDest = Join-Path $destFonts $fontName
    if ($ChangedFont) {
        Copy-Item -LiteralPath (Join-Path $sourceFonts 'IBMPlexMono-Regular.ttf') -Destination $fontDest -Force
    }
    return [pscustomobject]@{
        Root = $root
        Source = $source
        Installer = (Join-Path $source 'install.ps1')
        Profile = $profile
        Script = (Join-Path $scripts 'press-1.ahk')
        FontSource = (Join-Path $sourceFonts $fontName)
        FontDest = $fontDest
        Ready = (Join-Path $root 'resident-ready.txt')
    }
}

if (Test-Path -LiteralPath $testRoot) {
    Clear-TestRoot
}
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

try {
    Write-Host 'T1 identical locked font is skipped without lock recovery'
    $case = New-CaseSandbox 'identical'
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $case.FontDest).Hash
    $beforeWrite = (Get-Item -LiteralPath $case.FontDest).LastWriteTimeUtc
    $original = Start-TestResident $case
    $result = Invoke-SandboxInstall $case
    Start-Sleep -Milliseconds 400
    $resident = @(Get-ExactResident $case.Script)
    Check 'T1 installer exits 0' ($result.ExitCode -eq 0) "`n$($result.Output)"
    Check 'T1 identical files are explicitly skipped' ($result.Output -match 'Brand fonts already current') "`n$($result.Output)"
    Check 'T1 lock-recovery branch is not invoked' ($result.Output -notmatch 'Stopped resident press-1 AutoHotkey') "`n$($result.Output)"
    Check 'T1 press-1 remains resident after normal restart' ($resident.Count -eq 1)
    Check 'T1 locked font hash is unchanged' ((Get-FileHash -Algorithm SHA256 -LiteralPath $case.FontDest).Hash -eq $beforeHash)
    Check 'T1 locked font timestamp is unchanged' ((Get-Item -LiteralPath $case.FontDest).LastWriteTimeUtc -eq $beforeWrite)
    foreach ($proc in $resident) { Stop-TestProcess $proc.ProcessId }

    Write-Host 'T2 changed locked font stops only the exact resident and restarts it'
    $case = New-CaseSandbox 'changed' -ChangedFont
    $original = Start-TestResident $case
    $otherFont = Join-Path $case.Root 'other-font.ttf'
    [IO.File]::WriteAllBytes($otherFont, [byte[]](9, 8, 7))
    $other = Start-UnrelatedLocker (Join-Path $case.Root 'other\helper.ahk') $otherFont (Join-Path $case.Root 'other-ready.txt') $case.Script
    $result = Invoke-SandboxInstall $case
    $original.WaitForExit(5000) | Out-Null
    Start-Sleep -Milliseconds 400
    $resident = @(Get-ExactResident $case.Script)
    Check 'T2 installer exits 0' ($result.ExitCode -eq 0) "`n$($result.Output)"
    Check 'T2 changed font is replaced byte-exact' ((Get-FileHash -Algorithm SHA256 -LiteralPath $case.FontDest).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $case.FontSource).Hash)
    Check 'T2 original exact resident is stopped' $original.HasExited
    Check 'T2 press-1 is alive after verified restart' ($resident.Count -eq 1)
    Check 'T2 path passed as secondary arg does not match' (-not $other.HasExited)
    Check 'T2 restart is explicit' ($result.Output -match 'Resident AutoHotkey restarted after font update') "`n$($result.Output)"
    foreach ($proc in $resident) { Stop-TestProcess $proc.ProcessId }
    Stop-TestProcess $other.Id

    Write-Host 'T3 failed copy restarts old script and leaves the unrelated locker alone'
    $case = New-CaseSandbox 'retry-failure' -ChangedFont
    $original = Start-TestResident $case
    $other = Start-UnrelatedLocker (Join-Path $case.Root 'other\helper.ahk') $case.FontDest (Join-Path $case.Root 'other-ready.txt') $case.Script
    $result = Invoke-SandboxInstall $case
    $original.WaitForExit(5000) | Out-Null
    Start-Sleep -Milliseconds 400
    $resident = @(Get-ExactResident $case.Script)
    Check 'T3 installer fails loudly' ($result.ExitCode -ne 0) "`n$($result.Output)"
    Check 'T3 original exact resident is stopped' $original.HasExited
    Check 'T3 old press-1 is alive after failed font copy' ($resident.Count -eq 1)
    Check 'T3 unrelated locker remains running' (-not $other.HasExited)
    Check 'T3 deployed script was not overwritten before fonts' ((Get-Content -Raw -LiteralPath $case.Script) -match 'OLD_BUILD')
    Check 'T3 failure says restart succeeded' ($result.Output -match 'Font update failed; the resident press-1 process was restarted') "`n$($result.Output)"
    foreach ($proc in $resident) { Stop-TestProcess $proc.ProcessId }
    Stop-TestProcess $other.Id
} finally {
    Clear-TestRoot
}

Write-Host ""
Write-Host "Installer font-upgrade tests: $passed passed, $failed failed"
if ($failed) { exit 1 }
