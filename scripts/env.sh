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
IMAGE_CP="open5gs-cp:${OPEN5GS_VERSION}"
IMAGE_UPF="open5gs-upf:${OPEN5GS_VERSION}"

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
log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn() { echo "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
err()  { echo "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; }
hdr()  { echo "${BOLD}${CYAN}$1${NC}"; }

# ── Macvlan helpers ─────────────────────────────────────────

# Detect the host interface that can route to a given IP
detect_interface() {
    local target_ip="$1"
    ip -4 route get "$target_ip" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# Auto-detect the best physical interface for macvlan
# Skips: loopback, docker/veth/virbr/br- (virtual), /32 (cloud point-to-point)
# Prefers: interface with default route, real subnet (/16../24), state UP
detect_physical_interface() {
    local best="" best_score=0
    local iface ip_cidr prefix state has_default

    while IFS= read -r line; do
        # ip -br format: "enp1s0    UP    192.168.1.50/24"
        iface=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $3}')

        # Skip virtual/internal interfaces
        case "$iface" in
            lo|docker*|veth*|virbr*|br-*|dummy*|mac-*|flannel*|cni*|cali*) continue ;;
        esac

        # Must be UP with an IPv4 address
        [ "$state" != "UP" ] && continue
        [ -z "$ip_cidr" ] && continue

        # Extract prefix length
        prefix="${ip_cidr#*/}"
        [ -z "$prefix" ] && continue

        # Skip /32 (cloud point-to-point, not a real LAN)
        [ "$prefix" -eq 32 ] 2>/dev/null && continue

        # Score this interface
        local score=1

        # Prefer real LAN subnets (/16../24)
        [ "$prefix" -ge 16 ] && [ "$prefix" -le 24 ] && score=$((score + 2))

        # Prefer interface with default route
        if ip route show default dev "$iface" 2>/dev/null | grep -q .; then
            score=$((score + 3))
        fi

        # Prefer known physical naming (enp*, eth*, eno*, ens*)
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

# Validate that an interface is suitable for macvlan
validate_macvlan_interface() {
    local iface="$1"

    # Must exist
    if ! ip link show "$iface" >/dev/null 2>&1; then
        err "Interface '${iface}' does not exist"
        return 1
    fi

    # Must be UP
    local state
    state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
    if [[ "$state" != *UP* ]]; then
        err "Interface '${iface}' is not UP (state: ${state})"
        return 1
    fi

    # Must have an IPv4 address
    local cidr
    cidr=$(ip -4 addr show "$iface" | awk '/inet / {print $2; exit}')
    if [ -z "$cidr" ]; then
        err "Interface '${iface}' has no IPv4 address"
        return 1
    fi

    # Warn if /32 (macvlan needs a real subnet)
    local prefix="${cidr#*/}"
    if [ "$prefix" = "32" ]; then
        warn "Interface '${iface}' has a /32 address (${cidr}) — macvlan needs a real subnet"
        warn "Consider using a bridge interface instead"
        return 1
    fi

    # Warn about known virtual interfaces
    case "$iface" in
        virbr*|docker*|br-*)
            warn "Interface '${iface}' looks like a virtual bridge — macvlan may not work as expected"
            ;;
    esac

    # Test macvlan capability
    local test_name="macvlan-test-$$"
    if ip link add "$test_name" link "$iface" type macvlan mode bridge 2>/dev/null; then
        ip link del "$test_name" 2>/dev/null
        ok "Interface '${iface}' supports macvlan (${cidr})"
        return 0
    else
        err "Interface '${iface}' does not support macvlan — check promiscuous mode on hypervisor"
        return 1
    fi
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

# Create macvlan Docker network — shared per parent interface
# Multiple instances on the same LAN share one macvlan network
create_macvlan_network() {
    local parent="$2" subnet="$3" gateway="$4"
    local net_name="open5gs-${parent}"
    if docker network inspect "$net_name" >/dev/null 2>&1; then
        log "Network ${net_name} already exists (shared)"
        echo "$net_name"
        return 0
    fi
    docker network create -d macvlan \
        --subnet="$subnet" \
        --gateway="$gateway" \
        -o parent="$parent" \
        "$net_name"
    echo "$net_name"
}

# Get macvlan network name for a parent interface
get_macvlan_net_name() {
    local parent="$1"
    echo "open5gs-${parent}"
}

# Create host-side macvlan shim for host<->container communication
create_macvlan_shim() {
    local id="$1" parent="$2" amf_ip="$3" upf_ip="$4"
    local shim="mac-bts${id}"
    if ip link show "$shim" >/dev/null 2>&1; then
        log "Shim ${shim} already exists"
        return 0
    fi
    ip link add "$shim" link "$parent" type macvlan mode bridge
    ip link set "$shim" up
    ip route add "${amf_ip}/32" dev "$shim" 2>/dev/null || true
    ip route add "${upf_ip}/32" dev "$shim" 2>/dev/null || true
}

# Remove macvlan shim and routes
remove_macvlan_shim() {
    local id="$1" amf_ip="$2" upf_ip="$3"
    local shim="mac-bts${id}"
    ip route del "${amf_ip}/32" 2>/dev/null || true
    ip route del "${upf_ip}/32" 2>/dev/null || true
    ip link del "$shim" 2>/dev/null || true
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
