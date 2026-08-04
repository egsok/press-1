param(
    [int]$Seconds = 180,
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"

$pressDir = Join-Path $env:TEMP "press-1"
$pendingDir = Join-Path $pressDir "pending"
$flagPath = Join-Path $env:USERPROFILE ".press-1-codex-native-control"
$started = Get-Date
$deadline = $started.AddSeconds($Seconds)
$logPath = Join-Path $pressDir ("codex-native-control-smoke-{0}.log" -f $started.ToString("yyyyMMdd-HHmmss"))

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss.fff"), $Message
    Write-Host $line
    New-Item -ItemType Directory -Force -Path $pressDir | Out-Null
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function TryReadPending {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function PendingFiles {
    if (-not (Test-Path -LiteralPath $pendingDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $pendingDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
}

Log "Codex native-control smoke started. Log: $logPath"
Log "Flag present: $(Test-Path -LiteralPath $flagPath) ($flagPath)"
Log "Pending dir: $pendingDir"
Log "Now trigger a Codex approval in the VS Code Codex panel, then press Ctrl+Win+1/2/3 when press-1 appears."

$targetFile = $null
$target = $null
$lastNonNative = $null

while ((Get-Date) -lt $deadline) {
    foreach ($file in PendingFiles) {
        $json = TryReadPending $file.FullName
        if (-not $json) { continue }
        $agent = [string]$json.agent
        $hostType = [string]$json.host.type
        $native = $json.PSObject.Properties.Name -contains "native_control" -and [bool]$json.native_control
        if ($agent -eq "codex" -and $hostType -eq "vscode-extension" -and $native) {
            $targetFile = $file.FullName
            $target = $json
            break
        }
        if ($agent -eq "codex" -and $hostType -eq "vscode-extension") {
            $lastNonNative = $file.FullName
        }
    }
    if ($targetFile) { break }
    Start-Sleep -Milliseconds 200
}

if (-not $targetFile) {
    if ($lastNonNative) {
        Log "FAIL: Saw Codex panel pending, but it was not native_control=true: $lastNonNative"
    } else {
        Log "FAIL: No Codex panel native-control pending observed within ${Seconds}s."
    }
    exit 2
}

$hasDecisionFile = $target.PSObject.Properties.Name -contains "decision_file" -and [string]$target.decision_file
Log "PASS: native-control pending observed: $targetFile"
Log "  id=$($target.id) project=$($target.project_name) tool=$($target.tool_name) wait_until=$($target.wait_until)"
Log "  decision_file_present=$([bool]$hasDecisionFile)"
if ($hasDecisionFile) {
    Log "FAIL: native-control pending must not carry decision_file."
    exit 3
}

Start-Sleep -Milliseconds 700
$hookAlive = $false
if ($target.hook_pid) {
    $hookAlive = [bool](Get-Process -Id ([int]$target.hook_pid) -ErrorAction SilentlyContinue)
}
Log "  hook_pid=$($target.hook_pid) alive_after_700ms=$hookAlive"
if ($hookAlive) {
    Log "WARN: hook is still alive after 700ms; native prompt may still be waiting for hook release."
}

if (-not $NoPrompt) {
    Log "Press Ctrl+Win+1/2/3 in the press-1 popup, then press Enter in this console."
    Read-Host "After pressing the press-1 hotkey, press Enter here" | Out-Null
} else {
    Log "NoPrompt mode: waiting for pending disappearance without manual confirmation."
}

Log "Waiting for pending to disappear after the native-control action."
$removeDeadline = (Get-Date).AddSeconds([Math]::Min($Seconds, 180))
while ((Get-Date) -lt $removeDeadline) {
    if (-not (Test-Path -LiteralPath $targetFile)) {
        Log "PASS: pending removed after native-control action or teardown."
        Log "Smoke log complete."
        exit 0
    }
    Start-Sleep -Milliseconds 200
}

Log "FAIL: pending still exists after waiting for hotkey/teardown: $targetFile"
exit 4
