# press-1 — one-line installer.
#
#   irm https://raw.githubusercontent.com/egsok/press-1/main/bootstrap.ps1 | iex
#
# Prefer to read the code first? Use the high-trust path instead — clone, look
# it over, then run the very same installer:
#   git clone https://github.com/egsok/press-1; cd press-1; .\install.ps1
#
# This downloads press-1, installs its prerequisites (AutoHotkey v2 and Node.js,
# via winget, only if they're missing), and runs the installer.

$ErrorActionPreference = "Stop"
Write-Host "press-1 bootstrap" -ForegroundColor Cyan

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning "winget (App Installer) is needed for the one-line install."
    Write-Warning "Get it from the Microsoft Store, or use the manual steps:"
    Write-Warning "  https://github.com/egsok/press-1#install"
    return
}

$zip  = Join-Path $env:TEMP "press-1-main.zip"
$dest = Join-Path $env:TEMP "press-1-src"
Write-Host "Downloading press-1..."
Invoke-WebRequest -Uri "https://codeload.github.com/egsok/press-1/zip/refs/heads/main" -OutFile $zip
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Expand-Archive -Path $zip -DestinationPath $dest -Force
$repo = Join-Path $dest "press-1-main"

Write-Host "Running the installer..."
# -ExecutionPolicy Bypass so a default RemoteSigned machine doesn't block the
# downloaded script; -Yes installs prerequisites without extra prompts (you
# already opted into the one-liner).
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "install.ps1") -Yes

Write-Host ""
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Installer reported problems (exit $LASTEXITCODE). Scroll up for details, fix them, then re-run."
} else {
    Write-Host "press-1 is set up. Reload (or close) your editor windows once (VS Code / Cursor / Windsurf) to" -ForegroundColor Green
    Write-Host "unload the old companion extension, and you're done. (A first-time install can skip this.)" -ForegroundColor Green
}
