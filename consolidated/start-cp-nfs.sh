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
    local host="$1" port="$2" max="${3:-30}" waited=0
    while ! wget -q --spider "http://${host}:${port}" 2>/dev/null && ! nc -z "$host" "$port" 2>/dev/null; do
        sleep 1; waited=$((waited+1))
        [ $waited -ge $max ] && { log "WARNING: $host:$port not ready after ${max}s"; return 1; }
    done
    log "  $host:$port ready (${waited}s)"
}

wait_mongo() {
    local max=60 waited=0
    log "Waiting for MongoDB..."
    # Use bash /dev/tcp for a real TCP ping — avoids wget hanging on non-HTTP sockets
    while ! (echo > /dev/tcp/db/27017) 2>/dev/null; do
        sleep 2; waited=$((waited+2))
        [ $waited -ge $max ] && { log "WARNING: MongoDB not ready after ${max}s"; break; }
    done
    log "  MongoDB ready (${waited}s)"
    sleep 1
}

# ── 0. Wait for MongoDB ──────────────────────────────────────
wait_mongo

# ── 1. NRF (Network Repository Function) ────────────────────
log "Starting NRF (port 7777)..."
"$BINDIR/open5gs-nrfd" -c "$CFGDIR/nrf.yaml" >> "$LOGDIR/nrf.log" 2>&1 &
NRF_PID=$!
sleep 3

# ── 2. SCP (Service Communication Proxy) ────────────────────
log "Starting SCP (port 7778)..."
"$BINDIR/open5gs-scpd" -c "$CFGDIR/scp.yaml" >> "$LOGDIR/scp.log" 2>&1 &
SCP_PID=$!
sleep 2

# ── 3. UDR (Unified Data Repository) ────────────────────────
log "Starting UDR (port 7786)..."
"$BINDIR/open5gs-udrd" -c "$CFGDIR/udr.yaml" >> "$LOGDIR/udr.log" 2>&1 &
UDR_PID=$!
sleep 1

# ── 4. UDM (Unified Data Management) ────────────────────────
log "Starting UDM (port 7785)..."
"$BINDIR/open5gs-udmd" -c "$CFGDIR/udm.yaml" >> "$LOGDIR/udm.log" 2>&1 &
UDM_PID=$!
sleep 1

# ── 5. AUSF (Authentication Server Function) ────────────────
log "Starting AUSF (port 7784)..."
"$BINDIR/open5gs-ausfd" -c "$CFGDIR/ausf.yaml" >> "$LOGDIR/ausf.log" 2>&1 &
AUSF_PID=$!
sleep 1

# ── 6. PCF (Policy Control Function) ────────────────────────
log "Starting PCF (port 7782)..."
"$BINDIR/open5gs-pcfd" -c "$CFGDIR/pcf.yaml" >> "$LOGDIR/pcf.log" 2>&1 &
PCF_PID=$!
sleep 1

# ── 7. BSF (Binding Support Function) ────────────────────────
log "Starting BSF (port 7787)..."
"$BINDIR/open5gs-bsfd" -c "$CFGDIR/bsf.yaml" >> "$LOGDIR/bsf.log" 2>&1 &
BSF_PID=$!
sleep 1

# ── 8. NSSF (Network Slice Selection Function) ───────────────
log "Starting NSSF (port 7783)..."
"$BINDIR/open5gs-nssfd" -c "$CFGDIR/nssf.yaml" >> "$LOGDIR/nssf.log" 2>&1 &
NSSF_PID=$!
sleep 1

# ── 9. SMF (Session Management Function) ─────────────────────
log "Starting SMF (port 7781)..."
"$BINDIR/open5gs-smfd" -c "$CFGDIR/smf.yaml" >> "$LOGDIR/smf.log" 2>&1 &
SMF_PID=$!
sleep 2

# ── 10. AMF (Access and Mobility Management Function) ─────────
log "Starting AMF (port 7780, NGAP 38412)..."
"$BINDIR/open5gs-amfd" -c "$CFGDIR/amf.yaml" >> "$LOGDIR/amf.log" 2>&1 &
AMF_PID=$!
sleep 2

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
