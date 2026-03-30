#!/bin/bash
# ============================================================
# env.sh — Shared environment variables and helpers
# ============================================================
# Source this from other scripts: source "$(dirname "$0")/env.sh"
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Build constants ─────────────────────────────────────────
OPEN5GS_VERSION="v2.7.5"

# ── Default PLMN / subscriber ──────────────────────────────
DEFAULT_MCC="001"
DEFAULT_MNC="01"
DEFAULT_TAC="1"
DEFAULT_SST=3
DEFAULT_SD="198153"
DEFAULT_DNN="internet"
DEFAULT_IMSI="001010000050641"
DEFAULT_K="0c57e15a2cb86087097a6b50d42531de"
DEFAULT_OPC="109ee52735ae6d3849112cf4175029c7"
DEFAULT_AMF_FIELD="8000"

# ── Network defaults ────────────────────────────────────────
# Each BTS instance gets:
#   Docker bridge: 10.200.<ID>.0/24  (CP=.16, UPF=.17)
#   Host-facing:   10.0.0.<90+ID>    (BTS connects here, standard ports)
DEFAULT_BASE_SUBNET="10.200"
BTS_IP_BASE="10.0.0"
BTS_IP_OFFSET=90          # bts1=10.0.0.91, bts2=10.0.0.92, ...
BTS_IFACE="bts0"          # dummy interface for BTS IPs
NGAP_PORT="38412"
GTPU_PORT="2152"

# ── MongoDB (running on host) ──────────────────────────────
get_host_mongo_ip() {
    if [ -n "${MONGO_HOST:-}" ]; then
        echo "$MONGO_HOST"
        return
    fi
    # Docker containers reach host via the bridge gateway
    local gw
    gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]}')
    [ -z "$gw" ] && gw="172.17.0.1"
    echo "$gw"
}

# ── Colors ──────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Logging ─────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn() { echo "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
err()  { echo "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; }
hdr()  { echo "${BOLD}${CYAN}$1${NC}"; }

# ── Instance helpers ────────────────────────────────────────
instance_network() {
    local id="$1"
    echo "${DEFAULT_BASE_SUBNET}.${id}.0/24"
}

instance_cp_ip() {
    local id="$1"
    echo "${DEFAULT_BASE_SUBNET}.${id}.16"
}

instance_upf_ip() {
    local id="$1"
    echo "${DEFAULT_BASE_SUBNET}.${id}.17"
}

instance_gateway() {
    local id="$1"
    echo "${DEFAULT_BASE_SUBNET}.${id}.1"
}

# BTS-facing IP (what external gNB connects to)
instance_bts_ip() {
    local id="$1"
    echo "${BTS_IP_BASE}.$((BTS_IP_OFFSET + id))"
}

# Ensure the dummy interface for BTS IPs exists
ensure_bts_iface() {
    if ! ip link show "$BTS_IFACE" >/dev/null 2>&1; then
        ip link add "$BTS_IFACE" type dummy
        ip link set "$BTS_IFACE" up
    fi
}

# Wait for a TCP port to become available
wait_port() {
    local host="$1" port="$2" max="${3:-30}" tries=0
    local max_tries=$((max * 5))
    while ! (echo > /dev/tcp/${host}/${port}) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { warn "$host:$port not ready after ${max}s"; return 1; }
    done
    local ms=$((tries * 200))
    ok "$host:$port ready (${ms}ms)"
}
