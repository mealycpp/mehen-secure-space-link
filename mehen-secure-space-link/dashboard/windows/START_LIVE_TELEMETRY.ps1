$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "live_telemetry.log"
$PidFile = Join-Path $LogDir "live_telemetry.pid"
try {
    if (Test-Path $PidFile) {
        $old = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($old -match '^[0-9]+$') {
            $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
            if ($p) { exit 0 }
        }
    }
    $PID | Set-Content -Path $PidFile -Encoding ASCII
} catch {}

function Write-LogLine([string]$Text) {
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path $Log -Value ("[{0}] {1}" -f $ts, $Text) -Encoding UTF8
}

$Nodes = @(
    @{ Name = "AUP1"; Host = "100.116.148.59" },
    @{ Name = "AUP2"; Host = "100.71.108.15" }
)
$RemoteScript = @'
echo "NODE=$(hostname)"
echo "SERVICE=LIVE_TELEMETRY"
echo "HOSTNAME=$(hostname)"
echo "KERNEL=$(uname -r 2>/dev/null)"
ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "IP_ADDR=${ipaddr:-NA}"
uptime_s=$(cut -d. -f1 /proc/uptime 2>/dev/null); uptime_min=$(( ${uptime_s:-0} / 60 )); echo "UPTIME_MIN=$uptime_min"
loadavg=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null); echo "LOAD_AVG=${loadavg:-NA}"
mem_mb=$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null); echo "MEM_AVAILABLE_MB=${mem_mb:-0}"
disk_pct=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}'); echo "DISK_ROOT_USED=${disk_pct:-NA}"
python3 - <<'PY'
import os, glob, re, subprocess

def read_float(path):
    try:
        s=open(path,'r',errors='replace').read().strip()
        return float(s)
    except Exception:
        return None

def add(vals, raw, path, source):
    if raw is None: return
    try: val=float(raw)
    except Exception: return
    if abs(val)>1000: val=val/1000.0
    if -40 <= val <= 125:
        vals.append((val,path,source))

def label(path):
    d=os.path.dirname(path); parts=[]
    for f in ('name','type'):
        try:
            v=open(os.path.join(d,f),'r',errors='replace').read().strip()
            if v: parts.append(v)
        except Exception: pass
    m=re.match(r'(temp\d+)_input$', os.path.basename(path))
    if m:
        try:
            v=open(os.path.join(d,m.group(1)+'_label'),'r',errors='replace').read().strip()
            if v: parts.append(v)
        except Exception: pass
    return '/'.join(parts) if parts else 'sensor'

vals=[]
for path in glob.glob('/sys/class/thermal/thermal_zone*/temp'):
    add(vals, read_float(path), path, 'thermal:'+label(path))
for path in glob.glob('/sys/class/hwmon/hwmon*/temp*_input'):
    add(vals, read_float(path), path, 'hwmon:'+label(path))
for raw_path in glob.glob('/sys/bus/iio/devices/iio:device*/in_temp*_raw'):
    raw=read_float(raw_path)
    stem=raw_path[:-4]
    scale=read_float(stem+'_scale') or read_float(os.path.join(os.path.dirname(raw_path),'in_temp_scale'))
    offset=read_float(stem+'_offset') or read_float(os.path.join(os.path.dirname(raw_path),'in_temp_offset')) or 0.0
    if raw is not None and scale is not None:
        add(vals, (raw+offset)*scale, raw_path, 'iio:temp')
# Broad but bounded fallback for board-specific sensor paths.
for root in ('/sys/devices/virtual/thermal','/sys/devices/platform','/sys/bus/iio/devices','/sys/class'):
    for dirpath, dirnames, filenames in os.walk(root):
        if len(vals) > 20: break
        depth = dirpath[len(root):].count(os.sep)
        if depth > 7:
            dirnames[:] = []
            continue
        for fn in filenames:
            low=fn.lower()
            if low in ('temp','temperature') or low.endswith('temp') or low.startswith('temp') or ('temp' in low and ('input' in low or 'raw' in low)):
                path=os.path.join(dirpath,fn)
                add(vals, read_float(path), path, 'sysfs:'+label(path))
    if len(vals) > 20: break
if not vals:
    try:
        out=subprocess.check_output(['sensors'],text=True,timeout=2,stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            m=re.search(r'([+-]?[0-9]+(?:\.[0-9]+)?)\s*°?C', line)
            if m: add(vals, float(m.group(1)), 'sensors', 'lm-sensors')
    except Exception: pass
if vals:
    def score(item):
        val,path,source=item
        text=(path+' '+source).lower()
        bonus=sum(k in text for k in ('xadc','zynq','zocl','fpga','soc','ps','iio','junction','thermal_zone0','temp1'))
        return (bonus,val)
    val,path,source=sorted(vals,key=score,reverse=True)[0]
    print(f'BOARD_TEMP_C={val:.1f}')
    print(f'BOARD_TEMP_SOURCE={source}:{path}')
    print(f'BOARD_TEMP_CANDIDATES={len(vals)}')
else:
    print('BOARD_TEMP_C=NA')
    print('BOARD_TEMP_SOURCE=NO_READABLE_SENSOR')
    print('BOARD_TEMP_CANDIDATES=0')
PY
p5000=$(ss -ltn 2>/dev/null | awk '$4 ~ /:5000$/ {found=1} END {print found?"LISTEN":"NO"}')
p5001=$(ss -ltn 2>/dev/null | awk '$4 ~ /:5001$/ {found=1} END {print found?"LISTEN":"NO"}')
p50000=$(ss -ltn 2>/dev/null | awk '$4 ~ /:50000$/ {found=1} END {print found?"LISTEN":"NO"}')
p50100=$(ss -ltn 2>/dev/null | awk '$4 ~ /:50100$/ {found=1} END {print found?"LISTEN":"NO"}')
p9092=$(ss -ltn 2>/dev/null | awk '$4 ~ /:9092$/ {found=1} END {print found?"LISTEN":"NO"}')
echo "PORT_GDS_5000=$p5000"
echo "PORT_GDS_5001=$p5001"
echo "PORT_FLIGHT_50000=$p50000"
echo "PORT_FLIGHT_50100=$p50100"
echo "PORT_LINK_9092=$p9092"
echo "PORT_SUMMARY=GDS5000:$p5000 GDS5001:$p5001 FSW50000:$p50000 FSW50100:$p50100 LINK9092:$p9092"
echo "LIVE_TELEMETRY=PASS"
'@

Write-LogLine "MEHEN_LIVE_TELEMETRY_MONITOR_START pid=$PID"
while ($true) {
    foreach ($Node in $Nodes) {
        $name = $Node.Name
        $hostAddr = $Node.Host
        Write-LogLine ("[{0}] TELEMETRY_SAMPLE_START" -f $name)
        try {
            $out = $RemoteScript | ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "xilinx@$hostAddr" "bash -s" 2>&1
            $rc = $LASTEXITCODE
            foreach ($line in $out) { Add-Content -Path $Log -Value $line -Encoding UTF8 }
            if ($rc -ne 0) {
                Add-Content -Path $Log -Value ("NODE={0}" -f $name.ToLower()) -Encoding UTF8
                Add-Content -Path $Log -Value "SERVICE=LIVE_TELEMETRY" -Encoding UTF8
                Add-Content -Path $Log -Value ("LIVE_TELEMETRY=FAIL RC={0}" -f $rc) -Encoding UTF8
                Add-Content -Path $Log -Value "BOARD_TEMP_C=AUTH_OR_CONNECT_PENDING" -Encoding UTF8
            }
        } catch {
            Add-Content -Path $Log -Value ("NODE={0}" -f $name.ToLower()) -Encoding UTF8
            Add-Content -Path $Log -Value "SERVICE=LIVE_TELEMETRY" -Encoding UTF8
            Add-Content -Path $Log -Value ("LIVE_TELEMETRY=FAIL {0}" -f $_.Exception.Message) -Encoding UTF8
        }
    }
    Start-Sleep -Seconds 15
}
