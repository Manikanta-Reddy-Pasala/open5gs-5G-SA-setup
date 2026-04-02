#!/bin/bash
# ============================================================
# env.sh — Shared environment variables and helpers
# ============================================================
# Source this from other scripts: source "$(dirname "$0")/env.sh"
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Build constants ─────────────────────────────────────────
OPEN5GS_VERSION="v2.7.5"
IMAGE="open5gs:${OPEN5GS_VERSION}"

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
DEFAULT_UE_SUBNET="10.45.0.0/16"
DEFAULT_UE_GW="10.45.0.1"
NGAP_PORT="38412"
GTPU_PORT="2152"

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
log()  { echo "[$(date '+%H:%M:%S')] $1" >&2; }
ok()   { echo "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}" >&2; }
warn() { echo "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}" >&2; }
err()  { echo "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}" >&2; }
hdr()  { echo "${BOLD}${CYAN}$1${NC}" >&2; }

# ── Network helpers ─────────────────────────────────────────

# Find the interface that has a specific IP assigned to it
find_interface_by_ip() {
    local target_ip="$1"
    ip -4 -o addr show 2>/dev/null \
        | awk -v ip="$target_ip" '{split($4,a,"/"); if(a[1]==ip) print $2}' \
        | head -1
}

# Detect the host interface that can route to a given IP
detect_interface() {
    local target_ip="$1"
    ip -4 route get "$target_ip" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# Auto-detect the best physical interface
# Skips: loopback, docker/veth/virbr/br- (virtual), /32 (cloud point-to-point)
# Prefers: interface with default route, real subnet (/16../24), state UP
detect_physical_interface() {
    local best="" best_score=0
    local iface ip_cidr prefix state

    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $3}')

        # Skip virtual/internal interfaces
        case "$iface" in
            lo|docker*|veth*|virbr*|br-*|dummy*|flannel*|cni*|cali*) continue ;;
        esac

        [ "$state" != "UP" ] && continue
        [ -z "$ip_cidr" ] && continue

        prefix="${ip_cidr#*/}"
        [ -z "$prefix" ] && continue
        [ "$prefix" -eq 32 ] 2>/dev/null && continue

        local score=1
        [ "$prefix" -ge 16 ] && [ "$prefix" -le 24 ] && score=$((score + 2))

        if ip route show default dev "$iface" 2>/dev/null | grep -q .; then
            score=$((score + 3))
        fi

        case "$iface" in
            enp*|eth*|eno*|ens*) score=$((score + 1)) ;;
        esac

        if [ "$score" -gt "$best_score" ]; then
            best="$iface"
            best_score="$score"
        fi
    done < <(ip -4 -br addr show 2>/dev/null)

    [ -n "$best" ] && echo "$best"
}

# Get subnet CIDR of an interface (e.g., "192.168.1.0/24")
get_interface_subnet() {
    local iface="$1"
    local cidr
    cidr=$(ip -4 addr show "$iface" | awk '/inet / {print $2; exit}')
    [ -z "$cidr" ] && return 1
    python3 -c "import ipaddress; print(ipaddress.ip_interface('${cidr}').network)"
}

# Get default gateway for an interface
get_interface_gateway() {
    local iface="$1"
    ip route | awk '/default.*'"$iface"'/ {print $3; exit}'
}

# Get host's IP on a specific interface
get_host_ip() {
    local iface="$1"
    ip -4 addr show "$iface" | awk '/inet / {split($2,a,"/"); print a[1]; exit}'
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
