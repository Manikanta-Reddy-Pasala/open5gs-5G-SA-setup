#!/bin/bash
# ============================================================
# start-cp-nfs.sh — Start all open5GS Control Plane NFs
# ============================================================
# NRF must start first (service registry). All other 9 NFs launch
# in parallel — they have built-in NRF retry logic.
# ============================================================

set -uo pipefail

LOGDIR=/var/log/open5gs
BINDIR=/open5gs
CFGDIR=/etc/open5gs

mkdir -p "$LOGDIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

wait_port() {
    local host="$1" port="$2" max="${3:-30}" tries=0
    local max_tries=$((max * 5))
    while ! (echo > /dev/tcp/${host}/${port}) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { log "WARNING: $host:$port not ready after ${max}s"; return 1; }
    done
    local ms=$((tries * 200))
    log "  $host:$port ready (${ms}ms)"
}

wait_mongo() {
    local max=60 tries=0
    local max_tries=$((max * 5))
    log "Waiting for MongoDB..."
    while ! (echo > /dev/tcp/db/27017) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { log "WARNING: MongoDB not ready after ${max}s"; break; }
    done
    local ms=$((tries * 200))
    log "  MongoDB ready (${ms}ms)"
}

# ── 0. Wait for MongoDB ──────────────────────────────────────
wait_mongo

# ── 1. NRF (must be first — service registry) ────────────────
log "Starting NRF (port 7777)..."
"$BINDIR/open5gs-nrfd" -c "$CFGDIR/nrf.yaml" >> "$LOGDIR/nrf.log" 2>&1 &
wait_port 127.0.0.1 7777

# ── 2. ALL other NFs in parallel (they retry NRF registration) ─
log "Starting SCP + UDR + UDM + AUSF + PCF + BSF + NSSF + SMF + AMF..."
"$BINDIR/open5gs-scpd"  -c "$CFGDIR/scp.yaml"  >> "$LOGDIR/scp.log"  2>&1 &
"$BINDIR/open5gs-udrd"  -c "$CFGDIR/udr.yaml"  >> "$LOGDIR/udr.log"  2>&1 &
"$BINDIR/open5gs-udmd"  -c "$CFGDIR/udm.yaml"  >> "$LOGDIR/udm.log"  2>&1 &
"$BINDIR/open5gs-ausfd" -c "$CFGDIR/ausf.yaml" >> "$LOGDIR/ausf.log" 2>&1 &
"$BINDIR/open5gs-pcfd"  -c "$CFGDIR/pcf.yaml"  >> "$LOGDIR/pcf.log"  2>&1 &
"$BINDIR/open5gs-bsfd"  -c "$CFGDIR/bsf.yaml"  >> "$LOGDIR/bsf.log"  2>&1 &
"$BINDIR/open5gs-nssfd" -c "$CFGDIR/nssf.yaml" >> "$LOGDIR/nssf.log" 2>&1 &
"$BINDIR/open5gs-smfd"  -c "$CFGDIR/smf.yaml"  >> "$LOGDIR/smf.log"  2>&1 &
"$BINDIR/open5gs-amfd"  -c "$CFGDIR/amf.yaml"  >> "$LOGDIR/amf.log"  2>&1 &

# Wait for all 9 to bind their ports
wait_port 127.0.0.1 7778   # SCP
wait_port 127.0.0.1 7786   # UDR
wait_port 127.0.0.1 7785   # UDM
wait_port 127.0.0.1 7784   # AUSF
wait_port 127.0.0.1 7782   # PCF
wait_port 127.0.0.1 7787   # BSF
wait_port 127.0.0.1 7783   # NSSF
wait_port 127.0.0.1 7781   # SMF
wait_port 127.0.0.1 7780   # AMF

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
