#!/bin/bash
# ============================================================
# start-cp-nfs.sh — Start all open5GS Control Plane NFs
# ============================================================
# Startup order: NRF → SCP → UDR → UDM → AUSF → PCF → BSF → NSSF → SMF → AMF
# ============================================================

set -uo pipefail

LOGDIR=/var/log/open5gs
BINDIR=/open5gs
CFGDIR=/etc/open5gs

mkdir -p "$LOGDIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

wait_port() {
    local host="$1" port="$2" max="${3:-30}" tries=0 max_tries=$((max * 5))
    while ! (echo > /dev/tcp/${host}/${port}) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { log "WARNING: $host:$port not ready after ${max}s"; return 1; }
    done
    local ms=$((tries * 200))
    log "  $host:$port ready (${ms}ms)"
}

wait_mongo() {
    local max=60 tries=0 max_tries=$((max * 5))
    log "Waiting for MongoDB..."
    # Use bash /dev/tcp for a real TCP ping — avoids wget hanging on non-HTTP sockets
    while ! (echo > /dev/tcp/db/27017) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { log "WARNING: MongoDB not ready after ${max}s"; break; }
    done
    local ms=$((tries * 200))
    log "  MongoDB ready (${ms}ms)"
}

# ── 0. Wait for MongoDB ──────────────────────────────────────
wait_mongo

# ── 1. NRF (Network Repository Function) ────────────────────
log "Starting NRF (port 7777)..."
"$BINDIR/open5gs-nrfd" -c "$CFGDIR/nrf.yaml" >> "$LOGDIR/nrf.log" 2>&1 &
NRF_PID=$!
wait_port 127.0.0.1 7777

# ── 2. SCP (Service Communication Proxy) ────────────────────
log "Starting SCP (port 7778)..."
"$BINDIR/open5gs-scpd" -c "$CFGDIR/scp.yaml" >> "$LOGDIR/scp.log" 2>&1 &
SCP_PID=$!
wait_port 127.0.0.1 7778

# ── 3–7. UDR, UDM, AUSF, PCF, BSF (independent — start in parallel)
log "Starting UDR(7786) UDM(7785) AUSF(7784) PCF(7782) BSF(7787)..."
"$BINDIR/open5gs-udrd"  -c "$CFGDIR/udr.yaml"  >> "$LOGDIR/udr.log"  2>&1 &
"$BINDIR/open5gs-udmd"  -c "$CFGDIR/udm.yaml"  >> "$LOGDIR/udm.log"  2>&1 &
"$BINDIR/open5gs-ausfd" -c "$CFGDIR/ausf.yaml" >> "$LOGDIR/ausf.log" 2>&1 &
"$BINDIR/open5gs-pcfd"  -c "$CFGDIR/pcf.yaml"  >> "$LOGDIR/pcf.log"  2>&1 &
"$BINDIR/open5gs-bsfd"  -c "$CFGDIR/bsf.yaml"  >> "$LOGDIR/bsf.log"  2>&1 &
# Wait for all five to be listening
wait_port 127.0.0.1 7786
wait_port 127.0.0.1 7785
wait_port 127.0.0.1 7784
wait_port 127.0.0.1 7782
wait_port 127.0.0.1 7787

# ── 8. NSSF (Network Slice Selection Function) ───────────────
log "Starting NSSF (port 7783)..."
"$BINDIR/open5gs-nssfd" -c "$CFGDIR/nssf.yaml" >> "$LOGDIR/nssf.log" 2>&1 &
NSSF_PID=$!
wait_port 127.0.0.1 7783

# ── 9. SMF (Session Management Function) ─────────────────────
log "Starting SMF (port 7781)..."
"$BINDIR/open5gs-smfd" -c "$CFGDIR/smf.yaml" >> "$LOGDIR/smf.log" 2>&1 &
SMF_PID=$!
wait_port 127.0.0.1 7781

# ── 10. AMF (Access and Mobility Management Function) ─────────
log "Starting AMF (port 7780, NGAP 38412)..."
"$BINDIR/open5gs-amfd" -c "$CFGDIR/amf.yaml" >> "$LOGDIR/amf.log" 2>&1 &
AMF_PID=$!
wait_port 127.0.0.1 7780

log ""
log "========================================="
log "  All open5GS CP NFs started"
log "  NRF:  7777  SCP: 7778"
log "  AMF:  7780  SMF: 7781"
log "  PCF:  7782  NSSF:7783"
log "  AUSF: 7784  UDM: 7785"
log "  UDR:  7786  BSF: 7787"
log "  NGAP: 38412 (SCTP)"
log "========================================="
log ""

# Keep container alive — wait for any process to exit
wait -n 2>/dev/null || wait
log "One or more NFs exited. Container stopping."
