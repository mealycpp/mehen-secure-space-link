$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "clean_and_open_both_fprime.log"
Start-Transcript -Path $Log -Append | Out-Null

Write-Host "============================================================"
Write-Host " MEHEN ONE-BUTTON F-PRIME RESET + OPEN - HARD READY"
Write-Host "============================================================"
Write-Host "This is the clean operator path:"
Write-Host "  1. Clean AUP1 and AUP2"
Write-Host "  2. Start AUP1 flight app + GDS"
Write-Host "  3. Start AUP2 flight app + GDS"
Write-Host "  4. Wait for both remote GDS web servers"
Write-Host "  5. Start tunnels and open both F-Prime browser windows"
Write-Host ""

function Start-Helper($ScriptName, $Title) {
    $path = Join-Path $Root $ScriptName
    if (-not (Test-Path $path)) { Write-Host ("ERROR: missing helper {0}" -f $ScriptName); return $false }
    Write-Host ("[LAUNCH] {0}" -f $Title)
    Start-Process powershell.exe -ArgumentList '-NoExit','-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"$path" | Out-Null
    return $true
}

$clean = Join-Path $Root "CLEAN_BOTH_AUPS.ps1"
if (Test-Path $clean) {
    Write-Host "[STEP 1] Running full cleanup on both AUP boards."
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$clean"
} else {
    Write-Host "[STEP 1] WARNING: CLEAN_BOTH_AUPS.ps1 missing. Continuing."
}

Write-Host "[STEP 2] Starting AUP1 F-Prime terminal."
Start-Helper "START_AUP1_FPRIME.ps1" "AUP1 F-Prime terminal" | Out-Null
Start-Sleep -Seconds 3

Write-Host "[STEP 3] Starting AUP2 F-Prime terminal."
Start-Helper "START_AUP2_FPRIME.ps1" "AUP2 F-Prime terminal" | Out-Null
Start-Sleep -Seconds 5

Write-Host "[STEP 4] HARD WAIT: only open browsers after both remote GDS web servers confirm PASS."
$open = Join-Path $Root "OPEN_BOTH_FPRIME_GUIS.ps1"
if (Test-Path $open) {
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$open"
    $openRc = $LASTEXITCODE
    if ($openRc -ne 0) {
        Write-Host ("ERROR: OPEN_BOTH_FPRIME_GUIS failed with code {0}. Stack is not ready." -f $openRc)
        Write-Host "Do not continue to CHECK + PRIME until the AUP1/AUP2 watchdog terminals show GDS_WEB=PASS."
        Stop-Transcript | Out-Null
        exit $openRc
    }
} else {
    Write-Host "ERROR: OPEN_BOTH_FPRIME_GUIS.ps1 missing."
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host "============================================================"
Write-Host " ONE-BUTTON F-PRIME RESET + OPEN COMPLETE"
Write-Host " Both remote GDS servers confirmed PASS and both browser tunnels are usable."
Write-Host " Then use CHECK + PRIME F-PRIME."
Write-Host "============================================================"
Stop-Transcript | Out-Null
exit 0
