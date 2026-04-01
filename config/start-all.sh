#!/bin/bash
# ============================================================
# start-all.sh — Start complete 5G Core (10 CP NFs + UPF)
# ============================================================
# Env vars (passed by docker-compose):
#   DB_URI   — MongoDB connection string (e.g. mongodb://127.0.0.1/open5gs)
#   CP_IP    — Instance CP IP (NFs bind to this, e.g. 10.100.0.11)
#   UPF_IP   — UPF IP (GTP-U + PFCP bind to this)
#   TUN_DEV  — TUN device name (e.g. ogstun1) — unique per instance
# ============================================================

set -uo pipefail

LOGDIR=/var/log/open5gs
BINDIR=/open5gs
CFGDIR=/etc/open5gs

CP_IP="${CP_IP:-127.0.0.1}"
UPF_IP="${UPF_IP:-127.0.0.1}"
TUN_DEV="${TUN_DEV:-ogstun}"

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
    local mongo_host
    mongo_host=$(echo "${DB_URI:-mongodb://127.0.0.1/open5gs}" | sed 's|mongodb://||; s|/.*||; s|:.*||')
    mongo_host="${mongo_host:-127.0.0.1}"
    local mongo_port
    mongo_port=$(echo "${DB_URI:-}" | grep -oP ':\K[0-9]+(?=/)')
    mongo_port="${mongo_port:-27017}"

    log "Waiting for MongoDB (${mongo_host}:${mongo_port})..."
    wait_port "$mongo_host" "$mongo_port" 60
}

# ── 0. Setup TUN interface for UPF ──────────────────────────
log "Setting up TUN: ${TUN_DEV}..."

UE_SUBNET=$(awk '/subnet:/{print $3; exit}' "$CFGDIR/upf.yaml")
UE_GW=$(awk '/gateway:/{print $2; exit}' "$CFGDIR/upf.yaml")
UE_SUBNET="${UE_SUBNET:-10.45.0.0/16}"
UE_GW="${UE_GW:-10.45.0.1}"
UE_PREFIX="${UE_SUBNET#*/}"

if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    ip link set "$TUN_DEV" down 2>/dev/null || true
    ip tuntap del name "$TUN_DEV" mode tun 2>/dev/null || true
fi

ip tuntap add name "$TUN_DEV" mode tun
ip addr add "${UE_GW}/${UE_PREFIX}" dev "$TUN_DEV"
ip link set "$TUN_DEV" up
sysctl -qw net.ipv4.ip_forward=1

iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" ! -o "$TUN_DEV" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" ! -o "$TUN_DEV" -j MASQUERADE
iptables -C FORWARD -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -j ACCEPT

log "  ${TUN_DEV} UP — UE subnet: ${UE_SUBNET}, gw: ${UE_GW}"

# ── 1. Wait for MongoDB ─────────────────────────────────────
wait_mongo

# ── 2. NRF (must be first — service registry) ───────────────
log "Starting NRF (${CP_IP}:7777)..."
"$BINDIR/open5gs-nrfd" -c "$CFGDIR/nrf.yaml" >> "$LOGDIR/nrf.log" 2>&1 &
wait_port "$CP_IP" 7777

# ── 3. All other CP NFs in parallel ─────────────────────────
log "Starting SCP + UDR + UDM + AUSF + PCF + BSF + NSSF + SMF + AMF..."
"$BINDIR/open5gs-scpd"  -c "$CFGDIR/scp.yaml"  >> "$LOGDIR/scp.log"  2>&1 &
"$BINDIR/open5gs-udrd"  -c "$CFGDIR/udr.yaml"  >> "$LOGDIR/udr.log"  2>&1 &
"$BINDIR/open5gs-udmd"  -c "$CFGDIR/udm.yaml"  >> "$LOGDIR/udm.log"  2>&1 &
"$BINDIR/open5gs-ausfd" -c "$CFGDIR/ausf.yaml" >> "$LOGDIR/ausf.log" 2>&1 &
"$BINDIR/open5gs-pcfd"  -c "$CFGDIR/pcf.yaml"  >> "$LOGDIR/pcf.log"  2>&1 &
"$BINDIR/open5gs-bsfd"  -c "$CFGDIR/bsf.yaml"  >> "$LOGDIR/bsf.log" 2>&1 &
"$BINDIR/open5gs-nssfd" -c "$CFGDIR/nssf.yaml" >> "$LOGDIR/nssf.log" 2>&1 &
"$BINDIR/open5gs-smfd"  -c "$CFGDIR/smf.yaml"  >> "$LOGDIR/smf.log"  2>&1 &
"$BINDIR/open5gs-amfd"  -c "$CFGDIR/amf.yaml"  >> "$LOGDIR/amf.log"  2>&1 &

wait_port "$CP_IP" 7778   # SCP
wait_port "$CP_IP" 7786   # UDR
wait_port "$CP_IP" 7785   # UDM
wait_port "$CP_IP" 7784   # AUSF
wait_port "$CP_IP" 7782   # PCF
wait_port "$CP_IP" 7787   # BSF
wait_port "$CP_IP" 7783   # NSSF
wait_port "$CP_IP" 7781   # SMF
wait_port "$CP_IP" 7780   # AMF

# ── 4. UPF ──────────────────────────────────────────────────
log "Starting UPF (${UPF_IP})..."
"$BINDIR/open5gs-upfd" -c "$CFGDIR/upf.yaml" >> "$LOGDIR/upf.log" 2>&1 &

log ""
log "========================================="
log "  All 11 open5GS NFs started"
log "  CP:   ${CP_IP}"
log "  UPF:  ${UPF_IP}  TUN: ${TUN_DEV}"
log "  NRF:  7777  SCP: 7778"
log "  AMF:  7780  SMF: 7781"
log "  PCF:  7782  NSSF:7783"
log "  AUSF: 7784  UDM: 7785"
log "  UDR:  7786  BSF: 7787"
log "  NGAP: 38412 (SCTP)"
log "  GTP-U: 2152 (UDP)"
log "========================================="
log ""

# Keep container alive
wait -n 2>/dev/null || wait
log "One or more NFs exited. Container stopping."
