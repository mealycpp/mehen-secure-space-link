$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Agent = Join-Path $Root "mehen_secure_link_agent.py"
if (-not (Test-Path $Agent)) {
    Write-Host ("ERROR: missing agent script {0}" -f $Agent)
    exit 1
}

function Ensure-Agent([string]$Name, [string]$Ip) {
    Write-Host ("[{0}] Copying MEHEN link agent" -f $Name)
    & scp "$Agent" ("xilinx@{0}:/tmp/mehen_secure_link_agent.py" -f $Ip) 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[{0}] AGENT_COPY=FAIL" -f $Name)
        return $false
    }

    $Remote = @'
set +e
PORT=9092
AGENT=/tmp/mehen_secure_link_agent.py
is_listening() { ss -ltnp 2>/dev/null | grep -q ":${PORT}"; }
ping_local() { python3 "$AGENT" ping --peer 127.0.0.1 --port "$PORT" --timeout 3 >/tmp/mehen_agent_ping_local.log 2>&1; }

echo LINK_AGENT_RESTART=ALWAYS_CURRENT_AGENT
pkill -f 'mehen_secure_link_agent.py receiver' 2>/dev/null || true
sudo fuser -k ${PORT}/tcp 2>/dev/null || true
rm -f /tmp/mehen_link_agent.log /tmp/mehen_link_metrics.json /tmp/mehen_agent_ping_local.log 2>/dev/null || true
sleep 1
nohup python3 -u "$AGENT" receiver --port "$PORT" > /tmp/mehen_link_agent.log 2>&1 &
echo RECEIVER_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if is_listening && ping_local; then
    echo LINK_AGENT=PASS
    ss -ltnp | grep ":${PORT}" || true
    tail -12 /tmp/mehen_link_agent.log 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
echo LINK_AGENT=FAIL
echo LOCAL_PING_LOG:
cat /tmp/mehen_agent_ping_local.log 2>/dev/null || true
echo RECEIVER_LOG:
tail -120 /tmp/mehen_link_agent.log 2>/dev/null || true
exit 1
'@
    $RemotePath = Join-Path $env:TEMP ("mehen_ensure_{0}.sh" -f $Name)
    Set-Content -Path $RemotePath -Value $Remote -Encoding ASCII
    & scp "$RemotePath" ("xilinx@{0}:/tmp/mehen_ensure_link_agent.sh" -f $Ip) 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[{0}] ENSURE_SCRIPT_COPY=FAIL" -f $Name)
        return $false
    }

    Write-Host ("[{0}] Verifying receiver on port 9092" -f $Name)
    $SawPass = $false
    & ssh ("xilinx@{0}" -f $Ip) "bash /tmp/mehen_ensure_link_agent.sh" 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        if ($line -match 'LINK_AGENT=PASS') { $SawPass = $true }
    }
    $rc = $LASTEXITCODE
    if (($rc -eq 0) -and $SawPass) {
        Write-Host ("[{0}] LINK_AGENT_READY=PASS" -f $Name)
        return $true
    }
    Write-Host ("[{0}] LINK_AGENT_READY=FAIL" -f $Name)
    return $false
}

function Cross-Ping([string]$FromName, [string]$FromIp, [string]$ToIp) {
    Write-Host ("[{0}] Cross-ping link receiver at {1}:9092" -f $FromName, $ToIp)
    & ssh ("xilinx@{0}" -f $FromIp) ("python3 /tmp/mehen_secure_link_agent.py ping --peer {0} --port 9092 --timeout 5" -f $ToIp) 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("[{0}] LINK_CROSS_PING=PASS" -f $FromName)
        return $true
    }
    Write-Host ("[{0}] LINK_CROSS_PING=FAIL" -f $FromName)
    return $false
}

$ok1 = Ensure-Agent "AUP1" "100.116.148.59"
$ok2 = Ensure-Agent "AUP2" "100.71.108.15"
$ok3 = $false
$ok4 = $false
if ($ok1 -and $ok2) {
    $ok3 = Cross-Ping "AUP1_TO_AUP2" "100.116.148.59" "100.71.108.15"
    $ok4 = Cross-Ping "AUP2_TO_AUP1" "100.71.108.15" "100.116.148.59"
}
if ($ok1 -and $ok2 -and $ok3 -and $ok4) {
    Write-Host "MEHEN_LINK_AGENTS=PASS"
    exit 0
}
Write-Host "MEHEN_LINK_AGENTS=FAIL"
exit 1
