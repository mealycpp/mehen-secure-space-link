param(
    [ValidateSet("session","send","tamper","full")][string]$Mode = "session",
    [string]$Direction = "AUP1_TO_AUP2",
    [string]$PayloadB64 = "",
    [string]$Reason = ""
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ensure = Join-Path $Root "ENSURE_MEHEN_LINK_AGENTS.ps1"
$AUP1 = "100.116.148.59"
$AUP2 = "100.71.108.15"
$Port = 9092
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LiveLog = Join-Path $LogDir "link_live.log"

# Robust append for the live dashboard log. Add-Content can emit
# "Stream was not readable" when the GUI is polling the same file.
# This FileStream path opens the file with ReadWrite sharing so the
# action runner can append while the dashboard reads.
function Write-LiveLogLine([string]$Line) {
    try {
        $entry = ((Get-Date).ToString("HH:mm:ss") + " " + $Line + [Environment]::NewLine)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($entry)
        $fs = [System.IO.File]::Open($LiveLog, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    } catch {
        # Console output remains authoritative if the live file is momentarily unavailable.
    }
}

function Emit([object]$Message) {
    $text = [string]$Message
    Write-Host $text
    Write-LiveLogLine $text
}

function Invoke-AgentPreflight([string]$Label) {
    if (-not (Test-Path $Ensure)) {
        Emit ("MEHEN_AGENT_PREFLIGHT=FAIL missing {0}" -f $Ensure)
        return $false
    }
    Emit ("[{0}] Running clean MEHEN link-agent preflight on both AUPs" -f $Label)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Ensure"
    if ($LASTEXITCODE -eq 0) {
        Emit ("[{0}] MEHEN_AGENT_PREFLIGHT=PASS" -f $Label)
        return $true
    }
    Emit ("[{0}] MEHEN_AGENT_PREFLIGHT=FAIL" -f $Label)
    return $false
}

function Invoke-FPrimePulse([string]$PulseReason) {
    Emit ("[FPRIME] Safe event pulse after {0}: action-specific SecureLaneBridge command on both GDS tunnels" -f $PulseReason)
    $CommandKey = "0xfeedcafe"
    $Targets = @(
        @{ Name = "AUP1"; Base = "http://127.0.0.1:5101" },
        @{ Name = "AUP2"; Base = "http://127.0.0.1:5102" }
    )
    foreach ($Target in $Targets) {
        $Name = $Target.Name
        $Base = $Target.Base
        try {
            $Probe = Invoke-WebRequest -Uri $Base -Method Get -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
            Emit ("[{0}] FPRIME_PULSE_WEB=PASS HTTP={1}" -f $Name, $Probe.StatusCode)
            $Command = if ($PulseReason -match "send_|full_demo") { "SecureLane.secureLaneBridge.HASH_TEST" } else { "SecureLane.secureLaneBridge.GET_KEY128" }
            $Escaped = [System.Uri]::EscapeDataString($Command)
            $Uri = ("{0}/commands/{1}" -f $Base, $Escaped)
            $JsonBody = @{ key = $CommandKey; arguments = @() } | ConvertTo-Json -Compress
            $Response = Invoke-WebRequest -Uri $Uri -Method Put -ContentType "application/json" -Body $JsonBody -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            Emit ("[{0}] FPRIME_ACTION_PULSE=PASS {1} HTTP={2}" -f $Name, $Command, $Response.StatusCode)
            Start-Sleep -Seconds 4
        } catch {
            Emit ("[{0}] FPRIME_ACTION_PULSE=WARN {1}" -f $Name, $_.Exception.Message)
        }
    }
    Emit "FPRIME_ACTION_PULSE_DONE"
}

function Invoke-SendOnce([string]$Label, [string]$SrcIp, [string]$DstIp, [string]$Dir, [string]$B64, [bool]$Tamper) {
    $tam = if ($Tamper) { "--tamper" } else { "" }
    Emit ("[{0}] SEND_ATTEMPT src={1} dst={2} dir={3} tamper={4}" -f $Label, $SrcIp, $DstIp, $Dir, $Tamper)
    $sshOut = & ssh ("xilinx@{0}" -f $SrcIp) ("python3 /tmp/mehen_secure_link_agent.py send --peer {0} --port {1} --direction {2} --payload-b64 {3} {4}" -f $DstIp, $Port, $Dir, $B64, $tam) 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in $sshOut) { Emit ([string]$line) }
    Emit ("[{0}] SEND_RC={1}" -f $Label, $rc)
    if ($Tamper) {
        if ($rc -eq 2) { Emit ("[{0}] EXPECTED_TAMPER_REJECT=PASS" -f $Label); return $true }
        if ($rc -eq 0) { Emit ("[{0}] ERROR tamper packet was accepted" -f $Label); return $false }
        return $false
    }
    return ($rc -eq 0)
}

function Invoke-SendRobust([string]$Label, [string]$Dir, [string]$B64, [bool]$Tamper) {
    if ([string]::IsNullOrWhiteSpace($B64)) {
        $B64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("MEHEN secure telemetry packet"))
    }
    if ($Dir -eq "AUP2_TO_AUP1") { $src = $AUP2; $dst = $AUP1 } else { $src = $AUP1; $dst = $AUP2 }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Emit ("[{0}] ROBUST_ATTEMPT={1}" -f $Label, $attempt)
        if (-not (Invoke-AgentPreflight ("{0}/attempt{1}" -f $Label, $attempt))) {
            Start-Sleep -Seconds 2
            continue
        }
        Start-Sleep -Seconds 1
        if (Invoke-SendOnce $Label $src $dst $Dir $B64 $Tamper) {
            Emit ("[{0}] LINK_ACTION=PASS" -f $Label)
            return $true
        }
        Emit ("[{0}] LINK_ACTION_RETRY_NEEDED" -f $Label)
        Start-Sleep -Seconds 3
    }
    Emit ("[{0}] LINK_ACTION=FAIL" -f $Label)
    return $false
}

$ok = $false
switch ($Mode) {
    "session" {
        $ok = Invoke-SendRobust "SESSION_READY" "AUP1_TO_AUP2" $PayloadB64 $false
        if ($ok) { Invoke-FPrimePulse "session_ready" }
    }
    "send" {
        $ok = Invoke-SendRobust ("SEND_{0}" -f $Direction) $Direction $PayloadB64 $false
        if ($ok) { Invoke-FPrimePulse ("send_{0}" -f $Direction) }
    }
    "tamper" {
        $ok = Invoke-SendRobust "TAMPER_TEST" $Direction $PayloadB64 $true
        if ($ok) { Invoke-FPrimePulse "tamper_test" }
    }
    "full" {
        $probeB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("MEHEN session probe"))
        $replyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("MEHEN authenticated reply from AUP2"))
        $tamperB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("tamper this packet"))
        Emit "[1/4] Session setup AUP1 -> AUP2"
        $ok = Invoke-SendRobust "FULL_1_SESSION" "AUP1_TO_AUP2" $probeB64 $false
        if (-not $ok) { break }
        Emit "[2/4] Secure packet AUP1 -> AUP2"
        $ok = Invoke-SendRobust "FULL_2_AUP1_TO_AUP2" "AUP1_TO_AUP2" $PayloadB64 $false
        if (-not $ok) { break }
        Emit "[3/4] Secure reply AUP2 -> AUP1"
        $ok = Invoke-SendRobust "FULL_3_AUP2_TO_AUP1" "AUP2_TO_AUP1" $replyB64 $false
        if (-not $ok) { break }
        Emit "[4/4] Tamper test AUP1 -> AUP2"
        $ok = Invoke-SendRobust "FULL_4_TAMPER" "AUP1_TO_AUP2" $tamperB64 $true
        if ($ok) { Invoke-FPrimePulse "full_demo_complete" }
    }
}

if ($ok) {
    Emit ("MEHEN_LINK_ACTION_RESULT=PASS mode={0}" -f $Mode)
    exit 0
}
Emit ("MEHEN_LINK_ACTION_RESULT=FAIL mode={0}" -f $Mode)
exit 1
