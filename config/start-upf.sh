#!/bin/bash
# ============================================================
# start-upf.sh — Start open5GS UPF with TUN interface setup
# ============================================================
# Env vars (passed by docker-compose):
#   TUN_DEV  — TUN device name (e.g. ogstun1, ogstun2) — unique per instance
# ============================================================

set -e

log() { echo "[$(date '+%H:%M:%S')] $1"; }

TUN_DEV="${TUN_DEV:-ogstun}"

log "Setting up ${TUN_DEV} TUN interface..."

UE_SUBNET=$(awk '/subnet:/{print $3; exit}' /etc/open5gs/upf.yaml)
UE_GW=$(awk '/gateway:/{print $2; exit}' /etc/open5gs/upf.yaml)
UE_SUBNET="${UE_SUBNET:-10.45.0.0/16}"
UE_GW="${UE_GW:-10.45.0.1}"
UE_PREFIX="${UE_SUBNET#*/}"
log "  UE subnet: ${UE_SUBNET}  gateway: ${UE_GW}/${UE_PREFIX}  dev: ${TUN_DEV}"

if ip link show "$TUN_DEV" >/dev/null 2>&1; then
    log "  Removing stale ${TUN_DEV}..."
    ip link set "$TUN_DEV" down 2>/dev/null || true
    ip tuntap del name "$TUN_DEV" mode tun 2>/dev/null || true
fi

ip tuntap add name "$TUN_DEV" mode tun
ip addr add "${UE_GW}/${UE_PREFIX}" dev "$TUN_DEV"
ip link set "$TUN_DEV" up

sysctl -w net.ipv4.ip_forward=1

# NAT for this UE subnet (don't flush — other instances may have rules)
iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" ! -o "$TUN_DEV" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" ! -o "$TUN_DEV" -j MASQUERADE
iptables -C FORWARD -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -j ACCEPT

log "TUN interface ${TUN_DEV} is up:"
ip addr show "$TUN_DEV"

log "Starting open5GS UPF..."
exec /open5gs/open5gs-upfd -c /etc/open5gs/upf.yaml
