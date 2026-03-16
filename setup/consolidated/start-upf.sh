#!/bin/bash
# ============================================================
# start-upf.sh — Start open5GS UPF with TUN interface setup
# ============================================================

set -e

log() { echo "[$(date '+%H:%M:%S')] $1"; }

log "Setting up ogstun TUN interface..."

# Read UE subnet/gateway from config (YAML: "    - subnet: 10.206.0.0/16" and "      gateway: 10.206.0.1")
UE_SUBNET=$(awk '/subnet:/{print $3; exit}' /etc/open5gs/upf.yaml)
UE_GW=$(awk '/gateway:/{print $2; exit}' /etc/open5gs/upf.yaml)
UE_SUBNET="${UE_SUBNET:-10.206.0.0/16}"
UE_GW="${UE_GW:-10.206.0.1}"
UE_PREFIX="${UE_SUBNET#*/}"   # e.g. "16" from "10.206.0.0/16"
log "  UE subnet: ${UE_SUBNET}  gateway: ${UE_GW}/${UE_PREFIX}"

# Tear down any stale ogstun (survives container restarts in shared netns)
if ip link show ogstun >/dev/null 2>&1; then
    log "  Removing stale ogstun..."
    ip link set ogstun down 2>/dev/null || true
    ip tuntap del name ogstun mode tun 2>/dev/null || true
fi

# Create fresh TUN interface
ip tuntap add name ogstun mode tun
ip addr add "${UE_GW}/${UE_PREFIX}" dev ogstun
ip link set ogstun up

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# NAT: UE traffic goes out via ogstun, masquerade for internet access
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" ! -o ogstun -j MASQUERADE
iptables -I FORWARD 1 -j ACCEPT

log "TUN interface ogstun is up:"
ip addr show ogstun

log "Starting open5GS UPF..."
exec /open5gs/open5gs-upfd -c /etc/open5gs/upf.yaml
