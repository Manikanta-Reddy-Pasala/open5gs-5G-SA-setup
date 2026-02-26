#!/bin/bash
# ============================================================
# start-upf.sh — Start open5GS UPF with TUN interface setup
# ============================================================

set -e

log() { echo "[$(date '+%H:%M:%S')] $1"; }

log "Setting up ogstun TUN interface..."

# Create TUN interface for UE traffic
ip tuntap add name ogstun mode tun || true
ip addr add 10.206.0.1/16 dev ogstun || true
ip link set ogstun up

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# NAT: UE traffic goes through ogstun, forward to internet
iptables -t nat -A POSTROUTING -s 10.206.0.0/16 ! -o ogstun -j MASQUERADE
iptables -I FORWARD 1 -j ACCEPT

log "TUN interface ogstun is up:"
ip addr show ogstun

log "Starting open5GS UPF..."
exec /open5gs/open5gs-upfd -c /etc/open5gs/upf.yaml
