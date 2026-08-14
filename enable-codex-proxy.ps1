# press-1 — enable the EXPERIMENTAL Codex-panel proxy channel (opt-in, use at your
# own risk). Builds the codex-mitm wrapper as a Node SEA .exe, deploys it next to
# press-1.ahk, and points VS Code's `chatgpt.cliExecutable` at it so the ChatGPT/
# Codex panel routes command approvals through press-1's hotkey popup.
# Design + risks: docs/DESIGN-CODEX-PROXY.md (§2, §6, §9). Undo: disable-codex-proxy.ps1
#
#   .\enable-codex-proxy.ps1
#
# Re-running is safe (idempotent): it rebuilds the exe and re-points the setting.
$ErrorActionPreference = "Stop"

# Resolve paths against the script's own directory, not the caller's CWD.
Set-Location -LiteralPath $PSScriptRoot

$DeployExe = Join-Path $env:USERPROFILE "scripts\codex-mitm.exe"
$Fuse = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"  # standard Node SEA sentinel fuse

# Newest Codex extension bundle (openai.chatgpt-<semver>-win32-x64), by version.
# The wrapper resolves this itself at runtime; we check here only to fail loud
# when the extension isn't installed.
function Find-CodexBundle {
    $extRoot = Join-Path $env:USERPROFILE ".vscode\extensions"
    if (-not (Test-Path $extRoot)) { return $null }
    $best = $null; $bestVer = $null
    Get-ChildItem -LiteralPath $extRoot -Directory -Filter "openai.chatgpt-*-win32-x64" -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '^openai\.chatgpt-(\d+(?:\.\d+)+)-win32-x64$') {
                try { $ver = [version]$matches[1] } catch { return }
                $exe = Join-Path $_.FullName "bin\windows-x86_64\codex.exe"
                if ((Test-Path $exe) -and ($null -eq $bestVer -or $ver -gt $bestVer)) {
                    $bestVer = $ver; $best = $exe
                }
            }
        }
    return $best
}

# --- Prerequisites ---------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning "Node.js is required to build the wrapper. Install it (winget install OpenJS.NodeJS), then re-run."
    exit 1
}
$bundle = Find-CodexBundle
if (-not $bundle) {
    Write-Warning "Codex bundle not found under ~\.vscode\extensions\openai.chatgpt-*-win32-x64\bin\windows-x86_64\codex.exe."
    Write-Warning "Install the ChatGPT/Codex VS Code extension (and open the panel once), then re-run."
    exit 1
}
Write-Host "Found Codex bundle: $bundle"

$repoMitm = Join-Path $PSScriptRoot "codex-mitm.js"
if (-not (Test-Path $repoMitm)) {
    Write-Warning "codex-mitm.js not found in repo ($repoMitm) — cannot build."
    exit 1
}

# A running wrapper holds a lock on the deployed exe: the copy below can fail, and
# a copy that succeeds won't take effect until VS Code panels reload.
$running = Get-Process codex-mitm -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Note: codex-mitm.exe is already running (pid $($running.Id -join ', ')). The old build stays live until you Reload VS Code windows."
}

# --- Build the SEA .exe (recipe proven in spikes/codex-proxy) --------------
New-Item -ItemType Directory -Force -Path (Split-Path $DeployExe) | Out-Null
$buildDir = Join-Path $env:TEMP ("press-1-codex-build-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
try {
    # Copy the source into the build dir and reference it locally (keeps the SEA
    # config's `main` self-contained regardless of the repo path).
    $localMitm = Join-Path $buildDir "codex-mitm.js"
    Copy-Item -LiteralPath $repoMitm -Destination $localMitm -Force

    $seaConfig = Join-Path $buildDir "sea-config.json"
    ([ordered]@{
        main                          = $localMitm
        output                        = "sea-prep.blob"
        disableExperimentalSEAWarning = $true
    } | ConvertTo-Json) | Set-Content -LiteralPath $seaConfig -Encoding utf8

    $buildExe = Join-Path $buildDir "codex-mitm.exe"

    Push-Location $buildDir
    try {
        Write-Host "Generating SEA blob..."
        node --experimental-sea-config sea-config.json
        if ($LASTEXITCODE -ne 0) { throw "node --experimental-sea-config failed (exit $LASTEXITCODE)." }

        Copy-Item -LiteralPath (Get-Command node).Source -Destination $buildExe -Force

        Write-Host "Injecting blob with postject..."
        npx --yes postject codex-mitm.exe NODE_SEA_BLOB sea-prep.blob --sentinel-fuse $Fuse
        if ($LASTEXITCODE -ne 0) { throw "postject failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }

    # Smoke test: the wrapper relays --version to the real bundle, which prints
    # `codex-cli`. Anything else means the build or bundle resolution is broken.
    $ver = (& $buildExe --version 2>&1 | Out-String).Trim()
    if ($ver -notmatch 'codex-cli') {
        throw "SEA smoke test failed: ``$buildExe --version`` returned '$ver' (expected 'codex-cli')."
    }
    Write-Host "SEA smoke test passed ($ver)."

    # Deploy next to press-1.ahk.
    try {
        Copy-Item -LiteralPath $buildExe -Destination $DeployExe -Force
    } catch {
        Write-Warning "Couldn't write $DeployExe (a running wrapper may hold it locked): $($_.Exception.Message)"
        Write-Warning "Close/Reload your VS Code windows, then re-run enable-codex-proxy.ps1."
        exit 1
    }
    Write-Host "Deployed wrapper: $DeployExe"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $buildDir -ErrorAction SilentlyContinue
}

# --- Point the setting (JSONC-safe, via the Node helper) -------------------
node "$PSScriptRoot\codex-proxy-settings.js" enable $DeployExe
$code = $LASTEXITCODE
if ($code -eq 2) {
    # WSL mode: the helper already explained; the wrapper is Windows-only.
    exit 2
}
if ($code -ne 0) {
    Write-Warning "codex-proxy-settings.js enable failed (exit $code). The setting was NOT changed; the deployed exe is inert."
    exit 1
}

# --- Done ------------------------------------------------------------------
Write-Host ""
Write-Host "Codex proxy channel: ON (experimental)." -ForegroundColor Green
Write-Host "  Next: Reload VS Code windows once so the panel picks up the wrapper."
Write-Host "  To turn it off: .\disable-codex-proxy.ps1"
Write-Host "  Risk: the wrapper sits in the panel's critical path — if the panel breaks," -ForegroundColor Yellow
Write-Host "        run .\disable-codex-proxy.ps1 and reload VS Code to recover." -ForegroundColor Yellow
