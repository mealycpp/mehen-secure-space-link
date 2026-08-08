<#
MEHEN Mission Control v1.0.45 PRIMARY-FLOW-ORDERED

Dark mission-console dashboard for the MEHEN two-AUP secure space-link demo.
It intentionally uses external PowerShell/SSH terminal windows for long board-side processes.
The GUI remains responsive and polls local logs asynchronously.
#>

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Control]::CheckForIllegalCrossThreadCalls = $false

$script:AppVersion = "v1.0.45 PRIMARY-FLOW-ORDERED"
$script:Cfg = [ordered]@{
    AUP1IP = "100.116.148.59"
    AUP2IP = "100.71.108.15"
    SshUser = "xilinx"
    AUP1GuiLocal = "http://127.0.0.1:5101"
    AUP2GuiLocal = "http://127.0.0.1:5102"
    AUP1GuiDirect = "http://100.116.148.59:5000"
    AUP2GuiDirect = "http://100.71.108.15:5001"
    LinkPort = 9092
    CommandKey = "0xfeedcafe"
}
$script:UI = @{}
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:MissionStart = $null
$script:Metrics = [ordered]@{
    Channel = "STANDBY"
    KeyFp = "--"
    Direction = "--"
    PacketsTx = 0
    PacketsRx = 0
    BytesMoved = 0
    Tag = "--"
    Verify = "--"
    EncryptMs = "--"
    DecryptMs = "--"
    AUP1Temp = "not sampled"
    AUP2Temp = "not sampled"
    AUP1Load = "not sampled"
    AUP2Load = "not sampled"
    AUP1Uptime = "not sampled"
    AUP2Uptime = "not sampled"
    AUP1Ports = "not sampled"
    AUP2Ports = "not sampled"
    AUP1TRNG = "awaiting check"
    AUP2TRNG = "awaiting check"
    HWLatency = "awaiting check"
    DataState = "waiting"
    TelemetryAge = "--"
    LastAction = "none"
    ActionSec = "--"
    FPrimeEvents = "none"
    LastEvent = "standby"
}
$script:ChannelState = "GRAY"
$script:PayloadText = "MEHEN secure telemetry packet 001"
$script:LastPoll = Get-Date
$script:SeenEvents = @{}
$script:AnimTick = 0
$script:TimerTick = 0
$script:ActiveActionName = ""
$script:LastGateMessage = ""
$script:ActionStartTimes = @{}
$script:LastTelemetrySeen = $null
$script:TelemetryMonitorStarted = $false

function C([string]$Hex) { return [System.Drawing.ColorTranslator]::FromHtml($Hex) }
function F([float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular) { return [System.Drawing.Font]::new("Segoe UI", $Size, $Style) }

function Safe([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch {
        $msg = $_.Exception.Message
        Add-Log ("ERROR in {0}: {1}" -f $Name, $msg)
        Set-Status "ERROR" $Name "#FF4B4B"
        try { Add-Content -Path (Join-Path $PSScriptRoot "MEHEN_RUNTIME_ERROR.txt") -Value ("[{0}] {1}: {2}" -f (Get-Date), $Name, $msg) } catch {}
    }
}

function PanelBox($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Back="#07111E") {
    $p = [System.Windows.Forms.Panel]::new(); $p.Location = [System.Drawing.Point]::new($X,$Y); $p.Size = [System.Drawing.Size]::new($W,$H)
    $p.BackColor = C $Back; $p.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; $Parent.Controls.Add($p); return $p
}

function LabelText($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text, [float]$Size=9.0, [string]$Color="#DCEBFF", [System.Drawing.FontStyle]$Style=[System.Drawing.FontStyle]::Regular, [System.Drawing.ContentAlignment]$Align=[System.Drawing.ContentAlignment]::MiddleLeft) {
    $l = [System.Windows.Forms.Label]::new(); $l.Location = [System.Drawing.Point]::new($X,$Y); $l.Size = [System.Drawing.Size]::new($W,$H)
    $l.Text = $Text; $l.ForeColor = C $Color; $l.BackColor = $Parent.BackColor; $l.Font = F $Size $Style; $l.TextAlign = $Align
    $Parent.Controls.Add($l); return $l
}

function StatusCanvasBox($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text, [float]$Size=10.0, [string]$Color="#FFD166") {
    # Do not use TextBox/Label for the large status value. On this WinForms/DPI setup they can draw a black clipping band over the text.
    # This panel paints the value directly, so there is no caret, selection, text-control background, or child-control overlap.
    $p = [System.Windows.Forms.Panel]::new()
    $p.Location = [System.Drawing.Point]::new($X,$Y); $p.Size = [System.Drawing.Size]::new($W,$H)
    $p.BackColor = $Parent.BackColor
    $p.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $p | Add-Member -NotePropertyName DisplayText -NotePropertyValue $Text
    $p | Add-Member -NotePropertyName DisplayColor -NotePropertyValue (C $Color)
    $p | Add-Member -NotePropertyName DisplaySize -NotePropertyValue $Size
    $p.Add_Paint({
        param($sender, $e)
        $e.Graphics.Clear($sender.BackColor)
        try { $e.Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit } catch {}
        $font = F ([float]$sender.DisplaySize) ([System.Drawing.FontStyle]::Bold)
        $brush = [System.Drawing.SolidBrush]::new($sender.DisplayColor)
        $sf = [System.Drawing.StringFormat]::new()
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $rect = [System.Drawing.RectangleF]::new(0, 0, [float]$sender.Width, [float]$sender.Height)
        $e.Graphics.DrawString([string]$sender.DisplayText, $font, $brush, $rect, $sf)
        $sf.Dispose(); $brush.Dispose(); $font.Dispose()
    })
    $Parent.Controls.Add($p)
    return $p
}


function HeaderStatusPanel($Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    # One owner-drawn header panel. No nested label/textbox value controls, so no black text-control band or clipping artifact.
    $p = [System.Windows.Forms.Panel]::new()
    $p.Location = [System.Drawing.Point]::new($X,$Y)
    $p.Size = [System.Drawing.Size]::new($W,$H)
    $p.BackColor = C "#06111D"
    $p.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $p | Add-Member -NotePropertyName StateText -NotePropertyValue "STANDBY"
    $p | Add-Member -NotePropertyName StateColor -NotePropertyValue (C "#FFD166")
    $p | Add-Member -NotePropertyName GateText -NotePropertyValue "READY"
    $p | Add-Member -NotePropertyName GateColor -NotePropertyValue (C "#29D15F")
    $p | Add-Member -NotePropertyName DetailText -NotePropertyValue "MEHEN ready"
    $p | Add-Member -NotePropertyName HintText -NotePropertyValue "Press RESET + OPEN F-PRIME"
    $p.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        try { $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit } catch {}
        $bg = [System.Drawing.SolidBrush]::new($sender.BackColor)
        $g.FillRectangle($bg, 0, 0, $sender.Width, $sender.Height)
        $border = [System.Drawing.Pen]::new((C "#5D6B7A"), 1)
        $sep = [System.Drawing.Pen]::new((C "#34495E"), 1)
        $g.DrawRectangle($border, 0, 0, $sender.Width-1, $sender.Height-1)
        $g.DrawLine($sep, 160, 8, 160, $sender.Height-8)
        $g.DrawLine($sep, 280, 8, 280, $sender.Height-8)
        $fontSmall = F 7.2 ([System.Drawing.FontStyle]::Bold)
        $fontBig = F 13.0 ([System.Drawing.FontStyle]::Bold)
        $fontMsg = F 7.8 ([System.Drawing.FontStyle]::Regular)
        $blue = [System.Drawing.SolidBrush]::new((C "#9EC7FF"))
        $white = [System.Drawing.SolidBrush]::new((C "#DCEBFF"))
        $gold = [System.Drawing.SolidBrush]::new((C "#FFD166"))
        $stateBrush = [System.Drawing.SolidBrush]::new($sender.StateColor)
        $gateBrush = [System.Drawing.SolidBrush]::new($sender.GateColor)
        $sfCenter = [System.Drawing.StringFormat]::new(); $sfCenter.Alignment = [System.Drawing.StringAlignment]::Center; $sfCenter.LineAlignment = [System.Drawing.StringAlignment]::Center; $sfCenter.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $sfLeft = [System.Drawing.StringFormat]::new(); $sfLeft.Alignment = [System.Drawing.StringAlignment]::Near; $sfLeft.LineAlignment = [System.Drawing.StringAlignment]::Center; $sfLeft.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $g.DrawString("MISSION STATE", $fontSmall, $blue, [System.Drawing.RectangleF]::new(8, 3, 144, 14), $sfCenter)
        $g.DrawString([string]$sender.StateText, $fontBig, $stateBrush, [System.Drawing.RectangleF]::new(8, 19, 144, 24), $sfCenter)
        $g.DrawString("ACTION GATE", $fontSmall, $blue, [System.Drawing.RectangleF]::new(170, 3, 100, 14), $sfCenter)
        $g.DrawString([string]$sender.GateText, $fontBig, $gateBrush, [System.Drawing.RectangleF]::new(170, 19, 100, 24), $sfCenter)
        $g.DrawString([string]$sender.DetailText, $fontMsg, $white, [System.Drawing.RectangleF]::new(292, 5, $sender.Width-300, 19), $sfLeft)
        $g.DrawString([string]$sender.HintText, $fontMsg, $gold, [System.Drawing.RectangleF]::new(292, 27, $sender.Width-300, 20), $sfLeft)
        $sfCenter.Dispose(); $sfLeft.Dispose(); $stateBrush.Dispose(); $gateBrush.Dispose(); $blue.Dispose(); $white.Dispose(); $gold.Dispose(); $fontSmall.Dispose(); $fontBig.Dispose(); $fontMsg.Dispose(); $border.Dispose(); $sep.Dispose(); $bg.Dispose()
    })
    $Parent.Controls.Add($p)
    return $p
}

function PlainStatusStrip($Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    # Plain one-line status strip: no stacked value controls, no owner-drawn value boxes.
    $p = [System.Windows.Forms.Panel]::new()
    $p.Location = [System.Drawing.Point]::new($X,$Y)
    $p.Size = [System.Drawing.Size]::new($W,$H)
    $p.BackColor = C "#06111D"
    $p.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Parent.Controls.Add($p)

    $script:UI.StatusValue = LabelText $p 10 5 180 22 "STATUS: STANDBY" 10.5 "#FFD166" ([System.Drawing.FontStyle]::Bold)
    $script:UI.GateValue = LabelText $p 200 5 150 22 "GATE: READY" 10.5 "#29D15F" ([System.Drawing.FontStyle]::Bold)
    $script:UI.StatusDetail = LabelText $p 360 4 ($W-370) 22 "MEHEN ready" 8.2 "#DCEBFF" ([System.Drawing.FontStyle]::Regular)
    $script:UI.StatusHint = LabelText $p 360 29 ($W-370) 19 "Press RESET + OPEN F-PRIME" 7.8 "#FFD166" ([System.Drawing.FontStyle]::Bold)
    return $p
}

function ButtonBox($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title, [string]$Sub, [string]$Back="#0B3363") {
    $b = [System.Windows.Forms.Button]::new(); $b.Location = [System.Drawing.Point]::new($X,$Y); $b.Size = [System.Drawing.Size]::new($W,$H)
    $b.Text = "$Title`r`n$Sub"; $b.Font = F 9.0 ([System.Drawing.FontStyle]::Bold); $b.ForeColor = C "#F3FAFF"; $b.BackColor = C $Back
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.FlatAppearance.BorderColor = C "#20B9FF"; $b.FlatAppearance.BorderSize = 1
    $Parent.Controls.Add($b); return $b
}

function Add-Log([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Text
    [void]$script:LogLines.Add($line)
    while ($script:LogLines.Count -gt 260) { $script:LogLines.RemoveAt(0) }
    if ($script:UI.ContainsKey("TerminalView")) {
        $script:UI.TerminalView.Text = ($script:LogLines -join "`r`n")
        $script:UI.TerminalView.SelectionStart = $script:UI.TerminalView.TextLength
        $script:UI.TerminalView.ScrollToCaret()
    }
}

function Refresh-StatusLabel([string]$Name) {
    if ($script:UI.ContainsKey($Name)) {
        try { $script:UI[$Name].Invalidate(); $script:UI[$Name].Update(); $script:UI[$Name].Refresh() } catch {}
    }
}

function Set-Status([string]$State, [string]$Sub="", [string]$Color="#29D15F") {
    if ($script:UI.ContainsKey("StatusValue")) {
        $script:UI.StatusValue.Text = "STATUS: $State"
        $script:UI.StatusValue.ForeColor = C $Color
    }
    if ($script:UI.ContainsKey("StatusDetail")) { $script:UI.StatusDetail.Text = $Sub }
    if ($script:UI.ContainsKey("MissionStatus")) {
        $script:UI.MissionStatus.Text = $State
        $script:UI.MissionStatus.ForeColor = C $Color
    }
    if ($script:UI.ContainsKey("MissionSub")) { $script:UI.MissionSub.Text = $Sub }
}


function Set-ActionButtonsEnabled([bool]$Enabled) {
    if (-not $script:UI) { return }
    $buttonNames = @('BtnStart','BtnCheck','BtnFPrimeEvents','BtnSession','BtnSend12','BtnSend21','BtnTamper','BtnFull')
    foreach ($bn in $buttonNames) {
        if ($script:UI.ContainsKey($bn)) {
            try { $script:UI[$bn].Enabled = $Enabled } catch {}
        }
    }
    # STOP/CLEANUP must remain available even while an action is running.
    if ($script:UI.ContainsKey('BtnStop')) { try { $script:UI.BtnStop.Enabled = $true } catch {} }
}

function Is-ActionBusy {
    return (-not [string]::IsNullOrWhiteSpace([string]$script:ActiveActionName))
}

function Run-IfReady([string]$Label, [scriptblock]$Block) {
    if (Is-ActionBusy) {
        $running = [string]$script:ActiveActionName
        Set-OperatorGate "BUSY" ("{0} still running - wait for DONE before {1}" -f $running,$Label) "#FFD166"
        Add-Log ("BLOCKED: {0} ignored because {1} is still running. Wait for ACTION GATE = DONE." -f $Label,$running)
        return
    }
    & $Block
}

function Set-OperatorGate([string]$Gate, [string]$Hint="", [string]$Color="#29D15F") {
    $script:LastGateMessage = ("{0} {1}" -f $Gate, $Hint).Trim()
    if ($script:UI.ContainsKey("GateValue")) {
        $script:UI.GateValue.Text = "GATE: $Gate"
        $script:UI.GateValue.ForeColor = C $Color
    }
    if ($script:UI.ContainsKey("StatusHint")) { $script:UI.StatusHint.Text = $Hint }
    if ($script:UI.ContainsKey("OperatorGate")) {
        $script:UI.OperatorGate.Text = $Gate
        $script:UI.OperatorGate.ForeColor = C $Color
    }
    if ($script:UI.ContainsKey("OperatorHint")) { $script:UI.OperatorHint.Text = $Hint }
    if ($Gate -eq "BUSY") { Set-ActionButtonsEnabled $false } else { Set-ActionButtonsEnabled $true }
}


function Start-ActionTimer([string]$Name) {
    $script:ActionStartTimes[$Name] = Get-Date
    $script:ActiveActionName = $Name
    $script:Metrics.LastAction = $Name
    $script:Metrics.ActionSec = "running"
    $script:Metrics.DataState = "ACTION RUN"
    Update-Visuals
}

function Complete-ActionTimer([string]$Name, [double]$Seconds=-1) {
    if ($Seconds -lt 0 -and $script:ActionStartTimes.ContainsKey($Name)) {
        $Seconds = ((Get-Date) - $script:ActionStartTimes[$Name]).TotalSeconds
    }
    if ($Seconds -ge 0) {
        $script:Metrics.LastAction = $Name
        $script:Metrics.ActionSec = ("{0:N1} s" -f $Seconds)
        $script:Metrics.DataState = "fresh"
        if ($script:ActiveActionName -eq $Name) { $script:ActiveActionName = "" }
        return ("{0:N1} s" -f $Seconds)
    }
    return "--"
}

function Complete-ActiveActionSafe([string]$Action, [string]$StatusText, [string]$Hint, [string]$LastEvent="") {
    # Centralized completion so repeated actions cannot leave the gate stuck in BUSY.
    if ($script:ActiveActionName -ne $Action) { return }
    $durText = Complete-ActionTimer $Action
    Set-OperatorGate "DONE" ("{0} complete in {1}; ready" -f $Action,$durText) "#29D15F"
    Set-Status $StatusText $Hint "#29D15F"
    if (-not [string]::IsNullOrWhiteSpace($LastEvent)) { $script:Metrics.LastEvent = $LastEvent }
    Add-Log ("DONE: {0} robust completion detected in {1}." -f $Action,$durText)
}


function Start-LiveTelemetryMonitor {
    if ($script:TelemetryMonitorStarted) { return }
    $mon = Join-Path $PSScriptRoot "START_LIVE_TELEMETRY.ps1"
    if (-not (Test-Path $mon)) { Add-Log "Live telemetry monitor missing."; return }
    try {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$mon`"" | Out-Null
        $script:TelemetryMonitorStarted = $true
        $script:Metrics.DataState = "telemetry monitor started"
        Add-Log "Live board telemetry monitor started in background; right panel will update without pressing CHECK."
    } catch {
        Add-Log ("Live telemetry monitor failed to start: {0}" -f $_.Exception.Message)
    }
}

function Mission-State-AfterAction([string]$Action) {
    switch -Regex ($Action) {
        '^check_services$' { return 'CHECK OK' }
        '^fprime_event_set$' { return 'FPRIME EVT' }
        '^session_ready$' { return 'LINK READY' }
        '^send_AUP1_TO_AUP2$' { return 'TX AUP1' }
        '^send_AUP2_TO_AUP1$' { return 'TX AUP2' }
        '^tamper_test$' { return 'REJECT OK' }
        '^full_demo$' { return 'DEMO OK' }
        default { return 'STEP OK' }
    }
}

function Short-UiText([string]$Text, [int]$Max=32) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "--" }
    $t = ($Text -replace "[`r`n]+", " ").Trim()
    if ($t.Length -le $Max) { return $t }
    return ($t.Substring(0, [Math]::Max(0,$Max-1)) + "...")
}

function Short-ChannelName([string]$Text) {
    switch ($Text) {
        "CHECK + SAFE EVENT" { return "CHECK OK" }
        "FPRIME STARTUP" { return "F-PRIME STARTUP" }
        "PACKET MOVING" { return "PACKET TX" }
        "FULL DEMO RUNNING" { return "FULL DEMO" }
        "TAMPER INJECTED" { return "BAD TAG TEST" }
        "NEGOTIATING" { return "NEGOTIATING" }
        "READY" { return "LINK READY" }
        "ALERT" { return "BAD TAG" }
        default { return (Short-UiText $Text 18) }
    }
}

function Compact-PortSummary([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "--" }
    $items = @()
    if ($Raw -match "GDS5000:LISTEN|GDS5001:LISTEN") { $items += "GDS:OK" } else { $items += "GDS:--" }
    if ($Raw -match "FSW50000:LISTEN|FSW50100:LISTEN") { $items += "FSW:OK" } else { $items += "FSW:--" }
    if ($Raw -match "LINK9092:LISTEN") { $items += "LINK:OK" } else { $items += "LINK:--" }
    return ($items -join "  ")
}

function Maybe-CompleteResetOpen {
    # The RESET + OPEN step launches long-running watchdog/tunnel terminals. It should be considered
    # complete once both boards report F-Prime GDS and flight-app ports alive, even if those terminals
    # continue to run for the demo. This prevents the operator gate from staying BUSY forever.
    if ($script:ActiveActionName -ne "reset_open") { return }
    $p1 = [string]$script:Metrics.AUP1Ports
    $p2 = [string]$script:Metrics.AUP2Ports
    $portsReady = ($p1 -match "GDS:OK" -and $p1 -match "FSW:OK" -and $p2 -match "GDS:OK" -and $p2 -match "FSW:OK")
    $elapsed = -1.0
    if ($script:ActionStartTimes.ContainsKey("reset_open")) {
        $elapsed = ((Get-Date) - $script:ActionStartTimes["reset_open"]).TotalSeconds
    }
    if ($portsReady) {
        if (Mark-Seen "reset_open_autodone_ports") {
            $durText = Complete-ActionTimer "reset_open"
            Set-OperatorGate "DONE" ("F-Prime ports ready in {0}; press CHECK + PRIME" -f $durText) "#29D15F"
            Set-Status "STACK RDY" ("AUP1/AUP2 GDS+FSW ready in {0}" -f $durText) "#29D15F"
            $script:Metrics.DataState = "TELEM OK"
            $script:Metrics.LastEvent = "F-Prime stack ready: AUP1/AUP2 GDS and FSW ports are alive"
            Add-Log ("DONE: RESET + OPEN F-PRIME auto-completed from live port telemetry in {0}." -f $durText)
        }
    } elseif ($elapsed -gt 180) {
        if (Mark-Seen "reset_open_timeout_notice") {
            Set-OperatorGate "CHECK" "Reset still running; verify F-Prime browsers/tunnels" "#FFD166"
            Set-Status "CHECK STACK" "Reset exceeded 180s; inspect stack terminal" "#FFD166"
            Add-Log "NOTICE: RESET + OPEN F-PRIME exceeded 180s without both GDS+FSW port pairs ready. Inspect the stack terminal."
        }
    }
}

function Set-MeasurementPending([string]$Action, [string]$Direction="--", [bool]$Tamper=$false) {
    # Fill the right measurement column immediately when an operator presses a mission button.
    # The final values are replaced by parsed link-agent JSON/plain-text output when the action completes.
    $script:Metrics.DataState = "ACTION RUN"
    $script:Metrics.LastAction = $Action
    if ($Direction -and $Direction -ne "--") { $script:Metrics.Direction = $Direction }
    if ($Tamper) {
        $script:Metrics.Channel = "BAD TAG TEST"
        $script:Metrics.Verify = "expect reject"
        $script:Metrics.Tag = "tamper pending"
    } elseif ($Action -eq "session_ready") {
        $script:Metrics.Channel = "NEGOTIATING"
        $script:Metrics.KeyFp = "deriving"
        $script:Metrics.Tag = "probe pending"
        $script:Metrics.Verify = "pending"
    } elseif ($Action -eq "full_demo") {
        $script:Metrics.Channel = "FULL DEMO"
        $script:Metrics.Direction = "BIDIRECTIONAL"
        $script:Metrics.KeyFp = "rotating"
        $script:Metrics.Tag = "multi-packet"
        $script:Metrics.Verify = "pending"
    } elseif ($Action -like "send_*") {
        $script:Metrics.Channel = "PACKET TX"
        $script:Metrics.Tag = "pending"
        $script:Metrics.Verify = "pending"
    } elseif ($Action -eq "check_services") {
        $script:Metrics.Channel = "CHECK OK"
        $script:Metrics.Direction = "--"
        $script:Metrics.KeyFp = "F' key event"
        $script:Metrics.Tag = "--"
        $script:Metrics.Verify = "--"
    } elseif ($Action -eq "fprime_event_set") {
        $script:Metrics.Channel = "FPRIME EVENTS"
        $script:Metrics.Direction = "--"
        $script:Metrics.KeyFp = "F' event set"
        $script:Metrics.Tag = "--"
        $script:Metrics.Verify = "--"
    }
    if ($Action -in @("session_ready","send_AUP1_TO_AUP2","send_AUP2_TO_AUP1","tamper_test","full_demo")) {
        if ($script:Metrics.EncryptMs -eq "--" -or $script:Metrics.EncryptMs -eq "") { $script:Metrics.EncryptMs = "pending" } else { $script:Metrics.EncryptMs = "running" }
        if ($script:Metrics.DecryptMs -eq "--" -or $script:Metrics.DecryptMs -eq "") { $script:Metrics.DecryptMs = "pending" } else { $script:Metrics.DecryptMs = "running" }
        $script:Metrics.FPrimeEvents = "pulse pending"
    }
    if ($Action -eq "check_services") {
        $script:Metrics.FPrimeEvents = "key+hash pending"
        $script:Metrics.HWLatency = "running"
    }
    if ($Action -eq "fprime_event_set") { $script:Metrics.FPrimeEvents = "full set running" }
}


function Start-External($ScriptName, $Title) {
    $path = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path $path)) { Add-Log "Missing helper: $ScriptName"; return }
    $args = "-NoExit -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$path`""
    Start-Process powershell.exe -ArgumentList $args | Out-Null
    Add-Log "Opened external terminal: $Title"
}

function Run-ActionWindow([string]$Name, [string]$Body) {
    $logDir = Join-Path $PSScriptRoot "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $scriptPath = Join-Path $logDir ("action_{0}_{1}.ps1" -f $Name, (Get-Date).ToString("HHmmss"))
    $log = Join-Path $logDir ("{0}.log" -f $Name)
    $script:ActiveActionName = $Name
    Start-ActionTimer $Name
    Set-OperatorGate "BUSY" ("{0} running - wait for DONE" -f $Name) "#FFD166"
    @"
`$ErrorActionPreference = 'Continue'
`$global:MEHEN_ACTION_FAILED = `$false
# Do not let a stale PowerShell automatic variable make a successful action look failed.
# Individual action bodies mark real failures by setting `$global:MEHEN_ACTION_FAILED = `$true.
try { `$global:LASTEXITCODE = 0 } catch {}
Start-Transcript -Path '$log' -Append | Out-Null
Write-Host '============================================================'
Write-Host ' MEHEN ACTION: $Name'
Write-Host '============================================================'
`$__mehenActionStart = Get-Date
$Body
# Success/failure is controlled by `$global:MEHEN_ACTION_FAILED. Some pure PowerShell/GDS web actions
# can leave `$LASTEXITCODE nonzero even when every HTTP command returned 200.
`$__mehenActionDuration = [math]::Round(((Get-Date) - `$__mehenActionStart).TotalSeconds, 1)
Write-Host ("ACTION_DURATION_SEC: {0} {1}" -f '$Name', `$__mehenActionDuration)
Write-Host '============================================================'
if (`$global:MEHEN_ACTION_FAILED) {
    Write-Host ' ACTION FAILED: $Name'
    Write-Host ' This transient window will stay open for inspection.'
    Write-Host ' Close it manually after copying any useful error.'
    Write-Host '============================================================'
    Stop-Transcript | Out-Null
    Read-Host 'Press ENTER to close this failed-action window'
} else {
    Write-Host ' ACTION COMPLETE: $Name'
    Write-Host ' Closing this transient action window in 6 seconds.'
    Write-Host ' Main dashboard log keeps the evidence.'
    Write-Host '============================================================'
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 6
}
"@ | Set-Content -Path $scriptPath -Encoding UTF8
    Start-Process powershell.exe -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" | Out-Null
    Add-Log "Action launched: $Name (transient; closes on success, stays open on failure)"
}

function Ensure-AgentBody {
    return @'
$Root = Split-Path -Parent $PSScriptRoot
$Ensure = Join-Path $Root "ENSURE_MEHEN_LINK_AGENTS.ps1"
$global:MEHEN_AGENTS_READY = $false
if (-not (Test-Path $Ensure)) {
    Write-Host ("ERROR: missing ensure script {0}" -f $Ensure)
    $global:MEHEN_ACTION_FAILED = $true
} else {
    Write-Host "[MEHEN] Ensuring both link-agent receivers are live before packet action"
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Ensure"
    if ($LASTEXITCODE -eq 0) {
        $global:MEHEN_AGENTS_READY = $true
        Write-Host "MEHEN_AGENT_PREFLIGHT=PASS"
    } else {
        Write-Host "MEHEN_AGENT_PREFLIGHT=FAIL"
        Write-Host "MEHEN_ACTION_ABORTED=LINK_AGENTS_NOT_READY"
        $global:MEHEN_ACTION_FAILED = $true
    }
}
'@
}


function FPrimePulseBody([string]$Reason) {
    $safeReason = $Reason.Replace("'", "")
    return @"
Write-Host '[FPRIME] Safe action pulse: $safeReason'
Write-Host '[FPRIME] Sending a safe two-step F-Prime pulse: GET_KEY128 then HASH_TEST. XOF_TEST and ROUNDTRIP stay manual to avoid health faults.'
`$CommandKey = '0xfeedcafe'
`$Targets = @(
    @{ Name = 'AUP1'; Base = 'http://127.0.0.1:5101' },
    @{ Name = 'AUP2'; Base = 'http://127.0.0.1:5102' }
)
foreach (`$Target in `$Targets) {
    `$Name = `$Target.Name
    `$Base = `$Target.Base
    try {
        `$Probe = Invoke-WebRequest -Uri `$Base -Method Get -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        Write-Host ("[{0}] FPRIME_PULSE_WEB=PASS HTTP={1}" -f `$Name, `$Probe.StatusCode)
        foreach (`$Cmd in @('SecureLane.secureLaneBridge.GET_KEY128','SecureLane.secureLaneBridge.HASH_TEST')) {
            `$Escaped = [System.Uri]::EscapeDataString(`$Cmd)
            `$Uri = ("{0}/commands/{1}" -f `$Base, `$Escaped)
            `$JsonBody = @{ key = `$CommandKey; arguments = @() } | ConvertTo-Json -Compress
            `$Response = Invoke-WebRequest -Uri `$Uri -Method Put -ContentType 'application/json' -Body `$JsonBody -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            Write-Host ("[{0}] FPRIME_ACTION_PULSE=PASS {1} HTTP={2}" -f `$Name, `$Cmd, `$Response.StatusCode)
            Start-Sleep -Seconds 6
        }
    } catch {
        Write-Host ("[{0}] FPRIME_ACTION_PULSE=FAIL {1}" -f `$Name, `$_.Exception.Message)
        Write-Host ("[{0}] Pulse failure is treated as an action failure because the demo expects F-Prime event visibility." -f `$Name)
        `$global:MEHEN_ACTION_FAILED = `$true
    }
}
Write-Host 'FPRIME_ACTION_PULSE_DONE'
"@
}

function Start-Stack {
    if ($null -eq $script:MissionStart) { $script:MissionStart = Get-Date }
    Start-ActionTimer "reset_open"
    Set-Status "CLEANING" "Preflight clean both AUPs, then launch stack; no secure channel traffic yet" "#FFD166"
    Set-OperatorGate "BUSY" "Starting F-Prime; wait for DONE" "#FFD166"
    Start-External "START_STACK_CLEAN_BOOTSTRAP.ps1" "Clean both AUPs + launch MEHEN stack"
    $script:ChannelState = "GRAY"
    $script:Metrics.Channel = "FPRIME STARTUP"
    $script:Metrics.Direction = "--"
    $script:Metrics.LastEvent = "F-Prime startup: no link traffic"
    Update-Visuals
    Add-Log "RESET + OPEN F-PRIME pressed: clean both AUPs, start AUP1/AUP2 F-Prime, create tunnels, and open both GUIs. No secure-link packet is sent in this step."
}

function Check-Services {
    $body = @'
$Root = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $Root "mehen_remote_control.sh"
function Check-NativeResult([string]$Label) {
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("{0}=FAIL exit={1}" -f $Label, $LASTEXITCODE)
        $global:MEHEN_ACTION_FAILED = $true
    } else {
        Write-Host ("{0}=PASS" -f $Label)
    }
}
if (-not (Test-Path $Helper)) {
    Write-Host ("ERROR: missing helper script {0}" -f $Helper)
    $global:MEHEN_ACTION_FAILED = $true
} else {
    Write-Host "[AUP1] Deploying remote MEHEN control helper"
    & scp "$Helper" "xilinx@100.116.148.59:/tmp/mehen_remote_control.sh"; Check-NativeResult "AUP1_HELPER_COPY"
    Write-Host "[AUP1] MEHEN service check"
    & ssh "xilinx@100.116.148.59" "chmod +x /tmp/mehen_remote_control.sh && bash /tmp/mehen_remote_control.sh check"; Check-NativeResult "AUP1_SERVICE_CHECK"

    Write-Host "[AUP2] Deploying remote MEHEN control helper"
    & scp "$Helper" "xilinx@100.71.108.15:/tmp/mehen_remote_control.sh"; Check-NativeResult "AUP2_HELPER_COPY"
    Write-Host "[AUP2] MEHEN service check"
    & ssh "xilinx@100.71.108.15" "chmod +x /tmp/mehen_remote_control.sh && bash /tmp/mehen_remote_control.sh check"; Check-NativeResult "AUP2_SERVICE_CHECK"
}

Write-Host "[FPRIME] Safe-priming both F-Prime event panes through SecureLaneBridge"
Write-Host "[FPRIME] Demo-safe mode sends GET_KEY128 then HASH_TEST with a delay. XOF_TEST and ROUNDTRIP remain manual from the GDS Commanding tab."
Write-Host "[FPRIME] This proves more than TRNG/key readiness while avoiding the prior burst-command health faults."
$CommandKey = "0xfeedcafe"
$Commands = @(
    "SecureLane.secureLaneBridge.GET_KEY128",
    "SecureLane.secureLaneBridge.HASH_TEST"
)
$Targets = @(
    @{ Name = "AUP1"; Base = "http://127.0.0.1:5101" },
    @{ Name = "AUP2"; Base = "http://127.0.0.1:5102" }
)
foreach ($Target in $Targets) {
    $Name = $Target.Name
    $Base = $Target.Base
    Write-Host ("[{0}] F-Prime API target {1}" -f $Name, $Base)
    try {
        $Probe = Invoke-WebRequest -Uri $Base -Method Get -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        Write-Host ("[{0}] FPRIME_GDS_WEB=PASS HTTP={1}" -f $Name, $Probe.StatusCode)
    } catch {
        Write-Host ("[{0}] FPRIME_GDS_WEB=FAIL {1}" -f $Name, $_.Exception.Message)
        $global:MEHEN_ACTION_FAILED = $true
        continue
    }
    foreach ($Command in $Commands) {
        $Escaped = [System.Uri]::EscapeDataString($Command)
        $Uri = ("{0}/commands/{1}" -f $Base, $Escaped)
        $Body = @{ key = $CommandKey; arguments = @() } | ConvertTo-Json -Compress
        try {
            $Response = Invoke-WebRequest -Uri $Uri -Method Put -ContentType "application/json" -Body $Body -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            Write-Host ("[{0}] FPRIME_COMMAND_PASS {1} HTTP={2}" -f $Name, $Command, $Response.StatusCode)
            Write-Host ("[{0}] WAITING_FOR_EVENT_SETTLE 8s" -f $Name)
            Start-Sleep -Seconds 8
        } catch {
            Write-Host ("[{0}] FPRIME_COMMAND_FAIL {1}" -f $Name, $Command)
            Write-Host ("[{0}] {1}" -f $Name, $_.Exception.Message)
            $global:MEHEN_ACTION_FAILED = $true
            break
        }
    }
}
Write-Host "FPRIME_EVENT_SAFE_PRIME_DONE"
'@
    Set-MeasurementPending "check_services" "--" $false
    Set-Status "CHECKING" "Hardware proof + safe F-Prime events; no link traffic" "#FFD166"
    $script:ChannelState = "GRAY"
    $script:Metrics.Channel = "CHECK + SAFE EVENT"
    $script:Metrics.Direction = "--"
    $script:Metrics.AUP1TRNG = "CHECKING"
    $script:Metrics.AUP2TRNG = "CHECKING"
    $script:Metrics.AUP1Temp = "SAMPLING"
    $script:Metrics.AUP2Temp = "SAMPLING"
    $script:Metrics.AUP1Load = "SAMPLING"
    $script:Metrics.AUP2Load = "SAMPLING"
    $script:Metrics.AUP1Uptime = "SAMPLING"
    $script:Metrics.AUP2Uptime = "SAMPLING"
    $script:Metrics.AUP1Ports = "SAMPLING"
    $script:Metrics.AUP2Ports = "SAMPLING"
    $script:Metrics.HWLatency = "RUNNING"
    $script:Metrics.LastEvent = "Board proof running: overlay, TRNG, ASCON KAT, benchmark, F-prime GET_KEY128 + HASH_TEST"
    Update-Visuals
    Add-Log "CHECK + PRIME runs overlay/TRNG/KAT/benchmark checks, then sends safe F-Prime GET_KEY128 + HASH_TEST commands to each GUI. XOF_TEST/ROUNDTRIP remain manual to avoid burst-command health faults."
    Run-ActionWindow "check_services" $body
}

function Deploy-Agents {
    Set-Status "DEPLOYING" "Copying and launching verified MEHEN link agents" "#FFD166"
    Start-External "START_MEHEN_LINK_AGENTS.ps1" "MEHEN verified link agents"
    $script:ChannelState = "YELLOW"
    $script:Metrics.Channel = "AGENTS STARTING"
    Update-Visuals
}


function Invoke-LinkActionBody([string]$Mode, [string]$Direction="AUP1_TO_AUP2", [string]$PayloadB64="", [string]$Reason="") {
    return @"
`$Root = Split-Path -Parent `$PSScriptRoot
`$Runner = Join-Path `$Root 'RUN_MEHEN_LINK_ACTION.ps1'
if (-not (Test-Path `$Runner)) {
    Write-Host ("ERROR: missing link action runner {0}" -f `$Runner)
    `$global:MEHEN_ACTION_FAILED = `$true
} else {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `$Runner -Mode '$Mode' -Direction '$Direction' -PayloadB64 '$PayloadB64' -Reason '$Reason'
    if (`$LASTEXITCODE -ne 0) { `$global:MEHEN_ACTION_FAILED = `$true }
}
"@
}


function Prime-FPrimeEventSet {
    Set-MeasurementPending "fprime_event_set" "--" $false
    $body = @'
Write-Host "[FPRIME] PACED FULL EVENT SET on both AUPs"
Write-Host "[FPRIME] Commands: GET_KEY128, HASH_TEST, XOF_TEST, ROUNDTRIP"
Write-Host "[FPRIME] Expected events: Key128Ready, HashOk, XofOk, RoundTripOk"
$CommandKey = "0xfeedcafe"
$Commands = @(
    @{ Cmd = "SecureLane.secureLaneBridge.GET_KEY128"; Event = "Key128Ready"; Pause = 7 },
    @{ Cmd = "SecureLane.secureLaneBridge.HASH_TEST"; Event = "HashOk"; Pause = 9 },
    @{ Cmd = "SecureLane.secureLaneBridge.XOF_TEST"; Event = "XofOk"; Pause = 11 },
    @{ Cmd = "SecureLane.secureLaneBridge.ROUNDTRIP"; Event = "RoundTripOk"; Pause = 12 }
)
$Targets = @(
    @{ Name = "AUP1"; Base = "http://127.0.0.1:5101" },
    @{ Name = "AUP2"; Base = "http://127.0.0.1:5102" }
)
foreach ($Target in $Targets) {
    $Name = $Target.Name
    $Base = $Target.Base
    Write-Host ("[{0}] F-Prime API target {1}" -f $Name, $Base)
    try {
        $Probe = Invoke-WebRequest -Uri $Base -Method Get -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host ("[{0}] FPRIME_GDS_WEB=PASS HTTP={1}" -f $Name, $Probe.StatusCode)
    } catch {
        Write-Host ("[{0}] FPRIME_GDS_WEB=FAIL {1}" -f $Name, $_.Exception.Message)
        $global:MEHEN_ACTION_FAILED = $true
        continue
    }
    foreach ($Item in $Commands) {
        $Command = $Item.Cmd
        $Expected = $Item.Event
        $Escaped = [System.Uri]::EscapeDataString($Command)
        $Uri = ("{0}/commands/{1}" -f $Base, $Escaped)
        $Body = @{ key = $CommandKey; arguments = @() } | ConvertTo-Json -Compress
        try {
            $Response = Invoke-WebRequest -Uri $Uri -Method Put -ContentType "application/json" -Body $Body -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Host ("[{0}] FPRIME_EVENT_COMMAND_PASS {1} EXPECT_EVENT={2} HTTP={3}" -f $Name, $Command, $Expected, $Response.StatusCode)
            Start-Sleep -Seconds ([int]$Item.Pause)
        } catch {
            Write-Host ("[{0}] FPRIME_EVENT_COMMAND_FAIL {1}" -f $Name, $Command)
            Write-Host ("[{0}] {1}" -f $Name, $_.Exception.Message)
            $global:MEHEN_ACTION_FAILED = $true
            break
        }
    }
}
if (-not $global:MEHEN_ACTION_FAILED) {
    try { $global:LASTEXITCODE = 0 } catch {}
    Write-Host "FPRIME_FULL_EVENT_SET_RESULT=PASS"
}
Write-Host "FPRIME_FULL_EVENT_SET_DONE"
'@
    Set-Status "FPRIME EVT" "Paced full F-Prime event set: key, hash, xof, roundtrip" "#FFD166"
    Set-OperatorGate "BUSY" "F-Prime event set running - wait for DONE" "#FFD166"
    $script:ChannelState = "GRAY"
    $script:Metrics.Channel = "FPRIME EVENTS"
    $script:Metrics.FPrimeEvents = "running"
    $script:Metrics.LastEvent = "F-Prime full event set launched: Key128Ready, HashOk, XofOk, RoundTripOk"
    Update-Visuals
    Run-ActionWindow "fprime_event_set" $body
}

function Establish-Channel {
    $payload = "MEHEN SESSION PROBE " + (Get-Date).ToUniversalTime().ToString("HHmmss")
    Set-MeasurementPending "session_ready" "AUP1_TO_AUP2" $false
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
    $script:ChannelState = "YELLOW"
    $script:Metrics.Channel = "NEGOTIATING"
    $script:Metrics.Direction = "AUP1_TO_AUP2"
    $script:Metrics.LastEvent = "TRNG/session negotiation launched AUP1 -> AUP2"
    Update-Visuals
    Run-ActionWindow "session_ready" (Invoke-LinkActionBody "session" "AUP1_TO_AUP2" $payloadB64 "session_ready")
    Add-Log "Session-establish probe launched through stable link runner: verified receivers, retry on transient socket-close, safe F-Prime pulse after success."
}

function Send-Packet([string]$Dir, [bool]$Tamper=$false) {
    $actionNamePreview = if ($Tamper) { "tamper_test" } else { "send_$Dir" }
    Set-MeasurementPending $actionNamePreview $Dir $Tamper
    $payload = $script:UI.PayloadBox.Text
    if ([string]::IsNullOrWhiteSpace($payload)) { $payload = "MEHEN secure telemetry packet" }
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
    $script:ChannelState = if ($Tamper) { "RED" } else { "BLUE" }
    $script:Metrics.Channel = if ($Tamper) { "TAMPER INJECTED" } else { "PACKET MOVING" }
    $script:Metrics.Direction = $Dir
    $script:Metrics.LastEvent = if ($Tamper) { "Tamper packet launched: expect BAD_TAG reject" } else { "AEAD encrypt/transmit launched: $Dir" }
    Update-Visuals
    $mode = if ($Tamper) { "tamper" } else { "send" }
    $actionName = if ($Tamper) { "tamper_test" } else { "send_$Dir" }
    Run-ActionWindow $actionName (Invoke-LinkActionBody $mode $Dir $payloadB64 $actionName)
    Add-Log "Packet action launched through stable link runner: $Dir tamper=$Tamper. Runner restarts stale receivers and retries once if a socket closes."
}

function Run-FullDemo {
    Set-MeasurementPending "full_demo" "BIDIRECTIONAL" $false
    Set-Status "FULL DEMO" "Session, bidirectional send, tamper rejection" "#FFD166"
    $script:ChannelState = "BLUE"
    $script:Metrics.Channel = "FULL DEMO RUNNING"
    $script:Metrics.Direction = "BIDIRECTIONAL"
    $script:Metrics.LastEvent = "Full demo launched: session, forward packet, reverse packet, tamper reject"
    Update-Visuals
    $payloadText = $script:UI.PayloadBox.Text
    if ([string]::IsNullOrWhiteSpace($payloadText)) { $payloadText = "MEHEN secure telemetry packet" }
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadText))
    Run-ActionWindow "full_demo" (Invoke-LinkActionBody "full" "AUP1_TO_AUP2" $payloadB64 "full_demo")
    Add-Log "Full demo launched through stable link runner: preflight before each phase, retry on transient socket-close, expected tamper rejection handled as PASS."
}

function Stop-Cleanup {
    Set-Status "STOPPING" "Cleaning boards and demo processes" "#FFD166"
    Set-OperatorGate "BUSY" "Cleanup running" "#FFD166"
    Start-External "STOP_CLEANUP.ps1" "Stop cleanup"
}

function Read-RecentLogs {
    $dir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $dir)) { return "" }
    $texts = New-Object System.Collections.Generic.List[string]
    $files = Get-ChildItem $dir -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 24 | Sort-Object LastWriteTime
    foreach ($f in $files) {
        try { [void]$texts.Add((Get-Content $f.FullName -Tail 1200 -ErrorAction SilentlyContinue) -join "`n") } catch {}
    }
    return ($texts -join "`n")
}

function Mark-Seen([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    if ($script:SeenEvents.ContainsKey($Key)) { return $false }
    $script:SeenEvents[$Key] = $true
    return $true
}

function Apply-PacketMetrics([string]$Direction, [string]$Seq, [string]$TagFp, [int]$Bytes, [string]$Verify, [string]$KeyFp="") {
    if ($KeyFp) { $script:Metrics.KeyFp = $KeyFp; $script:Metrics.Channel = "READY" }
    if ($Direction) { $script:Metrics.Direction = $Direction }
    if ($TagFp) { $script:Metrics.Tag = $TagFp }
    if ($Bytes -gt 0) { $script:Metrics.BytesMoved = [int]$script:Metrics.BytesMoved + $Bytes }
    if ($Verify) { $script:Metrics.Verify = $Verify }
    if (($Verify -eq "BAD_TAG") -or ($Verify -eq "BAD TAG")) { $script:ChannelState = "RED"; $script:Metrics.Channel = "ALERT"; $script:Metrics.Verify = "BAD TAG" }
    elseif ($Verify -eq "PASS") { $script:ChannelState = "GREEN"; $script:Metrics.Channel = "READY" }
}

function Apply-FullDemoSummaryIfPass([string]$Text) {
    # RUN FULL DEMO intentionally ends with a tamper packet. The tamper step should create
    # BAD_TAG evidence, but the final dashboard state should summarize the complete demo as PASS,
    # not leave the whole mission looking like an alert/failure.
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text -notmatch "MEHEN_LINK_ACTION_RESULT=PASS\s+mode=full") { return }
    $script:ChannelState = "GREEN"
    $script:Metrics.Channel = "DEMO PASS"
    $script:Metrics.Direction = "BIDIRECTIONAL"
    $script:Metrics.Verify = "PASS + REJECT OK"
    $script:Metrics.LastEvent = "FULL DEMO PASS: session + AUP1->AUP2 + AUP2->AUP1 + tamper rejected"
    $script:Metrics.FPrimeEvents = if ($script:Metrics.FPrimeEvents -and $script:Metrics.FPrimeEvents -ne "none") { $script:Metrics.FPrimeEvents } else { "safe pulse" }
}


function Update-BoardTelemetryFromBlock([string]$NodeName, [string]$Block) {
    if ([string]::IsNullOrWhiteSpace($Block)) { return }
    $script:LastTelemetrySeen = Get-Date
    $script:Metrics.DataState = "TELEM OK"
    $script:Metrics.TelemetryAge = "0s"
    $prefix = if ($NodeName -eq "AUP1") { "AUP1" } else { "AUP2" }
    $m = [regex]::Match($Block, "BOARD_TEMP_C=([0-9.]+|NA)")
    if ($m.Success) { $script:Metrics["${prefix}Temp"] = if ($m.Groups[1].Value -eq "NA") { "NA" } else { ("{0:N1} C" -f [double]$m.Groups[1].Value) } }
    $m = [regex]::Match($Block, "BOARD_TEMP_SOURCE=([^`r`n]+)")
    if ($m.Success) { $tv=$m.Groups[1].Value.Trim(); if ($tv -ne "NA") { $k=("telemetry_temp_source:{0}:{1}" -f $NodeName,$tv); if (Mark-Seen $k) { Add-Log ("{0} BOARD_TEMP_SOURCE={1}" -f $NodeName, $tv) } } }
    $m = [regex]::Match($Block, "LOAD_AVG=([^`r`n]+)")
    if ($m.Success) { $script:Metrics["${prefix}Load"] = $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($Block, "UPTIME_MIN=([0-9]+)")
    if ($m.Success) {
        $mins = [int]$m.Groups[1].Value
        if ($mins -ge 1440) { $script:Metrics["${prefix}Uptime"] = ("{0}d {1}h" -f [math]::Floor($mins/1440), [math]::Floor(($mins % 1440)/60)) }
        elseif ($mins -ge 60) { $script:Metrics["${prefix}Uptime"] = ("{0}h {1}m" -f [math]::Floor($mins/60), ($mins % 60)) }
        else { $script:Metrics["${prefix}Uptime"] = ("{0}m" -f $mins) }
    }
    $m = [regex]::Match($Block, "PORT_SUMMARY=([^`r`n]+)")
    if ($m.Success) { $script:Metrics["${prefix}Ports"] = Compact-PortSummary($m.Groups[1].Value.Trim()) }
    $m = [regex]::Match($Block, "MEM_AVAILABLE_MB=([0-9]+)")
    if ($m.Success) { $k=("telemetry_mem:{0}:{1}" -f $NodeName,$m.Groups[1].Value); if (Mark-Seen $k) { Add-Log ("{0} MEM_AVAILABLE_MB={1}" -f $NodeName, $m.Groups[1].Value) } }
    $m = [regex]::Match($Block, "KERNEL=([^`r`n]+)")
    if ($m.Success) { $kv=$m.Groups[1].Value.Trim(); $k=("telemetry_kernel:{0}:{1}" -f $NodeName,$kv); if (Mark-Seen $k) { Add-Log ("{0} KERNEL={1}" -f $NodeName, $kv) } }
}

function Poll-Metrics {
    $txt = Read-RecentLogs
    if ($txt.Length -eq 0) { return }

    foreach ($m in [regex]::Matches($txt, "ACTION_DURATION_SEC:\s*([A-Za-z0-9_\-]+)\s+([0-9.]+)")) {
        $action = $m.Groups[1].Value
        $sec = [double]$m.Groups[2].Value
        $key = ("action_duration:{0}:{1}" -f $action,$sec)
        if (Mark-Seen $key) {
            # Do not call Complete-ActionTimer here by itself: it clears ActiveActionName
            # without changing GATE from BUSY. That was the reason CHECK/FPRIME could look stuck.
            $script:Metrics.LastAction = $action
            $script:Metrics.ActionSec = ("{0:N1} s" -f $sec)
            if ($script:ActiveActionName -eq $action -and ($txt -notmatch ("ACTION FAILED:\s*" + [regex]::Escape($action)))) {
                Complete-ActiveActionSafe $action (Mission-State-AfterAction $action) ("{0} finished; ready for next button" -f $action) ("Action completed: {0}" -f $action)
            }
            Add-Log ("TIME: {0} took {1:N1} s" -f $action,$sec)
        }
    }


    # Robust stuck-BUSY recovery: if the active action printed its duration and did not print
    # ACTION FAILED for that same action, treat it as completed. This catches cases where
    # transcript flushing or a repeated-action sentinel is missed by the narrower detectors.
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ActiveActionName)) {
        $active = [regex]::Escape([string]$script:ActiveActionName)
        if (($txt -match ("ACTION_DURATION_SEC:\s*" + $active + "\s+[0-9.]+")) -and ($txt -notmatch ("ACTION FAILED:\s*" + $active))) {
            $doneName = [string]$script:ActiveActionName
            $state = Mission-State-AfterAction $doneName
            Complete-ActiveActionSafe $doneName $state ("{0} finished; ready for next button" -f $doneName) ("Action completed: {0}" -f $doneName)
        }
    }

    # Robust CHECK + PRIME completion: the important proof is both service checks plus the
    # safe F-Prime prime stage. Do not leave the operator gate BUSY if the final sentinel
    # is missed but the AUP checks and F-Prime commands are visible in the transcript.
    if ($script:ActiveActionName -eq "check_services") {
        $bothChecks = ($txt -match "AUP1_SERVICE_CHECK=PASS" -and $txt -match "AUP2_SERVICE_CHECK=PASS")
        $safePrime = ($txt -match "FPRIME_EVENT_SAFE_PRIME_DONE" -or (($txt -match "AUP1.*FPRIME_COMMAND_PASS.*HASH_TEST") -and ($txt -match "AUP2.*FPRIME_COMMAND_PASS.*HASH_TEST")))
        $noCheckFail = ($txt -notmatch "ACTION FAILED:\s*check_services" -and $txt -notmatch "FPRIME_COMMAND_FAIL" -and $txt -notmatch "AUP1_SERVICE_CHECK=FAIL" -and $txt -notmatch "AUP2_SERVICE_CHECK=FAIL")
        if ($bothChecks -and $safePrime -and $noCheckFail) {
            Complete-ActiveActionSafe "check_services" "CHECK OK" "board proof + F-Prime key/hash events complete" "CHECK PASS: board proof plus safe F-Prime GET_KEY128/HASH_TEST events"
            $script:Metrics.FPrimeEvents = "Key128Ready + HashOk"
            $script:Metrics.DataState = "TELEM OK"
        }
    }


    # Some transient action windows close quickly and may not leave ACTION COMPLETE visible
    # to the polling loop in time. These explicit done sentinels mark successful completion.
    if ($script:ActiveActionName -eq "check_services" -and $txt -match "FPRIME_EVENT_SAFE_PRIME_DONE" -and $txt -match "AUP1_SERVICE_CHECK=PASS" -and $txt -match "AUP2_SERVICE_CHECK=PASS") {
        $durText = Complete-ActionTimer "check_services"
        Set-OperatorGate "DONE" ("check_services complete in {0}; ready for next button" -f $durText) "#29D15F"
        Set-Status "CHECK OK" ("hardware proof + F-Prime key/hash events complete in {0}" -f $durText) "#29D15F"
        $script:Metrics.FPrimeEvents = "Key128Ready + HashOk"
        $script:Metrics.DataState = "TELEM OK"
        $script:Metrics.LastEvent = "CHECK PASS: board proof plus safe F-Prime GET_KEY128/HASH_TEST events"
        Add-Log ("DONE: check_services explicit sentinel detected in {0}. Ready for next operator step." -f $durText)
    }

    if ($script:ActiveActionName -eq "fprime_event_set" -and $txt -match "FPRIME_FULL_EVENT_SET_DONE") {
        $durText = Complete-ActionTimer "fprime_event_set"
        Set-OperatorGate "DONE" ("F-Prime full event set complete in {0}; ready" -f $durText) "#29D15F"
        Set-Status "FPRIME EVT" ("Key128Ready + HashOk + XofOk + RoundTripOk in {0}" -f $durText) "#29D15F"
        $script:Metrics.FPrimeEvents = "FULL SET DONE"
        $script:Metrics.LastEvent = "F-Prime full event set complete"
        Add-Log ("DONE: F-Prime full event set completion detected in {0}." -f $durText)
    }


    if (-not [string]::IsNullOrWhiteSpace([string]$script:ActiveActionName)) {
        $activeName = [regex]::Escape([string]$script:ActiveActionName)
        if ($txt -match ("ACTION COMPLETE:\s*" + $activeName)) {
            $doneName = [string]$script:ActiveActionName
            $durText = Complete-ActionTimer $doneName
            Set-OperatorGate "DONE" ("{0} complete in {1}; ready" -f $doneName,$durText) "#29D15F"
            Set-Status (Get-StatusForAction $doneName) ("{0} complete in {1}" -f $doneName,$durText) "#29D15F"
            Add-Log ("DONE: {0} ACTION COMPLETE detected in {1}." -f $doneName,$durText)
        }
    }

    foreach ($m in [regex]::Matches($txt, "MEHEN_LINK_ACTION_RESULT=PASS\s+mode=([A-Za-z0-9_\-]+)")) {
        $mode = $m.Groups[1].Value
        $action = if ($mode -eq "full") { "full_demo" } elseif ($mode -eq "session") { "session_ready" } elseif ($mode -eq "tamper") { "tamper_test" } else { $script:ActiveActionName }
        if ($script:ActiveActionName -eq $action) {
            $durText = Complete-ActionTimer $action
            Set-OperatorGate "DONE" ("{0} link action PASS in {1}; ready" -f $action,$durText) "#29D15F"
            Set-Status (Mission-State-AfterAction $action) ("{0} link action PASS in {1}" -f $action,$durText) "#29D15F"
            $script:Metrics.LastEvent = ("Link action pass: {0}" -f $action)
            if ($mode -eq "full") { Apply-FullDemoSummaryIfPass $txt }
            Add-Log ("DONE: {0} link action PASS in {1}." -f $action,$durText)
        }
    }

    foreach ($m in [regex]::Matches($txt, "ACTION COMPLETE:\s*([A-Za-z0-9_\-]+)")) {
        $action = $m.Groups[1].Value
        if ($script:ActiveActionName -eq $action) {
            $missionState = Mission-State-AfterAction $action
            $durText = if ($script:Metrics.LastAction -eq $action) { $script:Metrics.ActionSec } else { Complete-ActionTimer $action }
            Set-OperatorGate "DONE" ("{0} done in {1}; ready for next button" -f $action,$durText) "#29D15F"
            Set-Status $missionState ("{0} complete in {1} - ready" -f $action,$durText) "#29D15F"
            $script:Metrics.LastEvent = ("Action complete: {0}" -f $action)
            Add-Log ("DONE: {0} in {1}. Ready for next operator step." -f $action,$durText)
        }
    }
    foreach ($m in [regex]::Matches($txt, "ACTION FAILED:\s*([A-Za-z0-9_\-]+)")) {
        $action = $m.Groups[1].Value
        $key = ("action_failed:{0}" -f $action)
        if (Mark-Seen $key) {
            if ($script:ActiveActionName -eq $action) { $script:ActiveActionName = "" }
            Set-OperatorGate "FAILED" ("Inspect terminal/log for {0}" -f $action) "#FF4B4B"
            Set-Status "FAILED" ("{0} failed - do not continue" -f $action) "#FF4B4B"
            $script:Metrics.LastEvent = ("Action failed: {0}" -f $action)
            Add-Log ("FAILED: {0}. Do not press the next button until fixed." -f $action)
        }
    }
    if (($txt -match "ONE-BUTTON F-PRIME RESET \+ OPEN COMPLETE") -or ($txt -match "START STACK COMPLETE")) {
        if (Mark-Seen "stack_complete_ready") {
            $durText = Complete-ActionTimer "reset_open"
            Set-OperatorGate "DONE" ("F-Prime open in {0}; press CHECK + PRIME" -f $durText) "#29D15F"
            Set-Status "STACK RDY" ("F-Prime stack open in {0} - ready for check" -f $durText) "#29D15F"
            Add-Log ("DONE: F-Prime reset/open complete in {0}. Ready for CHECK + PRIME F-PRIME." -f $durText)
        }
    }
    if ($txt -match "MEHEN_ACTION_ABORTED|MEHEN_AGENT_PREFLIGHT=FAIL|FPRIME_GDS_WEB=FAIL|FPRIME_COMMAND_FAIL") {
        if (Mark-Seen "action_abort_or_preflight_fail") {
            if (-not [string]::IsNullOrWhiteSpace([string]$script:ActiveActionName)) { $script:ActiveActionName = "" }
            Set-OperatorGate "FAILED" "Fix shown terminal/log before next button" "#FF4B4B"
            Set-Status "FAILED" "Preflight/action failed - stop and inspect" "#FF4B4B"
            Add-Log "FAILED: action preflight failed. Inspect transient terminal before continuing."
        }
    }

    if ($txt -match "PASS: TRNG") { $script:Metrics.AUP1TRNG = "PASS"; $script:Metrics.AUP2TRNG = "PASS"; $script:Metrics.LastEvent = "TRNG smoke PASS on both boards" }
    if ($txt -match "HASH KAT PASS" -and $txt -match "AEAD ENC KAT PASS" -and $txt -match "AEAD DEC KAT PASS") {
        if ($script:Metrics.HWLatency -eq "--") { $script:Metrics.HWLatency = "KAT PASS" }
        $script:Metrics.LastEvent = "ASCON KAT PASS: hash, AEAD encrypt, AEAD decrypt"
    }
    if ($txt -match "HASH:\s+n=200\s+mean_ms=([0-9.]+)") { $script:Metrics.HWLatency = ("HASH {0} ms" -f $matches[1]) }
    if ($txt -match "XOF:\s+n=200\s+mean_ms=([0-9.]+)") { $script:Metrics.HWLatency = $script:Metrics.HWLatency + " / XOF " + $matches[1] }

    # Strict board telemetry emitted by mehen_remote_control.sh. Use the newest block for each node.
    $aup1Blocks = [regex]::Matches($txt, "(?s)NODE=aup1.*?(?=\[AUP2\]|NODE=aup2|\z)")
    if ($aup1Blocks.Count -gt 0) { Update-BoardTelemetryFromBlock "AUP1" $aup1Blocks[$aup1Blocks.Count-1].Value }
    $aup2Blocks = [regex]::Matches($txt, "(?s)NODE=aup2.*?(?=\[AUP1\]|NODE=aup1|\z)")
    if ($aup2Blocks.Count -gt 0) { Update-BoardTelemetryFromBlock "AUP2" $aup2Blocks[$aup2Blocks.Count-1].Value }
    Maybe-CompleteResetOpen

    # Stable plain-text lines emitted by the MEHEN link agent
    foreach ($m in [regex]::Matches($txt, "SESSION_READY\s+key_fp=([A-Fa-f0-9]+)")) {
        $script:Metrics.Channel = "READY"; $script:Metrics.KeyFp = $m.Groups[1].Value.ToUpper(); if ($script:ChannelState -ne "RED") { $script:ChannelState = "GREEN" }
    }
    foreach ($m in [regex]::Matches($txt, "KEY_EXCHANGE\s+AUP1_NONCE_FP=([A-Fa-f0-9]+)\s+AUP2_NONCE_FP=([A-Fa-f0-9]+)\s+KEY_FP=([A-Fa-f0-9]+)")) {
        $script:Metrics.Channel = "READY"; $script:Metrics.KeyFp = $m.Groups[3].Value.ToUpper(); if ($script:ChannelState -ne "RED") { $script:ChannelState = "GREEN" }
    }
    foreach ($m in [regex]::Matches($txt, "PACKET_SENT\s+direction=([A-Z0-9_]+)\s+seq=([0-9]+)\s+ciphertext_bytes=([0-9]+)\s+tag_bytes=([0-9]+)\s+tag_fp=([A-Fa-f0-9]+)")) {
        $dir=$m.Groups[1].Value; $seq=$m.Groups[2].Value; $bytes=[int]$m.Groups[3].Value + [int]$m.Groups[4].Value; $tag=$m.Groups[5].Value.ToUpper()
        $key=("sent:{0}:{1}:{2}" -f $dir,$seq,$tag)
        if (Mark-Seen $key) { $script:Metrics.PacketsTx=[int]$script:Metrics.PacketsTx+1; $script:Metrics.LastEvent = ("AEAD_ENCRYPT_DONE + CT/TAG_SENT {0} seq={1}" -f $dir,$seq); Apply-PacketMetrics $dir $seq $tag $bytes "" }
        if ($script:ChannelState -ne "RED") { $script:ChannelState = "BLUE"; $script:Metrics.Channel = "PACKET MOVING" }
    }
    foreach ($m in [regex]::Matches($txt, "VERIFY_RESULT\s+(PASS|BAD_TAG)")) {
        $v=$m.Groups[1].Value; $key="verify:$($m.Index):$v"
        if (Mark-Seen $key) { if ($v -eq "PASS") { $script:Metrics.PacketsRx=[int]$script:Metrics.PacketsRx+1; $script:Metrics.LastEvent = "AEAD_DECRYPT_VERIFY_PASS"; Apply-PacketMetrics "" "" "" 0 "PASS" } else { $script:Metrics.LastEvent = "AEAD_DECRYPT_VERIFY_BAD_TAG_REJECT"; Apply-PacketMetrics "" "" "" 0 "BAD TAG" } }
    }
    foreach ($m in [regex]::Matches($txt, "LATENCY_MS\s+([0-9.]+)")) { $script:Metrics.EncryptMs = ("{0} ms" -f $m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($txt, "DECRYPT_MS\s+([0-9.]+)")) { $script:Metrics.DecryptMs = ("{0} ms" -f $m.Groups[1].Value) }

    if ($txt -match "Key128Ready") { $script:Metrics.FPrimeEvents = "Key128Ready" }
    if ($txt -match "HashOk") { $script:Metrics.FPrimeEvents = "Key128Ready+HashOk" }
    if ($txt -match "XofOk") { $script:Metrics.FPrimeEvents = "Key+Hash+XOF" }
    if ($txt -match "RoundTripOk") { $script:Metrics.FPrimeEvents = "Key+Hash+XOF+RT" }
    if ($txt -match "FPRIME_FULL_EVENT_SET_DONE") { $script:Metrics.FPrimeEvents = "FULL SET DONE" }

    foreach ($m in [regex]::Matches($txt, "MISSION_EVENT\s+([^`r`n]+)")) {
        $ev = $m.Groups[1].Value.Trim()
        $key = ("mission_event:{0}:{1}" -f $m.Index, $ev)
        if (Mark-Seen $key) { $script:Metrics.LastEvent = $ev; Add-Log ("MISSION EVENT: {0}" -f $ev) }
    }

    # JSON logs/metrics from remote agents. Parse them loosely because key order can vary.
    foreach ($line in ($txt -split "`n")) {
        $line=$line.Trim()
        if (-not ($line.StartsWith("{") -and $line.EndsWith("}"))) { continue }
        try { $j = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($j.key_fp) { $script:Metrics.KeyFp = ([string]$j.key_fp).ToUpper(); $script:Metrics.Channel = "READY"; if ($script:ChannelState -ne "RED") { $script:ChannelState = "GREEN" } }
        if ($j.last_direction) { $script:Metrics.Direction = [string]$j.last_direction }
        elseif ($j.direction) { $script:Metrics.Direction = [string]$j.direction }
        if ($j.tag_fp) { $script:Metrics.Tag = ([string]$j.tag_fp).ToUpper() }
        if ($j.verify) { if ([string]$j.verify -eq "BAD_TAG") { $script:Metrics.Verify="BAD TAG"; $script:Metrics.Channel="ALERT"; $script:ChannelState="RED" } else { $script:Metrics.Verify=[string]$j.verify; if ([string]$j.verify -eq "PASS") { $script:Metrics.Channel="READY"; if ($script:ChannelState -ne "RED") { $script:ChannelState="GREEN" } } } }
        $bytes = 0
        if ($j.bytes_sent) { $bytes += [int]$j.bytes_sent }
        if ($j.bytes_received) { $bytes += [int]$j.bytes_received }
        if ($j.bytes) { $bytes += [int]$j.bytes }
        $eventKey = "json:$($j.msg):$($j.direction):$($j.last_direction):$($j.last_seq):$($j.tag_fp):$($j.verify):$bytes"
        if ($bytes -gt 0 -and (Mark-Seen $eventKey)) { $script:Metrics.BytesMoved = [int]$script:Metrics.BytesMoved + $bytes }
        if ($j.msg -eq "PACKET_SENT") {
            $k="tx:$($j.direction):$($j.seq):$($j.tag_fp)"
            if ($j.direction) { $script:Metrics.Direction = [string]$j.direction }
            if ($j.tag_fp) { $script:Metrics.Tag = ([string]$j.tag_fp).ToUpper() }
            if ($j.decrypt_latency_ms) { $script:Metrics.DecryptMs = ("{0:N3} ms" -f [double]$j.decrypt_latency_ms) }
            if ($j.latency_ms) { $script:Metrics.EncryptMs = ("{0:N3} ms" -f [double]$j.latency_ms) }
            if (Mark-Seen $k) {
                $script:Metrics.PacketsTx=[int]$script:Metrics.PacketsTx+1
                if ($j.ciphertext_bytes -and $j.tag_bytes) { $script:Metrics.BytesMoved = [int]$script:Metrics.BytesMoved + [int]$j.ciphertext_bytes + [int]$j.tag_bytes }
                $script:Metrics.LastEvent=("AEAD_ENCRYPT_DONE + CT/TAG_SENT {0} seq={1}" -f $j.direction,$j.seq)
            }
        }
        if ($j.msg -eq "PACKET_ACCEPTED") {
            $k="rx:$($j.direction):$($j.seq):$($j.tag_fp)"
            if ($j.direction) { $script:Metrics.Direction = [string]$j.direction }
            if ($j.tag_fp) { $script:Metrics.Tag = ([string]$j.tag_fp).ToUpper() }
            $script:Metrics.Verify = "PASS"
            if ($j.latency_ms) { $script:Metrics.DecryptMs = ("{0:N3} ms" -f [double]$j.latency_ms) }
            if (Mark-Seen $k) { $script:Metrics.PacketsRx=[int]$script:Metrics.PacketsRx+1; $script:Metrics.LastEvent=("AEAD_DECRYPT_VERIFY_PASS {0} seq={1}" -f $j.direction,$j.seq) }
        }
        if ($j.msg -eq "PACKET_REJECTED") {
            $k="reject:$($j.direction):$($j.seq):$($j.tag_fp)"
            if ($j.direction) { $script:Metrics.Direction = [string]$j.direction }
            if ($j.tag_fp) { $script:Metrics.Tag = ([string]$j.tag_fp).ToUpper() }
            $script:Metrics.Verify = "BAD TAG"
            if ($j.latency_ms) { $script:Metrics.DecryptMs = ("{0:N3} ms" -f [double]$j.latency_ms) }
            if (Mark-Seen $k) { $script:Metrics.LastEvent=("AEAD_DECRYPT_VERIFY_BAD_TAG_REJECT {0} seq={1}" -f $j.direction,$j.seq) }
        }
        if ($j.encrypt_latency_ms) { $script:Metrics.EncryptMs = ("{0:N3} ms" -f [double]$j.encrypt_latency_ms) }
        if ($j.decrypt_latency_ms) { $script:Metrics.DecryptMs = ("{0:N3} ms" -f [double]$j.decrypt_latency_ms) }
        if ($j.latency_ms -and -not $j.encrypt_latency_ms -and -not ($j.msg -eq "PACKET_SENT")) { $script:Metrics.DecryptMs = ("{0:N3} ms" -f [double]$j.latency_ms) }
        $jsonDir = if ($j.last_direction) { [string]$j.last_direction } elseif ($j.direction) { [string]$j.direction } else { "" }
        if ($j.sender_temp_c) {
            if ($jsonDir -eq "AUP2_TO_AUP1") { $script:Metrics.AUP2Temp = ("{0:N1} C" -f [double]$j.sender_temp_c) }
            else { $script:Metrics.AUP1Temp = ("{0:N1} C" -f [double]$j.sender_temp_c) }
        }
        if ($j.receiver_temp_c) {
            if ($jsonDir -eq "AUP2_TO_AUP1") { $script:Metrics.AUP1Temp = ("{0:N1} C" -f [double]$j.receiver_temp_c) }
            else { $script:Metrics.AUP2Temp = ("{0:N1} C" -f [double]$j.receiver_temp_c) }
        }
        if ($j.sender_trng) {
            if ($jsonDir -eq "AUP2_TO_AUP1") { $script:Metrics.AUP2TRNG = [string]$j.sender_trng }
            else { $script:Metrics.AUP1TRNG = [string]$j.sender_trng }
        }
        if ($j.receiver_trng) {
            if ($jsonDir -eq "AUP2_TO_AUP1") { $script:Metrics.AUP1TRNG = [string]$j.receiver_trng }
            else { $script:Metrics.AUP2TRNG = [string]$j.receiver_trng }
        }
    }
}
    # Final override for full-demo success: keep BAD_TAG as evidence in the logs, but show the
    # dashboard outcome as DEMO PASS when the runner reports the full sequence completed.
    Apply-FullDemoSummaryIfPass $txt


function Update-Visuals {
    if ($script:UI.ContainsKey("Utc")) { $script:UI.Utc.Text = "UTC " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") }
    if ($script:UI.ContainsKey("Elapsed")) {
        if ($null -eq $script:MissionStart) { $script:UI.Elapsed.Text = "00:00:00" } else { $d=(Get-Date)-$script:MissionStart; $script:UI.Elapsed.Text=("{0:00}:{1:00}:{2:00}" -f [int]$d.TotalHours,$d.Minutes,$d.Seconds) }
    }
    $color = switch ($script:ChannelState) { "GRAY" {"#4B5563"} "YELLOW" {"#FFD166"} "GREEN" {"#29D15F"} "BLUE" {"#20B9FF"} "RED" {"#FF4B4B"} default {"#4B5563"} }
    if ($script:UI.ContainsKey("ChannelState")) { $script:UI.ChannelState.Text = Short-ChannelName([string]$script:Metrics.Channel); $script:UI.ChannelState.ForeColor = C $color }
    if ($script:UI.ContainsKey("ChannelCanvas")) { $script:UI.ChannelCanvas.Invalidate() }
    if ($script:UI.ContainsKey("PacketFlow")) {
        $script:AnimTick++
        $dots = "." * (($script:AnimTick % 4) + 1)
        $dirTxt = if ($script:Metrics.Direction -eq "BIDIRECTIONAL") { "AUP1 <-> AUP2" } elseif ($script:Metrics.Direction -eq "AUP2_TO_AUP1") { "AUP2 -> AUP1" } elseif ($script:Metrics.Direction -eq "AUP1_TO_AUP2") { "AUP1 -> AUP2" } else { "bidirectional lane ready" }
        $flow = switch ($script:ChannelState) {
            "GRAY" {
                if ($script:Metrics.Channel -eq "FPRIME STARTUP") { "F-PRIME STARTUP ONLY  |  no AUP-to-AUP packets yet" }
                elseif ($script:Metrics.Channel -eq "CHECK + SAFE EVENT") { "BOARD CHECK + SAFE F-PRIME EVENT  |  no secure-link traffic" }
                else { "NO SECURE SESSION  |  press ESTABLISH SECURE CHANNEL" }
            }
            "YELLOW" { "TRNG + SESSION NEGOTIATION" + $dots }
            "GREEN" { "SECURE CHANNEL READY  |  KEY FP: " + $script:Metrics.KeyFp }
            "BLUE" { "MOVING PACKET: " + $dirTxt + "  |  CIPHERTEXT + 16 B TAG" }
            "RED" { "BAD TAG / PACKET REJECTED" }
            default { "NO SECURE SESSION" }
        }
        $script:UI.PacketFlow.Text = Short-UiText $flow 68
        $script:UI.PacketFlow.ForeColor = C $color
    }
    if ($script:UI.ContainsKey("EventRail")) {
        $script:UI.EventRail.Text = Short-UiText ("EVENT RAIL: {0}" -f $script:Metrics.LastEvent) 78
        $script:UI.EventRail.ForeColor = C $(if ($script:ChannelState -eq "RED") { "#FF4B4B" } elseif ($script:ChannelState -eq "GREEN") { "#29D15F" } elseif ($script:ChannelState -eq "BLUE") { "#20B9FF" } else { "#FFD166" })
    }
    if ($script:UI.ContainsKey("ChannelTrack")) { $script:UI.ChannelTrack.BackColor = C $color }
    if ($script:UI.ContainsKey("PacketDot")) {
        $x1 = 258; $x2 = 444; $yDot = 168
        $phase = ($script:AnimTick % 14) / 13.0
        if ($script:ChannelState -eq "GRAY") {
            $script:UI.PacketDot.Visible = $false
        } else {
            $script:UI.PacketDot.Visible = $true
            if ($script:ChannelState -eq "GREEN") { $phase = 0.5 }
            elseif ($script:ChannelState -eq "RED") { $phase = 0.85 }
            elseif ($script:Metrics.Direction -eq "AUP2_TO_AUP1") { $phase = 1.0 - $phase }
            $x = [int]($x1 + (($x2 - $x1) * $phase))
            $script:UI.PacketDot.Location = [System.Drawing.Point]::new($x, $yDot)
            $script:UI.PacketDot.ForeColor = C $color
        }
    }
    foreach ($stepName in @("Step1","Step2","Step3","Step4")) { if ($script:UI.ContainsKey($stepName)) { $script:UI[$stepName].ForeColor = C "#4B5563" } }
    if ($script:ChannelState -eq "YELLOW") { foreach ($stepName in @("Step1","Step2")) { if ($script:UI.ContainsKey($stepName)) { $script:UI[$stepName].ForeColor = C "#FFD166" } } }
    elseif ($script:ChannelState -eq "GREEN") { foreach ($stepName in @("Step1","Step2","Step4")) { if ($script:UI.ContainsKey($stepName)) { $script:UI[$stepName].ForeColor = C "#29D15F" } } }
    elseif ($script:ChannelState -eq "BLUE") { foreach ($stepName in @("Step1","Step2","Step3")) { if ($script:UI.ContainsKey($stepName)) { $script:UI[$stepName].ForeColor = C "#20B9FF" } } }
    elseif ($script:ChannelState -eq "RED") { foreach ($stepName in @("Step4")) { if ($script:UI.ContainsKey($stepName)) { $script:UI[$stepName].ForeColor = C "#FF4B4B" } } }
    if ($script:LastTelemetrySeen) {
        $age = [int]((Get-Date) - $script:LastTelemetrySeen).TotalSeconds
        if ($age -lt 60) { $script:Metrics.TelemetryAge = ("{0}s" -f $age) }
        else { $script:Metrics.TelemetryAge = ("{0}m" -f [math]::Floor($age/60)) }
        if ($age -gt 45) { $script:Metrics.DataState = "TELEM STALE" }
    }
    if ($script:ActiveActionName -and $script:ActionStartTimes.ContainsKey($script:ActiveActionName)) {
        $script:Metrics.ActionSec = ("{0:N1} s..." -f ((Get-Date) - $script:ActionStartTimes[$script:ActiveActionName]).TotalSeconds)
    }
    foreach ($k in $script:Metrics.Keys) {
        if ($script:UI.ContainsKey("M_$k")) { $script:UI["M_$k"].Text = Short-UiText ([string]$script:Metrics[$k]) 28 }
    }
}

function Draw-ChannelCanvas($Sender, $E) {
    $g = $E.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $Sender.Width
    $h = $Sender.Height
    $g.Clear((C "#02070E"))

    $stateColor = switch ($script:ChannelState) { "GRAY" { C "#4B5563" } "YELLOW" { C "#FFD166" } "GREEN" { C "#29D15F" } "BLUE" { C "#20B9FF" } "RED" { C "#FF4B4B" } default { C "#4B5563" } }
    $muted = [System.Drawing.Color]::FromArgb(90, $stateColor)
    $bright = [System.Drawing.Color]::FromArgb(245, $stateColor)
    $white = [System.Drawing.SolidBrush]::new((C "#DCEBFF"))
    $gold = [System.Drawing.SolidBrush]::new((C "#FFD166"))
    $cyan = [System.Drawing.SolidBrush]::new((C "#20B9FF"))
    $redBrush = [System.Drawing.SolidBrush]::new((C "#FF4B4B"))

    # Star field / telemetry speckles
    $starBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(125, (C "#9EC7FF")))
    for ($i=0; $i -lt 38; $i++) {
        $sx = (17 + 41*$i + ($script:AnimTick % 17)) % [Math]::Max($w,1)
        $sy = (11 + 29*$i) % [Math]::Max($h,1)
        $r = 1 + (($i + $script:AnimTick) % 2)
        $g.FillEllipse($starBrush, $sx, $sy, $r, $r)
    }

    $leftX = 34; $rightX = $w - 34
    $upperY = [int]($h * 0.38)
    $lowerY = [int]($h * 0.66)
    $reverse = ($script:Metrics.Direction -eq "AUP2_TO_AUP1")
    $bidi = ($script:Metrics.Direction -eq "BIDIRECTIONAL")

    $dashPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(90, (C "#9EC7FF")), 2)
    $dashPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $activePen = [System.Drawing.Pen]::new($bright, 5)
    $inactivePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(85, $stateColor), 3)
    $activePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $activePen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor
    $inactivePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $inactivePen.EndCap = [System.Drawing.Drawing2D.LineCap]::ArrowAnchor

    # Two visible lanes: upper AUP1->AUP2, lower AUP2->AUP1.
    # In GRAY/standby/check states, draw only quiet dashed lanes so the UI does not imply traffic.
    $g.DrawLine($dashPen, $leftX, $upperY, $rightX, $upperY)
    $g.DrawLine($dashPen, $rightX, $lowerY, $leftX, $lowerY)
    if ($script:ChannelState -ne "GRAY") {
        if ($bidi) {
            $g.DrawLine($activePen, $leftX, $upperY, $rightX, $upperY)
            $g.DrawLine($activePen, $rightX, $lowerY, $leftX, $lowerY)
        } elseif ($reverse) {
            $g.DrawLine($inactivePen, $leftX, $upperY, $rightX, $upperY)
            $g.DrawLine($activePen, $rightX, $lowerY, $leftX, $lowerY)
        } else {
            $g.DrawLine($activePen, $leftX, $upperY, $rightX, $upperY)
            $g.DrawLine($inactivePen, $rightX, $lowerY, $leftX, $lowerY)
        }
    }

    $fontSmall = [System.Drawing.Font]::new("Segoe UI", 8.0, [System.Drawing.FontStyle]::Bold)
    $fontMed = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $fontBig = [System.Drawing.Font]::new("Segoe UI", 11.5, [System.Drawing.FontStyle]::Bold)

    if ($script:ChannelState -eq "GRAY") {
        $g.DrawString("AUP1 <-> AUP2 idle lane", $fontSmall, $cyan, 42, $upperY - 28)
        $g.DrawString("no ciphertext / tag traffic yet", $fontSmall, $white, [int]($w/2)-78, $upperY - 28)
        $g.DrawString("waiting for ESTABLISH SECURE CHANNEL", $fontSmall, $white, [int]($w/2)-116, $lowerY + 11)
    } else {
        $g.DrawString("AUP1 -> AUP2", $fontSmall, $cyan, 42, $upperY - 28)
        $g.DrawString("AAD | ciphertext | 16 B tag", $fontSmall, $white, [int]($w/2)-76, $upperY - 28)
        $g.DrawString("AUP2 -> AUP1", $fontSmall, $cyan, $w-142, $lowerY + 11)
        $g.DrawString("secure reply lane", $fontSmall, $white, [int]($w/2)-48, $lowerY + 11)
    }

    # Node badges
    $nodeBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(210, (C "#0A1728")))
    $nodePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(180, (C "#20B9FF")), 1)
    $g.FillEllipse($nodeBrush, 4, $upperY-22, 44, 44); $g.DrawEllipse($nodePen, 4, $upperY-22, 44, 44)
    $g.FillEllipse($nodeBrush, $w-48, $upperY-22, 44, 44); $g.DrawEllipse($nodePen, $w-48, $upperY-22, 44, 44)
    $g.DrawString("A1", $fontMed, $white, 16, $upperY-11)
    $g.DrawString("A2", $fontMed, $white, $w-36, $upperY-11)

    # Moving packet train. It is deliberately oversized for projector visibility.
    if ($script:ChannelState -eq "GRAY") {
        $idleText = if ($script:Metrics.Channel -eq "FPRIME STARTUP") { "F-PRIME STARTUP - NO LINK TRAFFIC" } elseif ($script:Metrics.Channel -eq "CHECK + SAFE EVENT") { "BOARD CHECK / SAFE F-PRIME EVENT - NO LINK TRAFFIC" } else { "NO SESSION / NO TRAFFIC" }
        $g.DrawString($idleText, $fontBig, $white, [int]($w/2)-160, [int]($h/2)-10)
    } elseif ($script:ChannelState -eq "GREEN") {
        $pulse = 18 + (($script:AnimTick % 10) * 2)
        $ringPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(150, $stateColor), 3)
        $g.DrawEllipse($ringPen, [int]($w/2)-$pulse, [int]($h/2)-$pulse, 2*$pulse, 2*$pulse)
        $g.DrawString("LOCKED", $fontBig, [System.Drawing.SolidBrush]::new($stateColor), [int]($w/2)-38, [int]($h/2)-9)
        $ringPen.Dispose()
    } elseif ($script:ChannelState -eq "RED") {
        $pktX = if ($reverse) { [int]($w*0.28) } else { [int]($w*0.72) }
        $pktY = if ($reverse) { $lowerY } else { $upperY }
        $badPen = [System.Drawing.Pen]::new((C "#FF4B4B"), 6)
        $g.DrawLine($badPen, $pktX-18, $pktY-18, $pktX+18, $pktY+18)
        $g.DrawLine($badPen, $pktX+18, $pktY-18, $pktX-18, $pktY+18)
        $g.DrawString("BAD TAG - REJECT", $fontBig, $redBrush, $pktX-72, $pktY+24)
        $badPen.Dispose()
    } else {
        $phase = (($script:AnimTick % 60) / 60.0)
        $laneList = @()
        if ($bidi) { $laneList = @(@{Y=$upperY; Reverse=$false; Label="CT+TAG"}, @{Y=$lowerY; Reverse=$true; Label="REPLY"}) }
        elseif ($reverse) { $laneList = @(@{Y=$lowerY; Reverse=$true; Label="CT+TAG"}) }
        else { $laneList = @(@{Y=$upperY; Reverse=$false; Label="CT+TAG"}) }
        foreach ($lane in $laneList) {
            for ($i=0; $i -lt 5; $i++) {
                $p = $phase - (0.16 * $i)
                while ($p -lt 0) { $p += 1.0 }
                $laneY = [int]$lane.Y
                if ([bool]$lane.Reverse) { $p = 1.0 - $p }
                $x = [int]($leftX + (($rightX - $leftX) * $p))
                $alpha = 245 - ($i * 32)
                if ($alpha -lt 80) { $alpha = 80 }
                $pktColor = [System.Drawing.Color]::FromArgb($alpha, $stateColor)
                $pktBrush = [System.Drawing.SolidBrush]::new($pktColor)
                $g.FillRectangle($pktBrush, $x-28, $laneY-10, 56, 20)
                $g.FillEllipse($pktBrush, $x-38, $laneY-10, 20, 20)
                $g.FillEllipse($pktBrush, $x+18, $laneY-10, 20, 20)
                if ($i -eq 0) { $g.DrawString([string]$lane.Label, $fontSmall, [System.Drawing.SolidBrush]::new((C "#02070E")), $x-24, $laneY-8) }
                $pktBrush.Dispose()
            }
        }
        $label = if ($script:ChannelState -eq "YELLOW") { "TRNG / SESSION MATERIAL" } elseif ($bidi) { "BIDIRECTIONAL ENCRYPTED PACKET TRAIN" } else { "ENCRYPTED PACKET TRAIN" }
        $g.DrawString($label, $fontBig, [System.Drawing.SolidBrush]::new($stateColor), [int]($w/2)-140, [int]($h/2)-10)
    }

    $starBrush.Dispose(); $dashPen.Dispose(); $activePen.Dispose(); $inactivePen.Dispose(); $fontSmall.Dispose(); $fontMed.Dispose(); $fontBig.Dispose(); $white.Dispose(); $gold.Dispose(); $cyan.Dispose(); $redBrush.Dispose(); $nodeBrush.Dispose(); $nodePen.Dispose()
}
function Build-UI {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "MEHEN Mission Control - Two-AUP Secure Space-Link Demo"
    $form.Size = [System.Drawing.Size]::new(1420, 900)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = C "#050B12"
    $form.MinimumSize = [System.Drawing.Size]::new(1280,820)

    $top = PanelBox $form 12 10 1378 74 "#07111E"
    $logoPath = Join-Path $PSScriptRoot "assets\RSCL_logo.png"
    if (Test-Path $logoPath) {
        $pb = [System.Windows.Forms.PictureBox]::new()
        $pb.Location = [System.Drawing.Point]::new(14,5); $pb.Size = [System.Drawing.Size]::new(64,64)
        $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom; $pb.BackColor = $top.BackColor
        try { $pb.Image = [System.Drawing.Image]::FromFile($logoPath) } catch {}
        $top.Controls.Add($pb)
    }
    LabelText $top 92 7 520 34 "MEHEN MISSION CONTROL" 22 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    LabelText $top 94 42 560 22 "Two-AUP secure link - F'-visible TRNG + ASCON" 9.6 "#9EC7FF" | Out-Null
    $script:UI.StatusStrip = PlainStatusStrip $top 682 7 528 58
    $clockBox = PanelBox $top 1220 7 145 58 "#061322"
    $script:UI.Elapsed = LabelText $clockBox 8 5 128 25 "00:00:00" 12 "#29D15F" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $script:UI.Utc = LabelText $clockBox 8 32 128 18 "UTC --" 7.8 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter)

    $left = PanelBox $form 12 94 292 748 "#07111E"
    LabelText $left 16 10 250 26 "COMMAND DECK" 13 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    $script:UI.BtnStart = ButtonBox $left 16 50 258 60 "1  RESET + OPEN F-PRIME" "clean both + open both GUIs" "#123A54"
    $script:UI.BtnCheck = ButtonBox $left 16 116 258 48 "2  CHECK + PRIME F-PRIME" "key + hash F' events" "#0B3363"
    $script:UI.BtnSession = ButtonBox $left 16 172 258 52 "3  ESTABLISH SECURE CHANNEL" "auto-starts link receivers" "#155A32"
    $script:UI.BtnSend12 = ButtonBox $left 16 232 258 48 "4  SEND AUP1 TO AUP2" "moving ciphertext + tag" "#155A32"
    $script:UI.BtnSend21 = ButtonBox $left 16 288 258 48 "5  SEND AUP2 TO AUP1" "secure reply" "#155A32"
    $script:UI.BtnTamper = ButtonBox $left 16 344 258 48 "6  TAMPER TEST" "bad tag -> reject" "#6B1F1F"
    $script:UI.BtnFull = ButtonBox $left 16 400 258 48 "7  RUN FULL DEMO" "session + bidi + tamper" "#764A10"
    $script:UI.BtnFPrimeEvents = ButtonBox $left 16 456 258 48 "OPTIONAL F-PRIME EVENT SET" "key/hash/xof/roundtrip" "#0B3363"
    $script:UI.BtnStop = ButtonBox $left 16 512 258 48 "STOP / CLEANUP" "kill ports/processes" "#5A1E1E"
    LabelText $left 16 586 250 24 "Payload for secure packet" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    $script:UI.PayloadBox = [System.Windows.Forms.TextBox]::new(); $script:UI.PayloadBox.Location=[System.Drawing.Point]::new(16,614); $script:UI.PayloadBox.Size=[System.Drawing.Size]::new(258,58); $script:UI.PayloadBox.Multiline=$true; $script:UI.PayloadBox.Text=$script:PayloadText; $script:UI.PayloadBox.BackColor=C "#061322"; $script:UI.PayloadBox.ForeColor=C "#F3FAFF"; $script:UI.PayloadBox.Font=F 9; $left.Controls.Add($script:UI.PayloadBox)
    LabelText $left 16 694 250 38 "Operator flow: reset -> check -> session -> send -> tamper -> optional F-prime events" 8 "#FFD166" ([System.Drawing.FontStyle]::Bold) | Out-Null

    $center = PanelBox $form 316 94 736 500 "#07111E"
    LabelText $center 18 10 420 26 "SECURE SPACE-LINK TOPOLOGY" 13 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    $script:UI.EventRail = LabelText $center 80 42 580 22 "EVENT RAIL: standby" 9.4 "#FFD166" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $n1 = PanelBox $center 34 72 230 218 "#0A1728"
    LabelText $n1 18 12 190 28 "AUP1 SPACE NODE" 14 "#20B9FF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n1 18 50 190 26 "F' SecureLaneBridge" 10 "#DCEBFF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n1 22 88 170 24 "TRNG + ASCON" 10 "#29D15F" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n1 22 126 170 20 "GET_KEY128 -> Key128Ready" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n1 22 152 170 20 "HASH_TEST -> HashOk" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n1 22 178 170 20 "XOF / ROUNDTRIP manual" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    $n2 = PanelBox $center 472 72 230 218 "#0A1728"
    LabelText $n2 18 12 190 28 "AUP2 SPACE NODE" 14 "#20B9FF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n2 18 50 190 26 "F' SecureLaneBridge" 10 "#DCEBFF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n2 22 88 170 24 "TRNG + ASCON" 10 "#29D15F" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n2 22 126 170 20 "GET_KEY128 -> Key128Ready" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n2 22 152 170 20 "HASH_TEST -> HashOk" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $n2 22 178 170 20 "XOF / ROUNDTRIP manual" 9 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    $linkBox = PanelBox $center 284 82 168 150 "#061322"
    LabelText $linkBox 12 8 144 16 "LINK STATUS" 7.8 "#9EC7FF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    $script:UI.ChannelState = LabelText $linkBox 10 28 148 30 "STANDBY" 12 "#4B5563" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    LabelText $linkBox 10 66 148 22 "ASCON-AEAD" 9.2 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $linkBox 10 90 148 22 "ciphertext + tag" 8.6 "#9EC7FF" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    LabelText $linkBox 10 114 148 22 "F' pulse + link JSON" 7.8 "#FFD166" ([System.Drawing.FontStyle]::Regular) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null
    $script:UI.PacketFlow = LabelText $center 50 294 636 26 "NO SECURE SESSION" 9.6 "#9EC7FF" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $script:UI.ChannelCanvas = PanelBox $center 42 324 640 134 "#02070E"
    $script:UI.ChannelCanvas.Add_Paint({ param($sender,$e) Draw-ChannelCanvas $sender $e })
    $script:UI.Step1 = LabelText $center 80 462 126 22 "1 TRNG" 8.5 "#4B5563" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $script:UI.Step2 = LabelText $center 210 462 126 22 "2 SESSION" 8.5 "#4B5563" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $script:UI.Step3 = LabelText $center 340 462 126 22 "3 CIPHERTEXT" 8.5 "#4B5563" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    $script:UI.Step4 = LabelText $center 470 462 126 22 "4 VERIFY" 8.5 "#4B5563" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter)
    LabelText $center 62 482 600 18 "TRNG material -> session ready -> encrypt -> tag -> transmit -> decrypt -> verify -> accept/reject" 8.5 "#FFD166" ([System.Drawing.FontStyle]::Bold) ([System.Drawing.ContentAlignment]::MiddleCenter) | Out-Null

    $right = PanelBox $form 1064 94 326 500 "#07111E"
    LabelText $right 16 10 280 24 "LIVE MISSION NUMBERS" 13 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    LabelText $right 16 34 288 18 "Strict facts: board helper + link-agent JSON" 7.4 "#FFD166" ([System.Drawing.FontStyle]::Bold) | Out-Null
    $metricLabels = [ordered]@{
        DataState="Data"; TelemetryAge="Telem age"; LastAction="Last action"; ActionSec="Action time"; FPrimeEvents="F' events";
        Channel="Channel"; KeyFp="Key FP"; Direction="Dir"; PacketsTx="Tx"; PacketsRx="Rx"; BytesMoved="Bytes"; Tag="Tag"; Verify="Verify"; EncryptMs="Enc ms"; DecryptMs="Dec ms";
        AUP1Temp="AUP1 Temp"; AUP2Temp="AUP2 Temp"; AUP1Load="AUP1 Load"; AUP2Load="AUP2 Load"; AUP1Uptime="AUP1 Up"; AUP2Uptime="AUP2 Up"; AUP1Ports="AUP1 Ports"; AUP2Ports="AUP2 Ports"; AUP1TRNG="AUP1 TRNG"; AUP2TRNG="AUP2 TRNG"; HWLatency="HW Lat"
    }
    $y=54
    foreach ($name in $metricLabels.Keys) {
        LabelText $right 16 $y 92 15 $metricLabels[$name] 6.7 "#9EC7FF" ([System.Drawing.FontStyle]::Bold) | Out-Null
        $script:UI["M_$name"] = LabelText $right 112 $y 196 15 (Short-UiText ([string]$script:Metrics[$name]) 28) 6.7 "#DCEBFF"
        $y += 16
    }

    $bottom = PanelBox $form 316 606 1074 236 "#07111E"
    LabelText $bottom 16 8 270 24 "MISSION TIMELINE / LOCAL LOGS" 12 "#F3FAFF" ([System.Drawing.FontStyle]::Bold) | Out-Null
    $script:UI.TerminalView = [System.Windows.Forms.TextBox]::new(); $script:UI.TerminalView.Multiline=$true; $script:UI.TerminalView.ScrollBars="Vertical"; $script:UI.TerminalView.ReadOnly=$true
    $script:UI.TerminalView.Location=[System.Drawing.Point]::new(16,38); $script:UI.TerminalView.Size=[System.Drawing.Size]::new(1040,180); $script:UI.TerminalView.BackColor=C "#02070E"; $script:UI.TerminalView.ForeColor=C "#DCEBFF"; $script:UI.TerminalView.Font=[System.Drawing.Font]::new("Consolas",9)
    $bottom.Controls.Add($script:UI.TerminalView)

    $script:UI.BtnStart.Add_Click({ Safe "START STACK" { Run-IfReady "RESET + OPEN F-PRIME" { Start-Stack } } })
    $script:UI.BtnCheck.Add_Click({ Safe "CHECK SERVICES" { Run-IfReady "CHECK + PRIME F-PRIME" { Check-Services } } })
    $script:UI.BtnFPrimeEvents.Add_Click({ Safe "FPRIME EVENT SET" { Run-IfReady "F-PRIME EVENT SET" { Prime-FPrimeEventSet } } })
    $script:UI.BtnSession.Add_Click({ Safe "ESTABLISH CHANNEL" { Run-IfReady "ESTABLISH SECURE CHANNEL" { Establish-Channel } } })
    $script:UI.BtnSend12.Add_Click({ Safe "SEND AUP1 TO AUP2" { Run-IfReady "SEND AUP1 TO AUP2" { Send-Packet "AUP1_TO_AUP2" $false } } })
    $script:UI.BtnSend21.Add_Click({ Safe "SEND AUP2 TO AUP1" { Run-IfReady "SEND AUP2 TO AUP1" { Send-Packet "AUP2_TO_AUP1" $false } } })
    $script:UI.BtnTamper.Add_Click({ Safe "TAMPER" { Run-IfReady "TAMPER TEST" { Send-Packet "AUP1_TO_AUP2" $true } } })
    $script:UI.BtnFull.Add_Click({ Safe "FULL DEMO" { Run-IfReady "RUN FULL DEMO" { Run-FullDemo } } })
    $script:UI.BtnStop.Add_Click({ Safe "STOP" { Stop-Cleanup } })

    $timer = [System.Windows.Forms.Timer]::new(); $timer.Interval = 250
    $timer.Add_Tick({ Safe "timer" { $script:TimerTick++; if (($script:TimerTick % 4) -eq 0) { Poll-Metrics }; Update-Visuals } })
    $timer.Start()

    Start-LiveTelemetryMonitor
    Add-Log "MEHEN Mission Control $script:AppVersion loaded."
    Add-Log "Use RESET + OPEN F-PRIME first. MISSION STATE shows the current phase; ACTION GATE shows when it is safe to press the next button."
    Add-Log "CHECK + PRIME sends GET_KEY128 + HASH_TEST through each GDS tunnel. The primary flow now keeps ESTABLISH SECURE CHANNEL as button 3; OPTIONAL F-PRIME EVENT SET is below the demo flow and sends GET_KEY128 + HASH_TEST + XOF_TEST + ROUNDTRIP with pacing. In the F-Prime Events page, GET_KEY128 appears as Key128Ready / TRNG key ready, and HASH_TEST appears as HashOk. Mission buttons immediately fill the measurement column with PENDING/RUNNING values, then replace them with strict link-agent JSON once packets complete."
    Set-Status "STANDBY" "MEHEN ready" "#FFD166"
    Set-OperatorGate "READY" "Press RESET + OPEN F-PRIME" "#29D15F"
    Update-Visuals
    return $form
}

$form = Build-UI
[void][System.Windows.Forms.Application]::Run($form)
