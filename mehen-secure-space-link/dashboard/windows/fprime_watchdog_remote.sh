#!/usr/bin/env bash
set +e

NODE="${1:-AUP}"
PREFERRED_FLIGHT_PORT="${2:-50000}"
FALLBACK_FLIGHT_PORT="${3:-50100}"
GDS_PORT="${4:-5000}"
SECURELANE="/home/xilinx/spaccomputing/SecureLane"
DICTIONARY="build-fprime-automatic-native/AupZu3/Top/AupZu3TopologyDictionary.json"
FLIGHT_BIN="./build-fprime-automatic-native/bin/Linux/AupZu3"

log() { printf '[%s] %s\n' "$NODE" "$*"; }

cd "$SECURELANE" || { log "ERROR: $SECURELANE not found"; exit 2; }
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source fprime-venv/bin/activate || { log "ERROR: fprime-venv activation failed"; exit 3; }

if [ ! -x "$FLIGHT_BIN" ]; then
    log "ERROR: flight binary not executable: $FLIGHT_BIN"
    exit 4
fi
if [ ! -f "$DICTIONARY" ]; then
    log "ERROR: F-Prime dictionary missing: $DICTIONARY"
    exit 5
fi

clean_stack() {
    log "Cleaning old F-Prime/GDS processes and ports"
    pkill -f "AupZu3" || true
    pkill -f "fprime-gds" || true
    pkill -f "fprime_gds" || true
    pkill -f "flask run" || true
    pkill -f "CustomDataHandlers" || true
    sudo fuser -k "${GDS_PORT}/tcp" 2>/dev/null || true
    sudo fuser -k "${PREFERRED_FLIGHT_PORT}/tcp" 2>/dev/null || true
    sudo fuser -k "${FALLBACK_FLIGHT_PORT}/tcp" 2>/dev/null || true
    sudo fuser -k 50050/tcp 2>/dev/null || true
    sleep 2
    log "Port state after cleanup:"
    ss -ltnp | grep -E "(:${GDS_PORT}|:${PREFERRED_FLIGHT_PORT}|:${FALLBACK_FLIGHT_PORT}|:50050)" || log "ports clean"
}

try_flight_port() {
    PORT="$1"
    LOGFILE="/tmp/mehen_flight_${PORT}.log"
    log "Trying AupZu3 flight app on 0.0.0.0:${PORT}"
    rm -f "$LOGFILE" /tmp/mehen_flight.log
    nohup "$FLIGHT_BIN" -a 0.0.0.0 -p "$PORT" > "$LOGFILE" 2>&1 &
    FLIGHT_PID=$!
    log "AupZu3 PID=$FLIGHT_PID PORT=$PORT"
    i=1
    while [ "$i" -le 18 ]; do
        if kill -0 "$FLIGHT_PID" 2>/dev/null && ss -ltnp | grep -q ":${PORT}"; then
            sleep 2
            if kill -0 "$FLIGHT_PID" 2>/dev/null && ss -ltnp | grep -q ":${PORT}"; then
                cp "$LOGFILE" /tmp/mehen_flight.log 2>/dev/null || true
                log "FLIGHT_PORT_SELECTED=${PORT}"
                log "Flight app stable on ${PORT}"
                ss -ltnp | grep -E "(:${PORT})" || true
                return 0
            fi
        fi
        if ! kill -0 "$FLIGHT_PID" 2>/dev/null; then
            log "AupZu3 exited before listening on ${PORT}"
            break
        fi
        sleep 1
        i=$((i+1))
    done
    log "Port ${PORT} did not become stable. Last 40 flight-log lines:"
    tail -40 "$LOGFILE" 2>/dev/null || true
    kill "$FLIGHT_PID" 2>/dev/null || true
    pkill -f "AupZu3" || true
    sudo fuser -k "${PORT}/tcp" 2>/dev/null || true
    sleep 2
    return 1
}

select_flight() {
    SELECTED_PORT=""
    if try_flight_port "$PREFERRED_FLIGHT_PORT"; then
        SELECTED_PORT="$PREFERRED_FLIGHT_PORT"
        return 0
    fi
    log "Preferred flight port $PREFERRED_FLIGHT_PORT failed. Trying $FALLBACK_FLIGHT_PORT."
    if try_flight_port "$FALLBACK_FLIGHT_PORT"; then
        SELECTED_PORT="$FALLBACK_FLIGHT_PORT"
        return 0
    fi
    log "ERROR: AupZu3 failed on both ports."
    return 1
}

start_gds() {
    log "Starting F-Prime GDS on remote :${GDS_PORT}, connected to AupZu3 :${SELECTED_PORT}"
    rm -rf /tmp/mehen_gds_logs
    mkdir -p /tmp/mehen_gds_logs
    rm -f /tmp/mehen_gds.log
    nohup fprime-gds -n \
        --dictionary "$DICTIONARY" \
        --communication-selection ip \
        --ip-client \
        --ip-address 127.0.0.1 \
        --ip-port "$SELECTED_PORT" \
        --gui-addr 0.0.0.0 \
        --gui-port "$GDS_PORT" \
        --log-to-stdout \
        --log-directly \
        -l /tmp/mehen_gds_logs > /tmp/mehen_gds.log 2>&1 &
    GDS_PID=$!
    log "GDS_PID=$GDS_PID GDS_PORT=$GDS_PORT FLIGHT_PORT=$SELECTED_PORT"
    i=1
    while [ "$i" -le 25 ]; do
        if kill -0 "$GDS_PID" 2>/dev/null && ss -ltnp | grep -q ":${GDS_PORT}"; then
            if curl -I --max-time 2 "http://127.0.0.1:${GDS_PORT}" >/tmp/mehen_gds_web_check.log 2>&1; then
                log "GDS_WEB=PASS port=${GDS_PORT}"
                ss -ltnp | grep -E "(:${GDS_PORT}|:${SELECTED_PORT})" || true
                return 0
            fi
        fi
        if ! kill -0 "$GDS_PID" 2>/dev/null; then
            log "GDS exited during startup. Last 80 GDS log lines:"
            tail -80 /tmp/mehen_gds.log 2>/dev/null || true
            return 1
        fi
        sleep 1
        i=$((i+1))
    done
    log "GDS web did not confirm. Last 100 GDS log lines:"
    tail -100 /tmp/mehen_gds.log 2>/dev/null || true
    return 1
}

clean_stack
RESTART_COUNT=0
while true; do
    RESTART_COUNT=$((RESTART_COUNT+1))
    log "WATCHDOG_CYCLE=$RESTART_COUNT"
    if ! select_flight; then
        log "WATCHDOG_FATAL=NO_FLIGHT"
        sleep 10
        clean_stack
        continue
    fi
    if ! start_gds; then
        log "WATCHDOG_RESTART=GDS_START_FAILED"
        clean_stack
        sleep 4
        continue
    fi
    HEART=0
    while true; do
        sleep 5
        HEART=$((HEART+1))
        FLIGHT_OK=0
        GDS_OK=0
        if kill -0 "$FLIGHT_PID" 2>/dev/null && ss -ltnp | grep -q ":${SELECTED_PORT}"; then FLIGHT_OK=1; fi
        if kill -0 "$GDS_PID" 2>/dev/null && ss -ltnp | grep -q ":${GDS_PORT}"; then GDS_OK=1; fi
        if [ "$FLIGHT_OK" != "1" ]; then
            log "WATCHDOG_RESTART=FLIGHT_LOST port=${SELECTED_PORT}"
            tail -60 "/tmp/mehen_flight_${SELECTED_PORT}.log" 2>/dev/null || true
            clean_stack
            sleep 4
            break
        fi
        if [ "$GDS_OK" != "1" ]; then
            log "WATCHDOG_RESTART=GDS_LOST port=${GDS_PORT}"
            tail -60 /tmp/mehen_gds.log 2>/dev/null || true
            clean_stack
            sleep 4
            break
        fi
        if [ $((HEART % 12)) -eq 0 ]; then
            log "HEARTBEAT flight_port=${SELECTED_PORT} gds_port=${GDS_PORT} status=OK"
        fi
    done
done
