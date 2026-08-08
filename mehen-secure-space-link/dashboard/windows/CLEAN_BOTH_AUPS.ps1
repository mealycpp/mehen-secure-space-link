$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "preflight_clean_both_aups.log"
Start-Transcript -Path $Log -Append | Out-Null
Write-Host "============================================================"
Write-Host " MEHEN PREFLIGHT CLEAN: BOTH AUP BOARDS"
Write-Host " AUP1 = 100.116.148.59"
Write-Host " AUP2 = 100.71.108.15"
Write-Host "============================================================"
Write-Host "This runs BEFORE any MEHEN/F-Prime/link-agent launch."
Write-Host "It kills stale AupZu3, F-Prime GDS, Flask, and MEHEN link-agent processes, then frees ports."
Write-Host "If prompted, enter the xilinx password for each AUP."
Write-Host ""

$RemoteClean = @'
set +e
NODE="$1"
echo "[$NODE] preflight cleanup starting on $(hostname)"
pkill -f "mehen_secure_link_agent.py" || true
pkill -f "AupZu3" || true
pkill -f "fprime-gds" || true
pkill -f "fprime_gds" || true
pkill -f "flask run" || true
pkill -f "CustomDataHandlers" || true
sudo fuser -k 5000/tcp 2>/dev/null || true
sudo fuser -k 5001/tcp 2>/dev/null || true
sudo fuser -k 50000/tcp 2>/dev/null || true
sudo fuser -k 50100/tcp 2>/dev/null || true
sudo fuser -k 50050/tcp 2>/dev/null || true
sudo fuser -k 9092/tcp 2>/dev/null || true
sleep 1
echo "[$NODE] remaining MEHEN/F-Prime processes:"
ps -ef | grep -Ei "AupZu3|fprime-gds|fprime_gds|flask|mehen_secure_link_agent" | grep -v grep || echo "[$NODE] no matching processes"
echo "[$NODE] remaining demo ports:"
ss -ltnp | grep -E '(:5000|:5001|:50000|:50100|:50050|:9092)' || echo "[$NODE] ports clean"
echo "[$NODE] preflight cleanup done"
'@

foreach ($pair in @(@("AUP1","100.116.148.59"), @("AUP2","100.71.108.15"))) {
    $node = $pair[0]
    $ip = $pair[1]
    Write-Host "------------------------------------------------------------"
    Write-Host ("Cleaning {0} at {1}" -f $node, $ip)
    Write-Host "------------------------------------------------------------"
    $RemoteClean | ssh xilinx@$ip "bash -s -- $node"
    Write-Host ""
}
Write-Host "============================================================"
Write-Host " PREFLIGHT CLEAN COMPLETE"
Write-Host "============================================================"
Stop-Transcript | Out-Null
