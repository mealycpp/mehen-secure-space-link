$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "aup1_fprime_terminal.log"
Start-Transcript -Path $Log -Append | Out-Null

Write-Host "============================================================"
Write-Host " MEHEN AUP1 F-PRIME TERMINAL"
Write-Host " AUP1 = 100.116.148.59"
Write-Host "============================================================"
Write-Host "Starts AupZu3 and F-Prime GDS with a watchdog. If the flight app dies, this terminal restarts it."
Write-Host "Flight port preference: 50000 then 50100. Remote GDS web port: 5000."
Write-Host "If prompted, enter the xilinx password. Keep this terminal open during the demo."

$Helper = Join-Path $Root "fprime_watchdog_remote.sh"
if (-not (Test-Path $Helper)) {
    Write-Host "[AUP1] ERROR: missing fprime_watchdog_remote.sh"
    Stop-Transcript | Out-Null
    Read-Host "Press ENTER to close"
    exit 1
}

Write-Host "[AUP1] Copying watchdog helper to board"
& scp "$Helper" "xilinx@100.116.148.59:/tmp/mehen_fprime_watchdog.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[AUP1] ERROR: scp failed"
    Stop-Transcript | Out-Null
    Read-Host "Press ENTER to close"
    exit 1
}

Write-Host "[AUP1] Launching remote watchdog"
& ssh "xilinx@100.116.148.59" "chmod +x /tmp/mehen_fprime_watchdog.sh && bash /tmp/mehen_fprime_watchdog.sh AUP1 50000 50100 5000"
Write-Host "[AUP1] Remote watchdog SSH session ended. This usually means the terminal was closed or SSH disconnected."
Stop-Transcript | Out-Null
Read-Host "Press ENTER to close"
