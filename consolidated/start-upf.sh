#!/bin/bash
# ============================================================
# start-upf.sh — Start open5GS UPF with TUN interface setup
# ============================================================

set -e

log() { echo "[$(date '+%H:%M:%S')] $1"; }

log "Setting up ogstun TUN interface..."

UE_SUBNET=$(awk '/subnet:/{print $3; exit}' /etc/open5gs/upf.yaml)
UE_GW=$(awk '/gateway:/{print $2; exit}' /etc/open5gs/upf.yaml)
UE_SUBNET="${UE_SUBNET:-10.206.0.0/16}"
UE_GW="${UE_GW:-10.206.0.1}"
UE_PREFIX="${UE_SUBNET#*/}"
log "  UE subnet: ${UE_SUBNET}  gateway: ${UE_GW}/${UE_PREFIX}"

if ip link show ogstun >/dev/null 2>&1; then
    log "  Removing stale ogstun..."
    ip link set ogstun down 2>/dev/null || true
    ip tuntap del name ogstun mode tun 2>/dev/null || true
fi

ip tuntap add name ogstun mode tun
ip addr add "${UE_GW}/${UE_PREFIX}" dev ogstun
ip link set ogstun up

sysctl -w net.ipv4.ip_forward=1

iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" ! -o ogstun -j MASQUERADE
iptables -I FORWARD 1 -j ACCEPT

log "TUN interface ogstun is up:"
ip addr show ogstun

log "Starting open5GS UPF..."
exec /open5gs/open5gs-upfd -c /etc/open5gs/upf.yaml
