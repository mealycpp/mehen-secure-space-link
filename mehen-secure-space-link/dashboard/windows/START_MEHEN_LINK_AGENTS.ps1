$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "link_agents_terminal.log"
Start-Transcript -Path $Log -Append | Out-Null
Write-Host "============================================================"
Write-Host " MEHEN SECURE LINK AGENTS"
Write-Host " Deploys, starts, and verifies receiver on both AUP boards."
Write-Host "============================================================"
$Ensure = Join-Path $Root "ENSURE_MEHEN_LINK_AGENTS.ps1"
if (-not (Test-Path $Ensure)) { Write-Host "ERROR: missing $Ensure"; exit 1 }
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Ensure"
Write-Host "============================================================"
Write-Host " Link-agent terminal can stay open for reference."
Write-Host "============================================================"
Stop-Transcript | Out-Null
