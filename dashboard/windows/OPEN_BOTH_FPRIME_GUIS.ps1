$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "open_both_fprime_guis.log"
Start-Transcript -Path $Log -Append | Out-Null

Write-Host "============================================================"
Write-Host " MEHEN OPEN BOTH F-PRIME GUIS - HARD WAIT"
Write-Host "============================================================"
Write-Host "This helper waits until BOTH remote GDS web servers are really alive before opening browsers."
Write-Host "Mapping: AUP1 -> http://127.0.0.1:5101/ ; AUP2 -> http://127.0.0.1:5102/"
Write-Host "AUP1 remote GDS: 5000 ; AUP2 remote GDS: 5001"
Write-Host ""

function Kill-LocalPort([int]$Port) {
    Write-Host ("[LOCAL] Clearing local tunnel port {0}" -f $Port)
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            try {
                Write-Host ("[LOCAL] Stopping PID {0} on port {1}" -f $c.OwningProcess, $Port)
                Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    } catch {
        Write-Host ("[LOCAL] Get-NetTCPConnection unavailable or no listener on {0}" -f $Port)
    }
}

function Test-RemoteGds($Name, $Ip, [int]$RemoteGdsPort) {
    $remote = @"
if ss -ltnp | grep -q ':$RemoteGdsPort'; then
  PORT_OK=1
else
  PORT_OK=0
fi
if curl -fsS --max-time 3 http://127.0.0.1:$RemoteGdsPort/ >/tmp/mehen_gds_http_${RemoteGdsPort}.log 2>&1; then
  HTTP_OK=1
else
  HTTP_OK=0
fi
printf 'PORT_OK=%s HTTP_OK=%s\n' "`$PORT_OK" "`$HTTP_OK"
ss -ltnp | grep -E '(:5000|:5001|:50000|:50100)' || true
if [ "`$PORT_OK" = "1" ] && [ "`$HTTP_OK" = "1" ]; then
  echo REMOTE_GDS=PASS
else
  echo REMOTE_GDS=WAIT
fi
"@
    $out = ssh ("xilinx@{0}" -f $Ip) $remote 2>&1
    $joined = ($out -join "`n")
    if ($joined -match "REMOTE_GDS=PASS") {
        Write-Host ("[{0}] REMOTE_GDS=PASS port={1}" -f $Name, $RemoteGdsPort)
        return $true
    }
    Write-Host ("[{0}] REMOTE_GDS=WAIT port={1} {2}" -f $Name, $RemoteGdsPort, (($out | Select-Object -First 1) -join ' '))
    return $false
}

function Wait-BothRemoteGds([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $aup1Ready = $false
    $aup2Ready = $false
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        $tick += 1
        Write-Host ("[WAIT] Remote GDS readiness check #{0}" -f $tick)
        if (-not $aup1Ready) { $aup1Ready = Test-RemoteGds "AUP1" "100.116.148.59" 5000 }
        if (-not $aup2Ready) { $aup2Ready = Test-RemoteGds "AUP2" "100.71.108.15" 5001 }
        if ($aup1Ready -and $aup2Ready) {
            Write-Host "[WAIT] BOTH_REMOTE_GDS=PASS"
            return $true
        }
        Start-Sleep -Seconds 4
    }
    Write-Host "[WAIT] BOTH_REMOTE_GDS=FAIL_TIMEOUT"
    return $false
}

function Start-Tunnel($Name, $Ip, [int]$LocalPort, [int]$RemoteGdsPort) {
    $cmd = "`$host.UI.RawUI.WindowTitle = 'MEHEN $Name F-Prime Tunnel $LocalPort'; Write-Host '============================================================'; Write-Host ' MEHEN $Name F-PRIME TUNNEL'; Write-Host ' Browser URL: http://127.0.0.1:$LocalPort/'; Write-Host ' Remote: xilinx@$Ip 127.0.0.1:$RemoteGdsPort'; Write-Host ' Leave this terminal open.'; Write-Host '============================================================'; ssh -N -L $LocalPort`:127.0.0.1`:$RemoteGdsPort xilinx@$Ip"
    Start-Process powershell.exe -ArgumentList '-NoExit','-NoLogo','-NoProfile','-Command',$cmd | Out-Null
    Write-Host ("[{0}] Tunnel terminal launched: local {1} -> remote 127.0.0.1:{2}" -f $Name, $LocalPort, $RemoteGdsPort)
}

function Test-LocalUrl([string]$Name, [int]$LocalPort) {
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $LocalPort) -UseBasicParsing -TimeoutSec 4
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            Write-Host ("[{0}] LOCAL_BROWSER_TARGET=PASS http://127.0.0.1:{1}/ HTTP={2}" -f $Name, $LocalPort, $resp.StatusCode)
            return $true
        }
    } catch {
        Write-Host ("[{0}] LOCAL_BROWSER_TARGET=WAIT {1}" -f $Name, $_.Exception.Message)
    }
    return $false
}

function Wait-LocalTunnels([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $l1 = $false
    $l2 = $false
    while ((Get-Date) -lt $deadline) {
        if (-not $l1) { $l1 = Test-LocalUrl "AUP1" 5101 }
        if (-not $l2) { $l2 = Test-LocalUrl "AUP2" 5102 }
        if ($l1 -and $l2) { Write-Host "[LOCAL] BOTH_LOCAL_TUNNELS=PASS"; return $true }
        Start-Sleep -Seconds 2
    }
    Write-Host "[LOCAL] BOTH_LOCAL_TUNNELS=FAIL_TIMEOUT"
    return $false
}

Kill-LocalPort 5101
Kill-LocalPort 5102

$remoteReady = Wait-BothRemoteGds 240
if (-not $remoteReady) {
    Write-Host "ERROR: remote GDS web servers did not become ready. Browsers will NOT be opened."
    Write-Host "Inspect the AUP1/AUP2 F-Prime watchdog terminals. Look for GDS_WEB=PASS."
    Stop-Transcript | Out-Null
    exit 2
}

Start-Tunnel "AUP1" "100.116.148.59" 5101 5000
Start-Tunnel "AUP2" "100.71.108.15" 5102 5001

Write-Host "[LOCAL] Waiting for SSH tunnels to become usable"
$localReady = Wait-LocalTunnels 60
if (-not $localReady) {
    Write-Host "ERROR: local tunnels did not become usable. Browsers will NOT be opened."
    Stop-Transcript | Out-Null
    exit 3
}

Write-Host "[LOCAL] Opening browsers"
Start-Process "http://127.0.0.1:5101/" | Out-Null
Start-Process "http://127.0.0.1:5102/" | Out-Null

Write-Host "============================================================"
Write-Host " OPEN BOTH F-PRIME GUIS COMPLETE"
Write-Host " REMOTE_GDS=PASS for both boards; LOCAL_TUNNELS=PASS."
Write-Host " Keep the two tunnel terminals open."
Write-Host "============================================================"
Stop-Transcript | Out-Null
exit 0
