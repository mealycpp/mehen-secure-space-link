#!/usr/bin/env bash
# MEHEN remote board control helper v1.0.29
# Runs on AUP1/AUP2. Keeps complex board logic out of Windows PowerShell SSH strings.
set +e

ACTION="${1:-check}"
MEHEN_DIR="${MEHEN_DIR:-/home/xilinx/spaccomputing}"
PY="${PY:-/usr/local/share/pynq-venv/bin/python3}"
LOG_ROOT="/tmp/mehen_remote_control"
mkdir -p "$LOG_ROOT"

cd "$MEHEN_DIR" 2>/dev/null || { echo "NODE=$(hostname)"; echo "ERROR=MEHEN_DIR_NOT_FOUND"; echo "SERVICE_CHECK=FAIL"; exit 2; }
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true

run_capture() {
    local name="$1"
    shift
    local out="$LOG_ROOT/${name}_last.log"
    "$@" > "$out" 2>&1
    local rc=$?
    echo "RC_${name}=$rc"
    return 0
}

print_matches() {
    local file="$1"
    shift
    python3 - "$file" "$@" <<'PY'
import sys
path = sys.argv[1]
terms = sys.argv[2:]
try:
    with open(path, 'r', errors='replace') as f:
        for line in f:
            if any(t in line for t in terms):
                print(line.rstrip())
except FileNotFoundError:
    pass
PY
}

has_text() {
    local file="$1"
    local text="$2"
    python3 - "$file" "$text" <<'PY'
import sys
path, text = sys.argv[1], sys.argv[2]
try:
    data = open(path, 'r', errors='replace').read()
except FileNotFoundError:
    data = ''
sys.exit(0 if text in data else 1)
PY
}

bench_summary() {
    local file="$1"
    python3 - "$file" <<'PY'
import sys, re
path = sys.argv[1]
try:
    data = open(path, 'r', errors='replace').read().splitlines()
except FileNotFoundError:
    data = []
for line in data:
    if line.startswith(('HASH:', 'XOF:', 'AEAD_ENC:', 'AEAD_DEC:')):
        print(line)
        m = re.match(r'([A-Z_]+):.*mean_ms=([0-9.]+)', line)
        if m:
            print(f'BENCH_{m.group(1)}_MEAN_MS={m.group(2)}')
PY
}

board_telemetry() {
    echo "SERVICE=BOARD_TELEMETRY"
    echo "HOSTNAME=$(hostname)"
    echo "KERNEL=$(uname -r)"
    local ipaddr
    ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "IP_ADDR=${ipaddr:-NA}"
    local uptime_s uptime_min
    uptime_s=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    uptime_min=$(( ${uptime_s:-0} / 60 ))
    echo "UPTIME_MIN=$uptime_min"
    local loadavg
    loadavg=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null)
    echo "LOAD_AVG=${loadavg:-NA}"
    local mem_mb
    mem_mb=$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    echo "MEM_AVAILABLE_MB=${mem_mb:-0}"
    local disk_pct
    disk_pct=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}')
    echo "DISK_ROOT_USED=${disk_pct:-NA}"
    python3 - <<'PY'
import glob, os, re, subprocess

def read_float(path):
    try:
        return float(open(path, 'r', errors='replace').read().strip())
    except Exception:
        return None

def label_for_input(path):
    base = os.path.basename(path)
    d = os.path.dirname(path)
    m = re.match(r'(temp\d+)_input$', base)
    parts=[]
    try:
        name = open(os.path.join(d, 'name'), 'r', errors='replace').read().strip()
        if name: parts.append(name)
    except Exception:
        pass
    if m:
        for cand in (os.path.join(d, m.group(1)+'_label'), os.path.join(d, 'label')):
            try:
                lab = open(cand, 'r', errors='replace').read().strip()
                if lab: parts.append(lab)
            except Exception:
                pass
    return '/'.join(parts) if parts else ''

def add_temp(vals, raw, path, source):
    if raw is None: return
    val = float(raw)
    # Linux thermal/hwmon temp inputs are usually millidegC. Some drivers report C.
    if abs(val) > 1000: val = val / 1000.0
    if -40.0 <= val <= 125.0:
        vals.append((val, path, source))

vals=[]
# Standard Linux thermal zones
for path in glob.glob('/sys/class/thermal/thermal_zone*/temp'):
    lab=''
    try:
        lab=open(os.path.join(os.path.dirname(path),'type'), 'r', errors='replace').read().strip()
    except Exception:
        pass
    add_temp(vals, read_float(path), path, 'thermal:' + (lab or 'zone'))

# hwmon sensors, including Xilinx/IIO-backed temperature sensors on many Zynq boards
for path in glob.glob('/sys/class/hwmon/hwmon*/temp*_input'):
    add_temp(vals, read_float(path), path, 'hwmon:' + (label_for_input(path) or 'temp'))

# IIO temperature devices, when exposed without hwmon glue
for raw_path in glob.glob('/sys/bus/iio/devices/iio:device*/in_temp*_raw'):
    stem = raw_path[:-4]  # remove _raw
    raw = read_float(raw_path)
    if raw is None: continue
    scale = read_float(stem + '_scale')
    if scale is None: scale = read_float(os.path.join(os.path.dirname(raw_path), 'in_temp_scale'))
    offset = read_float(stem + '_offset')
    if offset is None: offset = read_float(os.path.join(os.path.dirname(raw_path), 'in_temp_offset'))
    if scale is not None:
        val = (raw + (offset or 0.0)) * scale
        # IIO may report millidegC or degC depending on driver.
        if abs(val) > 1000: val = val / 1000.0
        add_temp(vals, val, raw_path, 'iio:temp')


# Broad bounded sysfs fallback for board-specific sensor paths that are not under standard thermal/hwmon/iio aliases.
if not vals:
    for root in ('/sys/devices/virtual/thermal','/sys/devices/platform','/sys/bus/iio/devices','/sys/class'):
        for dirpath, dirnames, filenames in os.walk(root):
            if len(vals) > 20:
                break
            depth = dirpath[len(root):].count(os.sep)
            if depth > 7:
                dirnames[:] = []
                continue
            for fn in filenames:
                low = fn.lower()
                if low in ('temp','temperature') or low.endswith('temp') or low.startswith('temp') or ('temp' in low and ('input' in low or 'raw' in low)):
                    path = os.path.join(dirpath, fn)
                    add_temp(vals, read_float(path), path, 'sysfs:' + (label_for_input(path) or 'temp'))
        if len(vals) > 20:
            break

# Last-resort lm-sensors parser if installed
if not vals:
    try:
        out = subprocess.check_output(['sensors'], text=True, timeout=2, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            m = re.search(r'([+-]?[0-9]+(?:\.[0-9]+)?)\s*°?C', line)
            if m:
                add_temp(vals, float(m.group(1)), 'sensors', 'lm-sensors')
    except Exception:
        pass

# Prefer plausible SoC/FPGA/XADC style sensors; otherwise use the highest plausible board temp.
if vals:
    def score(item):
        val,path,source=item
        text=(path+' '+source).lower()
        bonus=0
        for key in ('xadc','zynq','zocl','fpga','soc','ps','iio','junction','temp1'):
            if key in text: bonus += 1
        return (bonus, val)
    val,path,source = sorted(vals, key=score, reverse=True)[0]
    print(f'BOARD_TEMP_C={val:.1f}')
    print(f'BOARD_TEMP_SOURCE={source}:{path}')
    print(f'BOARD_TEMP_CANDIDATES={len(vals)}')
else:
    print('BOARD_TEMP_C=NA')
    print('BOARD_TEMP_SOURCE=NO_READABLE_THERMAL_HWMON_IIO_SENSOR')
    print('BOARD_TEMP_CANDIDATES=0')
PY
    local pynq_ver
    pynq_ver=$($PY - <<'PY' 2>/dev/null
try:
    import pynq
    print(getattr(pynq, '__version__', 'unknown'))
except Exception as e:
    print('NA')
PY
)
    echo "PYNQ_VERSION=${pynq_ver:-NA}"
    if [ -e /dev/dri/renderD128 ]; then echo "ZOCL_RENDERD128=YES"; else echo "ZOCL_RENDERD128=NO"; fi
    if [ -e /dev/fpga0 ]; then echo "FPGA0=YES"; else echo "FPGA0=NO"; fi
    local p5000 p5001 p50000 p50100 p9092
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
    echo "BOARD_TELEMETRY=PASS"
}

check_all() {
    local overall="PASS"
    echo "NODE=$(hostname)"
    echo "MEHEN_DIR=$MEHEN_DIR"
    board_telemetry
    echo "SERVICE=OVERLAY"
    run_capture overlay sudo -E "$PY" load_ascon_overlay.py
    print_matches "$LOG_ROOT/overlay_last.log" "Overlay loaded successfully" "trng_axi_0" "ascon_core_0" "FAIL" "ERROR"
    if has_text "$LOG_ROOT/overlay_last.log" "Overlay loaded successfully"; then echo "OVERLAY=PASS"; else echo "OVERLAY=FAIL"; overall="FAIL"; fi

    echo "SERVICE=TRNG"
    run_capture trng sudo -E "$PY" test_trng_axi.py
    print_matches "$LOG_ROOT/trng_last.log" "unique_words" "valid_seen" "health_fail" "PASS: TRNG" "FAIL:"
    if has_text "$LOG_ROOT/trng_last.log" "PASS: TRNG"; then echo "TRNG=PASS"; else echo "TRNG=FAIL"; overall="FAIL"; fi

    echo "SERVICE=ASCON_KAT"
    run_capture kat sudo -E "$PY" run_ascon_full_kat.py
    print_matches "$LOG_ROOT/kat_last.log" "HASH KAT PASS" "AEAD ENC KAT PASS" "AEAD DEC KAT PASS" "ALL REQUESTED KATS PASSED" "FAIL"
    if has_text "$LOG_ROOT/kat_last.log" "ALL REQUESTED KATS PASSED"; then echo "ASCON_KAT=PASS"; else echo "ASCON_KAT=FAIL"; overall="FAIL"; fi

    echo "SERVICE=BENCH"
    run_capture bench sudo -E "$PY" bench_mehen_hw.py
    bench_summary "$LOG_ROOT/bench_last.log"
    if has_text "$LOG_ROOT/bench_last.log" "AEAD_DEC:"; then echo "BENCH=PASS"; else echo "BENCH=FAIL"; overall="FAIL"; fi

    echo "SERVICE_CHECK=$overall"
    if [ "$overall" = "PASS" ]; then exit 0; else exit 1; fi
}

case "$ACTION" in
    check) check_all ;;
    trng)
        echo "NODE=$(hostname)"; echo "SERVICE=TRNG"
        run_capture trng sudo -E "$PY" test_trng_axi.py
        print_matches "$LOG_ROOT/trng_last.log" "unique_words" "valid_seen" "health_fail" "PASS: TRNG" "FAIL:"
        ;;
    kat)
        echo "NODE=$(hostname)"; echo "SERVICE=ASCON_KAT"
        run_capture kat sudo -E "$PY" run_ascon_full_kat.py
        print_matches "$LOG_ROOT/kat_last.log" "HASH KAT PASS" "AEAD ENC KAT PASS" "AEAD DEC KAT PASS" "ALL REQUESTED KATS PASSED" "FAIL"
        ;;
    bench)
        echo "NODE=$(hostname)"; echo "SERVICE=BENCH"
        run_capture bench sudo -E "$PY" bench_mehen_hw.py
        bench_summary "$LOG_ROOT/bench_last.log"
        ;;
    telemetry)
        echo "NODE=$(hostname)"; echo "MEHEN_DIR=$MEHEN_DIR"; board_telemetry
        ;;
    *)
        echo "NODE=$(hostname)"; echo "ERROR=UNKNOWN_ACTION_$ACTION"; exit 64 ;;
esac
