$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "start_stack_clean_bootstrap.log"
Start-Transcript -Path $Log -Append | Out-Null
Write-Host "============================================================"
Write-Host " MEHEN START STACK: CLEAN + OPEN BOTH F-PRIME GUIS"
Write-Host "============================================================"
Write-Host "Operator-safe path: clean both AUPs, start both flight apps/GDS, create tunnels, open both F-Prime GUIs."
Write-Host "After both GUIs are open, use CHECK + PRIME F-PRIME, then ESTABLISH SECURE CHANNEL."
Write-Host ""
$Launcher = Join-Path $Root "CLEAN_AND_OPEN_BOTH_FPRIME.ps1"
if (-not (Test-Path $Launcher)) {
    Write-Host "ERROR: CLEAN_AND_OPEN_BOTH_FPRIME.ps1 missing."
    exit 1
}
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Launcher"
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Host ("START STACK FAILED before ready. RC={0}" -f $rc)
    Stop-Transcript | Out-Null
    exit $rc
}
Write-Host "============================================================"
Write-Host " START STACK COMPLETE - BOTH GDS AND TUNNELS READY"
Write-Host "============================================================"
Stop-Transcript | Out-Null
exit 0
