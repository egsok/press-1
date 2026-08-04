# press-1 — disable the experimental Codex-panel proxy channel. Removes the
# `chatgpt.cliExecutable` setting so the panel goes back to the bundled Codex.
# Design: docs/DESIGN-CODEX-PROXY.md (§2). Re-enable: enable-codex-proxy.ps1
#
#   .\disable-codex-proxy.ps1
#
# Safe to run any time (idempotent): if the setting isn't present, it does nothing.
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning "Node.js is required to edit settings.json safely. Install it, then re-run — or remove the"
    Write-Warning "  ``chatgpt.cliExecutable`` line from VS Code settings.json by hand."
    exit 1
}

node "$PSScriptRoot\codex-proxy-settings.js" disable
if ($LASTEXITCODE -ne 0) {
    Write-Warning "codex-proxy-settings.js disable failed (exit $LASTEXITCODE). Remove the ``chatgpt.cliExecutable`` line manually."
    exit 1
}

$DeployExe = Join-Path $env:USERPROFILE "scripts\codex-mitm.exe"

Write-Host ""
Write-Host "Codex proxy channel: OFF." -ForegroundColor Green
Write-Host "  Next: Reload VS Code windows once so the panel returns to the bundled Codex."
Write-Host "  The wrapper exe was left in place (inert without the setting): $DeployExe"
Write-Host "  To delete it fully: Remove-Item -LiteralPath '$DeployExe'"
Write-Host "  (The settings.json backup — settings.json.press1-bak — is kept and never removed.)"
