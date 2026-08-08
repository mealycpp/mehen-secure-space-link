$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Open = Join-Path $Root "OPEN_BOTH_FPRIME_GUIS.ps1"
if (-not (Test-Path $Open)) {
    Write-Host "ERROR: OPEN_BOTH_FPRIME_GUIS.ps1 not found."
    exit 1
}
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Open"
