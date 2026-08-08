$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "stop_cleanup.log"
Start-Transcript -Path $Log -Append | Out-Null
Write-Host "============================================================"
Write-Host " MEHEN STOP / CLEANUP"
Write-Host "============================================================"

# Stop local hidden live-telemetry monitor if it is running.
$PidFile = Join-Path $LogDir "live_telemetry.pid"
if (Test-Path $PidFile) {
  try {
    $old = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -match '^[0-9]+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "Local live telemetry monitor stopped."
  } catch { Write-Host "Local live telemetry monitor stop skipped: $($_.Exception.Message)" }
}

foreach ($ip in @('100.116.148.59','100.71.108.15')) {
  Write-Host "Cleaning $ip"
  ssh xilinx@$ip "pkill -f mehen_secure_link_agent.py || true; pkill -f AupZu3 || true; pkill -f fprime-gds || true; pkill -f fprime_gds || true; pkill -f 'flask run' || true; sudo fuser -k 50000/tcp || true; sudo fuser -k 50100/tcp || true; sudo fuser -k 5000/tcp || true; sudo fuser -k 5001/tcp || true; sudo fuser -k 50050/tcp || true; sudo fuser -k 9092/tcp || true; ss -ltnp | grep -E '(:5000|:5001|:50000|:50100|:50050|:9092)' || echo ports clean"
}
Write-Host "Cleanup complete."
Stop-Transcript | Out-Null
