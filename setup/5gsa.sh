#!/bin/bash
# ============================================================
# 5gsa.sh - Build & Run for open5GS 5G SA Core
# ============================================================
# Single script to build and run a portable 5G SA core.
#
# Usage:
#   ./5gsa.sh build                # Compile from source (~20 min)
#   ./5gsa.sh build --quick        # Rebuild runtime images only
#   ./5gsa.sh start                # Start core (without UERANSIM)
#   ./5gsa.sh start --ueransim     # Start core + UERANSIM simulator
#   ./5gsa.sh start --debug        # Start with debug-level logging
#   ./5gsa.sh start --mcc 404 --mnc 30 --tac 1  # Custom single PLMN
#   ./5gsa.sh start --plmn 404:30 --plmn 404:20 --tac 1  # Multi-PLMN
#   ./5gsa.sh start --sst 1 --sd 111111          # Custom slice
#   ./5gsa.sh provision            # Provision default subscriber
#   ./5gsa.sh bulk-provision --count 10  # Provision 10 subscribers
#   ./5gsa.sh ue start             # Launch UE (inside UERANSIM container)
#   ./5gsa.sh ue stop              # Stop UE
#   ./5gsa.sh ue status            # Check UE connectivity
#   ./5gsa.sh stop                 # Stop all containers
#   ./5gsa.sh remove               # Remove all containers and volumes
#   ./5gsa.sh status               # Show container status
#   ./5gsa.sh logs [nf]            # Tail logs
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Constants ────────────────────────────────────────────────
COMPOSE_FILE="docker-compose.yaml"
OPEN5GS_VERSION="v2.7.5"
AMF_IP="10.200.100.16"
NGAP_PORT="38412"
GTPU_PORT="2152"

# Subscriber / PLMN defaults
IMSI="imsi-001010000050641"
MCC="001"
MNC="01"
TAC="1"
K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
AMF_FIELD="8000"
SST=3
SD="198153"
DNN="internet"
UE_SUBNET="10.206.0.0/16"
WEBUI_PORT=4000

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"; }
warn() { echo "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
err()  { echo "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; }
hdr()  { echo "${BOLD}${CYAN}$1${NC}"; }

# ── Helpers ──────────────────────────────────────────────────

wait_cp_ready() {
    # Direct TCP check to NRF on the CP's fixed IP — bypasses Docker's
    # slow healthcheck scheduler (~5s overhead) since NFs start in <1s.
    local max="${1:-60}" tries=0
    local max_tries=$((max * 5))
    while ! (echo > /dev/tcp/${AMF_IP}/7777) 2>/dev/null; do
        sleep 0.2; tries=$((tries+1))
        [ $tries -ge $max_tries ] && { warn "CP not ready after ${max}s"; return 1; }
    done
    local ms=$((tries * 200))
    ok "Control Plane ready (${ms}ms)"
}

setup_sctp_forward() {
    cleanup_sctp_forward 2>/dev/null
    modprobe sctp 2>/dev/null || true
    iptables -t nat -A PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"
    iptables -t nat -A OUTPUT    -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"
    iptables -A FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT
    iptables -A FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT
    log "  SCTP DNAT rules added (host:${NGAP_PORT} -> ${AMF_IP}:${NGAP_PORT})"
}

cleanup_sctp_forward() {
    iptables -t nat -D PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -t nat -D OUTPUT    -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -D FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
}

setup_dataplane() {
    log "Setting up data plane routing..."
    local UPF_IP
    UPF_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' open5gs-upf 2>/dev/null | head -1)
    if [ -z "$UPF_IP" ]; then
        warn "Could not detect UPF IP, skipping route setup"
        return 0
    fi
    ip route add "${UE_SUBNET}" via "$UPF_IP" 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || true
    log "  NAT: MASQUERADE for ${UE_SUBNET}"

    # FORWARD: allow UE traffic through the host
    iptables -I FORWARD 1 -s "${UE_SUBNET}" -j ACCEPT
    iptables -I FORWARD 1 -d "${UE_SUBNET}" -j ACCEPT
    log "  FORWARD: ACCEPT for ${UE_SUBNET}"

    # GTP-U: DNAT host:2152 -> UPF container (for real gNB traffic)
    iptables -t nat -A PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
    iptables -t nat -A OUTPUT     -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
    iptables -I FORWARD 1 -p udp -d "$UPF_IP" --dport "$GTPU_PORT" -j ACCEPT
    iptables -I FORWARD 1 -p udp -s "$UPF_IP" --sport "$GTPU_PORT" -j ACCEPT
    log "  GTP-U: DNAT host:${GTPU_PORT} -> ${UPF_IP}:${GTPU_PORT}"
    ok "Route ${UE_SUBNET} -> ${UPF_IP} added"
}

cleanup_dataplane() {
    local UPF_IP
    UPF_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' open5gs-upf 2>/dev/null | head -1)
    [ -n "$UPF_IP" ] && ip route del "${UE_SUBNET}" via "$UPF_IP" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "${UE_SUBNET}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "${UE_SUBNET}" -j ACCEPT 2>/dev/null || true
    if [ -n "$UPF_IP" ]; then
        iptables -t nat -D PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}" 2>/dev/null || true
        iptables -t nat -D OUTPUT     -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}" 2>/dev/null || true
        iptables -D FORWARD -p udp -d "$UPF_IP" --dport "$GTPU_PORT" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p udp -s "$UPF_IP" --sport "$GTPU_PORT" -j ACCEPT 2>/dev/null || true
    fi
}

update_plmn_config() {
    local mcc="$1" mnc="$2" tac="$3"
    local cfg_dir="${4:-config}"

    log "Updating PLMN: MCC=${mcc} MNC=${mnc} TAC=${tac} in ${cfg_dir}/"

    sed -i "s/mcc: [0-9]*/mcc: ${mcc}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/mnc: [0-9]*/mnc: ${mnc}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/tac: [0-9]*/tac: ${tac}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/mcc: '[0-9]*'/mcc: '${mcc}'/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/mnc: '[0-9]*'/mnc: '${mnc}'/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/tac: [0-9]*/tac: ${tac}/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/mcc: '[0-9]*'/mcc: '${mcc}'/g" "${cfg_dir}/ue.yaml"
    sed -i "s/mnc: '[0-9]*'/mnc: '${mnc}'/g" "${cfg_dir}/ue.yaml"

    MCC="$mcc"; MNC="$mnc"; TAC="$tac"
    log "  PLMN updated in config files"
}

update_plmn_config_multi() {
    # Args: tac cfg_dir MCC1:MNC1 [MCC2:MNC2 ...]
    local tac="$1"
    local cfg_dir="$2"
    shift 2
    local plmns=("$@")

    log "Updating multi-PLMN config: TAC=${tac} PLMNs: ${plmns[*]} in ${cfg_dir}/"

    # Update AMF config (guami / tai / plmn_support) using Python for safe YAML rewrite
    python3 - "${cfg_dir}/amf.yaml" "$tac" "${plmns[@]}" <<'PYEOF'
import sys, re

cfg_file = sys.argv[1]
tac      = sys.argv[2]
plmns    = []
for arg in sys.argv[3:]:
    parts = arg.split(':')
    mcc, mnc = parts[0].strip(), parts[1].strip()
    plmns.append((mcc, mnc))

with open(cfg_file) as f:
    content = f.read()

# Extract existing sst/sd values to preserve slice config
sst_m = re.search(r'(?m)^\s+- sst:\s*(\d+)', content)
sd_m  = re.search(r'(?m)^\s+sd:\s*([0-9a-fA-F]+)', content)
sst = sst_m.group(1) if sst_m else '3'
sd  = sd_m.group(1)  if sd_m  else '198153'

def build_guami(plmns):
    lines = ['  guami:']
    for mcc, mnc in plmns:
        lines += [
            '    - plmn_id:',
            f'        mcc: {mcc}',
            f'        mnc: {mnc}',
            '      amf_id:',
            '        region: 2',
            '        set: 1',
        ]
    return '\n'.join(lines)

def build_tai(plmns, tac):
    lines = ['  tai:']
    for mcc, mnc in plmns:
        lines += [
            '    - plmn_id:',
            f'        mcc: {mcc}',
            f'        mnc: {mnc}',
            f'      tac: {tac}',
        ]
    return '\n'.join(lines)

def build_plmn_support(plmns, sst, sd):
    lines = ['  plmn_support:']
    for mcc, mnc in plmns:
        lines += [
            '    - plmn_id:',
            f'        mcc: {mcc}',
            f'        mnc: {mnc}',
            '      s_nssai:',
            f'        - sst: {sst}',
            f'          sd: {sd}',
        ]
    return '\n'.join(lines)

def replace_section(content, key, new_block):
    # Match "  key:" and everything until the next 2-space-indented key or end-of-file
    pattern = rf'  {key}:.*?(?=\n  [a-z_]|\Z)'
    return re.sub(pattern, new_block, content, flags=re.DOTALL)

content = replace_section(content, 'guami',        build_guami(plmns))
content = replace_section(content, 'tai',          build_tai(plmns, tac))
content = replace_section(content, 'plmn_support', build_plmn_support(plmns, sst, sd))

with open(cfg_file, 'w') as f:
    f.write(content)

print(f"  Updated {cfg_file}: {len(plmns)} PLMN(s), TAC={tac}")
PYEOF

    # Update gNB + UE config with the FIRST PLMN's MCC/MNC (single gNB)
    local first_mcc="${plmns[0]%%:*}"
    local first_mnc="${plmns[0]##*:}"
    sed -i "s/mcc: '[0-9]*/mcc: '${first_mcc}/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/mnc: '[0-9]*/mnc: '${first_mnc}/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/tac: [0-9]*/tac: ${tac}/g"           "${cfg_dir}/gnb.yaml"
    sed -i "s/mcc: '[0-9]*/mcc: '${first_mcc}/g" "${cfg_dir}/ue.yaml"
    sed -i "s/mnc: '[0-9]*/mnc: '${first_mnc}/g" "${cfg_dir}/ue.yaml"

    MCC="$first_mcc"; MNC="$first_mnc"; TAC="$tac"
    log "  Multi-PLMN update complete"
}

update_slice_config() {
    local sst="$1" sd="$2"
    local cfg_dir="${3:-config}"

    log "Updating slice: SST=${sst} SD=${sd} in ${cfg_dir}/"

    # AMF: sst (int) + sd (decimal, no prefix)
    sed -i "s/sst: [0-9]*/sst: ${sst}/g"   "${cfg_dir}/amf.yaml"
    sed -i "s/sd: [0-9a-fA-F]*/sd: ${sd}/g" "${cfg_dir}/amf.yaml"

    # SMF info + NSSF nsi: sst and sd (decimal, no prefix)
    sed -i "s/sst: [0-9]*/sst: ${sst}/g" "${cfg_dir}/smf.yaml"
    sed -i "s/sd: [0-9a-fA-F]*/sd: ${sd}/g" "${cfg_dir}/smf.yaml"
    sed -i "s/sst: [0-9]*/sst: ${sst}/g" "${cfg_dir}/nssf.yaml"
    sed -i "s/sd: [0-9a-fA-F]*/sd: ${sd}/g" "${cfg_dir}/nssf.yaml"

    # gNB + UE: sst (int) + sd (0x hex prefix)
    sed -i "s/sst: [0-9]*/sst: ${sst}/g"         "${cfg_dir}/gnb.yaml"
    sed -i "s/sd: 0x[0-9a-fA-F]*/sd: 0x${sd}/g"  "${cfg_dir}/gnb.yaml"
    sed -i "s/sst: [0-9]*/sst: ${sst}/g"         "${cfg_dir}/ue.yaml"
    sed -i "s/sd: 0x[0-9a-fA-F]*/sd: 0x${sd}/g"  "${cfg_dir}/ue.yaml"

    SST="$sst"; SD="$sd"
    log "  Slice updated in config files"
}

# ── Commands ─────────────────────────────────────────────────

cmd_build() {
    local quick=false
    [ "${1:-}" = "--quick" ] && quick=true

    if [ "$quick" = false ]; then
        hdr ""
        hdr "  Building open5GS + UERANSIM from source"
        hdr "  This compiles C + C++ code inside Docker (~20 minutes first run)"
        hdr ""

        log "Step 1/3: Building all open5GS + UERANSIM from source..."
        docker build -f Dockerfile.build-all -t "open5gs-builder:${OPEN5GS_VERSION}" .

        log "Source build complete."
        log "Step 2/3: Extracting built binaries to build-output/..."
        rm -rf build-output
        mkdir -p build-output

        docker run --rm -v "$(pwd)/build-output:/export" "open5gs-builder:${OPEN5GS_VERSION}"

        if [ ! -f "build-output/open5gs/bin/open5gs-amfd" ]; then
            err "Binary extraction failed. build-output/open5gs/bin/open5gs-amfd not found."
            exit 1
        fi

        log "Binaries extracted:"
        log "  open5GS: $(ls build-output/open5gs/bin/ | tr '\n' ' ')"
        log "  UERANSIM: $(ls build-output/ueransim/ | tr '\n' ' ')"

        [ -f "build-output/BUILD_MANIFEST.txt" ] && cat build-output/BUILD_MANIFEST.txt
    else
        log "Step 1/3: Skipping source build (--quick mode)"
        log "Step 2/3: Using existing build-output/"
        if [ ! -d "build-output/open5gs" ]; then
            err "build-output/open5gs/ not found. Run './5gsa.sh build' first."
            exit 1
        fi
    fi

    log "Step 3/3: Building runtime Docker images..."
    mkdir -p logs/cp logs/upf

    docker compose -f "$COMPOSE_FILE" build

    hdr ""
    hdr "  BUILD COMPLETE"
    hdr ""
    log "Runtime images:"
    docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "open5gs-(cp|upf|webui|ueransim)" || true
    hdr ""
    log "Next: ./5gsa.sh start"
    hdr ""
}

cmd_start() {
    local with_ueransim=false
    local debug_mode=false
    local custom_mcc="" custom_mnc="" custom_tac=""
    local custom_sst="" custom_sd=""
    local custom_plmns=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ueransim) with_ueransim=true ;;
            --debug)    debug_mode=true ;;
            --mcc)      custom_mcc="$2";               shift ;;
            --mnc)      custom_mnc="$2";               shift ;;
            --tac)      custom_tac="$2";               shift ;;
            --sst)      custom_sst="$2";               shift ;;
            --sd)       custom_sd="$2";                shift ;;
            --plmn)     custom_plmns+=("$2");          shift ;;
        esac
        shift
    done

    local cfg_dir="config"
    if [ "$debug_mode" = true ]; then
        cfg_dir="config-debug"
        log "Using DEBUG logging (config-debug/)"
    fi

    if [ "${#custom_plmns[@]}" -gt 0 ]; then
        # Multi-PLMN mode: --plmn MCC:MNC [--plmn MCC2:MNC2 ...] [--tac TAC]
        update_plmn_config_multi \
            "${custom_tac:-$TAC}" \
            "$cfg_dir" \
            "${custom_plmns[@]}"
    elif [ -n "$custom_mcc" ] || [ -n "$custom_mnc" ] || [ -n "$custom_tac" ]; then
        # Single PLMN mode: --mcc X --mnc Y --tac Z
        update_plmn_config \
            "${custom_mcc:-$MCC}" \
            "${custom_mnc:-$MNC}" \
            "${custom_tac:-$TAC}" \
            "$cfg_dir"
    fi

    if [ -n "$custom_sst" ] || [ -n "$custom_sd" ]; then
        update_slice_config \
            "${custom_sst:-$SST}" \
            "${custom_sd:-$SD}" \
            "$cfg_dir"
    fi

    mkdir -p logs/cp logs/upf

    hdr ""
    hdr "  Starting open5GS 5G SA Core"
    hdr ""

    # Ensure MongoDB is running (no-op if already up)
    CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d open5gs-mongodb

    # Restart CP: use "docker restart" (in-place, ~1s) if container exists,
    # otherwise create it.  Configs are bind-mounted so restart picks up
    # any PLMN / slice changes immediately — no need to destroy + recreate.
    if docker inspect open5gs-cp >/dev/null 2>&1; then
        log "Restarting Control Plane (in-place)..."
        docker restart -t 1 open5gs-cp
    else
        log "Creating Control Plane..."
        CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d open5gs-cp
    fi

    log "Waiting for Control Plane..."
    wait_cp_ready 60

    log "Starting UPF (fresh start to ensure clean PFCP association with SMF)..."
    # Always force-recreate UPF so it starts with no stale PFCP state.
    # SMF (in the CP) initiates PFCP; if UPF holds an old association from a
    # previous SMF run it will reject SMF's new Association Setup Request,
    # blocking all PDU session establishment.
    CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d --force-recreate open5gs-upf

    log "Starting WebUI (port ${WEBUI_PORT})..."
    CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d open5gs-webui

    if [ "$with_ueransim" = true ]; then
        log "Starting UERANSIM gNB..."
        CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" --profile ueransim up -d ueransim
    fi

    setup_sctp_forward
    setup_dataplane

    hdr ""
    hdr "  ========================================="
    hdr "  open5GS 5G SA Core is running!"
    hdr "  ========================================="
    hdr ""
    log "  WebUI:     http://$(hostname -I | awk '{print $1}'):${WEBUI_PORT}"
    log "             Login: admin / 1423"
    log "  NGAP/SCTP: $(hostname -I | awk '{print $1}'):${NGAP_PORT}"
    log "  PLMN:      MCC=${MCC} MNC=${MNC} TAC=${TAC}"
    log "  Slice:     SST=${SST} SD=${SD}"
    log "  DNN:       ${DNN}"
    hdr ""
    log "  NRF API:   http://10.200.100.16:7777"
    hdr ""
    log "Run './5gsa.sh provision' to add a test subscriber."
    log "Run './5gsa.sh status' to verify all NFs are running."
    hdr ""
}

cmd_stop() {
    hdr "Stopping open5GS..."
    # Stop NF containers only — keep MongoDB, networking, and containers intact
    # so the next "start" is instant.  Use "remove" for full teardown.
    docker compose -f "$COMPOSE_FILE" --profile ueransim stop open5gs-cp open5gs-upf open5gs-webui ueransim 2>/dev/null || true
    ok "Stopped.  (MongoDB + networking intact — use 'remove' for full teardown)"
}

cmd_remove() {
    hdr "Removing all open5GS containers and volumes..."
    cleanup_sctp_forward 2>/dev/null || true
    cleanup_dataplane 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" --profile ueransim down -v --remove-orphans
    ok "Removed."
}

cmd_status() {
    hdr ""
    hdr "  ========================================="
    hdr "  open5GS Status"
    hdr "  ========================================="
    hdr ""

    echo "${BOLD}Containers:${NC}"
    local all_ok=true
    for cname in open5gs-mongodb open5gs-cp open5gs-upf open5gs-webui; do
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
        local health=""
        health=$(docker inspect --format='{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$cname" 2>/dev/null || true)
        if [ "$state" = "running" ]; then
            printf "  ${GREEN}✓${NC} %-25s %s%s\n" "$cname" "$state" "$health"
        else
            printf "  ${RED}✗${NC} %-25s %s\n" "$cname" "$state"
            all_ok=false
        fi
    done

    # Check UERANSIM (optional)
    if docker inspect "open5gs-ueransim" >/dev/null 2>&1; then
        local ur_state
        ur_state=$(docker inspect --format='{{.State.Status}}' "open5gs-ueransim" 2>/dev/null)
        if [ "$ur_state" = "running" ]; then
            printf "  ${GREEN}✓${NC} %-25s running (optional)\n" "open5gs-ueransim"
        else
            printf "  ${CYAN}○${NC} %-25s %s (optional)\n" "open5gs-ueransim" "$ur_state"
        fi
    else
        printf "  ${CYAN}○${NC} %-25s not running (optional)\n" "open5gs-ueransim"
    fi

    echo ""
    echo "${BOLD}NRF Registrations:${NC}"
    local nrf_output
    # open5GS NRF speaks HTTP/2 only; wget (HTTP/1.1) fails with bad magic bytes.
    # Query from host using curl --http2-prior-knowledge via the container's fixed IP.
    nrf_output=$(curl -s --max-time 5 --http2-prior-knowledge \
        http://10.200.100.16:7777/nnrf-nfm/v1/nf-instances 2>/dev/null || echo "")
    if [ -n "$nrf_output" ]; then
        # Parse NF types from JSON
        local nf_list
        nf_list=$(echo "$nrf_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    links = data.get('_links', {})
    # open5GS uses 'items' (plural); fall back to 'item' for compatibility
    items = links.get('items', links.get('item', []))
    total = data.get('totalItemCount', len(items))
    print(f'  Registered NFs: {total}')
except:
    print('  NRF API responded')
" 2>/dev/null || echo "  NRF API responded (parse error)")
        echo "$nf_list"
        ok "NRF is reachable"
    else
        warn "NRF API not reachable (CP may still be starting)"
    fi

    echo ""
    echo "${BOLD}Network:${NC}"
    # ── SCTP DNAT (external gNB only) ────────────────────────────
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${NGAP_PORT}"; then
        ok "SCTP DNAT  :${NGAP_PORT}  active  -> ${AMF_IP}:${NGAP_PORT}"
    else
        log "  ℹ SCTP DNAT  :${NGAP_PORT}  not set  (only needed for external gNB)"
    fi

    # ── UE subnet FORWARD (external gNB only) ────────────────────
    if iptables -C FORWARD -s "${UE_SUBNET}" -j ACCEPT >/dev/null 2>&1 || \
       iptables -C FORWARD -d "${UE_SUBNET}" -j ACCEPT >/dev/null 2>&1; then
        ok "UE subnet FORWARD active (${UE_SUBNET})"
    else
        log "  ℹ UE subnet FORWARD not set  (only needed for external gNB)"
    fi

    # ── GTP-U DNAT (external gNB only) ───────────────────────────
    local UPF_CUR_IP
    UPF_CUR_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' open5gs-upf 2>/dev/null | head -1)
    if [ -n "$UPF_CUR_IP" ] && iptables -t nat -C PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_CUR_IP}:${GTPU_PORT}" >/dev/null 2>&1; then
        ok "GTP-U DNAT  :${GTPU_PORT}    active  -> ${UPF_CUR_IP}:${GTPU_PORT}"
    else
        log "  ℹ GTP-U DNAT  :${GTPU_PORT}    not set  (only needed for external gNB)"
    fi

    echo ""
    echo "${BOLD}PLMN Configuration:${NC}"
    # Detect PLMNs from AMF config on host (supports multiple PLMNs)
    local amf_plmns
    amf_plmns=$(python3 - <<'PYEOF' 2>/dev/null
import yaml, sys
try:
    with open('config/amf.yaml') as f:
        cfg = yaml.safe_load(f)
    plmns = cfg.get('amf', {}).get('plmn_support', [])
    tais = cfg.get('amf', {}).get('tai', [])

    # Collect all PLMNs from plmn_support (main list)
    seen = set()
    result = []
    for p in plmns:
        plmn_id = p.get('plmn_id', {})
        mcc = str(plmn_id.get('mcc', '???')).zfill(3)
        mnc = str(plmn_id.get('mnc', '??')).zfill(2)
        key = f"{mcc}-{mnc}"
        if key not in seen:
            seen.add(key)
            s_nssai = p.get('s_nssai', [])
            slices = []
            for s in s_nssai:
                sst = s.get('sst', '?')
                sd = s.get('sd')
                slices.append(f"SST={sst}" + (f" SD={sd}" if sd else ""))
            result.append((mcc, mnc, ', '.join(slices) if slices else 'no slices'))

    # Collect TACs per PLMN from tai list
    tac_map = {}
    for t in tais:
        plmn_id = t.get('plmn_id', {})
        mcc = str(plmn_id.get('mcc', '???')).zfill(3)
        mnc = str(plmn_id.get('mnc', '??')).zfill(2)
        tac = t.get('tac', '?')
        key = f"{mcc}-{mnc}"
        if key not in tac_map:
            tac_map[key] = []
        tac_map[key].append(str(tac))

    # Print results
    for mcc, mnc, slices in result:
        key = f"{mcc}-{mnc}"
        tacs = tac_map.get(key, [])
        tac_str = ', '.join(tacs) if tacs else '?'
        print(f"{mcc}|{mnc}|{tac_str}|{slices}")
except Exception as e:
    print(f"error|{e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
    if [ -n "$amf_plmns" ]; then
        local count=0
        while IFS='|' read -r mcc mnc tacs slices; do
            count=$((count + 1))
            if [ $count -eq 1 ]; then
                printf "  %-6s %-6s %-12s %s\n" "MCC" "MNC" "TAC(s)" "Slices"
                echo "  ────────────────────────────────────────────────"
            fi
            printf "  %-6s %-6s %-12s %s\n" "$mcc" "$mnc" "$tacs" "$slices"
        done <<< "$amf_plmns"
        if [ $count -eq 0 ]; then
            log "  No PLMNs configured in AMF"
        fi
    else
        log "  Could not read AMF config (container not running?)"
    fi

    # Show gNB PLMN if UERANSIM is running
    if docker inspect "open5gs-ueransim" >/dev/null 2>&1; then
        local gnb_state
        gnb_state=$(docker inspect --format='{{.State.Status}}' "open5gs-ueransim" 2>/dev/null)
        if [ "$gnb_state" = "running" ]; then
            echo ""
            log "  gNB (UERANSIM):"
            local gnb_cfg
            gnb_cfg=$(docker exec open5gs-ueransim cat ./config/gnb.yaml 2>/dev/null)
            if [ -n "$gnb_cfg" ]; then
                local gnb_mcc gnb_mnc gnb_tac
                gnb_mcc=$(echo "$gnb_cfg" | grep '^mcc:' | head -1 | awk '{print $2}' | tr -d "'\"")
                gnb_mnc=$(echo "$gnb_cfg" | grep '^mnc:' | head -1 | awk '{print $2}' | tr -d "'\"")
                gnb_tac=$(echo "$gnb_cfg" | grep '^tac:' | head -1 | awk '{print $2}' | tr -d "'\"")
                log "    MCC=${gnb_mcc:-?} MNC=${gnb_mnc:-?} TAC=${gnb_tac:-?}"
            fi
        fi
    fi

    echo ""
    echo "${BOLD}Subscribers:${NC}"
    local sub_count
    sub_count=$(docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
        --quiet --eval "db.subscribers.countDocuments()" 2>/dev/null | tail -1 || echo "0")
    log "  Total subscribers in DB: ${sub_count}"

    echo ""
    if [ "$all_ok" = true ]; then
        ok "Core is UP"
    else
        warn "Some containers are not running"
        echo "Run: ./5gsa.sh logs"
    fi
    hdr ""
}

cmd_logs() {
    local nf="${1:-}"
    local follow="-f"

    if [ -z "$nf" ]; then
        log "Tailing all container logs (Ctrl+C to stop)..."
        docker compose -f "$COMPOSE_FILE" --profile ueransim logs $follow --tail=50
    else
        # Map NF name to container
        case "$nf" in
            amf|smf|nrf|scp|ausf|udm|udr|pcf|nssf|bsf)
                log "Tailing $nf logs from open5gs-cp container..."
                docker exec open5gs-cp tail $follow "/var/log/open5gs/${nf}.log" 2>/dev/null || \
                    docker compose -f "$COMPOSE_FILE" logs $follow open5gs-cp
                ;;
            upf)
                docker exec open5gs-upf tail $follow /var/log/open5gs/upf.log 2>/dev/null || \
                    docker compose -f "$COMPOSE_FILE" logs $follow open5gs-upf
                ;;
            webui)
                docker compose -f "$COMPOSE_FILE" logs $follow open5gs-webui ;;
            gnb|ueransim)
                docker compose -f "$COMPOSE_FILE" --profile ueransim logs $follow ueransim ;;
            *)
                docker compose -f "$COMPOSE_FILE" logs $follow "$nf" 2>/dev/null || \
                    docker exec "open5gs-cp" tail $follow "/var/log/open5gs/${nf}.log"
                ;;
        esac
    fi
}

cmd_provision() {
    local imsi_plain="${IMSI#imsi-}"

    hdr ""
    hdr "  Provisioning subscriber: ${IMSI}"
    hdr ""
    log "  IMSI: ${imsi_plain}"
    log "  K:    ${K}"
    log "  OPC:  ${OPC}"
    log "  SST:  ${SST}  SD: ${SD}"
    log "  DNN:  ${DNN}"
    hdr ""

    docker exec open5gs-mongodb mongosh \
        'mongodb://localhost:27017/open5gs' \
        --quiet \
        --eval "
            db.subscribers.deleteOne({ imsi: '${imsi_plain}' });
            db.subscribers.insertOne({
                imsi: '${imsi_plain}',
                subscribed_rau_tau_timer: 12,
                network_access_mode: 0,
                subscriber_status: 0,
                access_restriction_data: 32,
                slice: [{
                    sst: ${SST},
                    sd: '${SD}',
                    default_indicator: true,
                    session: [{
                        name: '${DNN}',
                        type: 3,
                        pcc_rule: [],
                        ambr: {
                            uplink:   { value: 1, unit: 3 },
                            downlink: { value: 1, unit: 3 }
                        },
                        qos: {
                            index: 9,
                            arp: {
                                priority_level: 8,
                                pre_emption_capability: 1,
                                pre_emption_vulnerability: 1
                            }
                        }
                    }]
                }],
                ambr: {
                    uplink:   { value: 1, unit: 3 },
                    downlink: { value: 1, unit: 3 }
                },
                security: {
                    k:   '${K^^}',
                    opc: '${OPC^^}',
                    amf: '${AMF_FIELD}',
                    sqn: NumberLong(32)
                },
                schema_version: 1,
                __v: 0
            });
            print('Subscriber provisioned: ${imsi_plain}');
            print('Total subscribers: ' + db.subscribers.countDocuments());
        "
    ok "Subscriber ${IMSI} provisioned successfully"
    hdr ""
}

cmd_bulk_provision() {
    local count=5
    local same_key=false
    local start_imsi="${IMSI#imsi-}"
    local start_key="$K"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count)      count="$2";      shift ;;
            --same-key)   same_key=true ;;
            --imsi)       start_imsi="$2"; shift ;;
            --key)        start_key="$2";  shift ;;
        esac
        shift
    done

    hdr ""
    hdr "  Bulk provisioning ${count} subscribers"
    hdr ""

    local imsi_num="${start_imsi: -10}"  # last 10 digits
    local imsi_prefix="${start_imsi:0:${#start_imsi}-10}"

    for i in $(seq 0 $((count - 1))); do
        local cur_imsi="${imsi_prefix}$(printf '%010d' $((10#$imsi_num + i)))"
        local cur_k="$start_key"
        if [ "$same_key" = false ]; then
            # Increment last byte of key
            local key_end="${start_key: -2}"
            local key_start="${start_key:0:${#start_key}-2}"
            cur_k="${key_start}$(printf '%02x' $(( (16#${key_end} + i) % 256 )))"
        fi

        docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' --quiet --eval "
            db.subscribers.deleteOne({ imsi: '${cur_imsi}' });
            db.subscribers.insertOne({
                imsi: '${cur_imsi}',
                subscribed_rau_tau_timer: 12,
                network_access_mode: 0,
                subscriber_status: 0,
                access_restriction_data: 32,
                slice: [{
                    sst: ${SST},
                    sd: '${SD}',
                    default_indicator: true,
                    session: [{
                        name: '${DNN}',
                        type: 3,
                        pcc_rule: [],
                        ambr: {
                            uplink:   { value: 1, unit: 3 },
                            downlink: { value: 1, unit: 3 }
                        },
                        qos: {
                            index: 9,
                            arp: {
                                priority_level: 8,
                                pre_emption_capability: 1,
                                pre_emption_vulnerability: 1
                            }
                        }
                    }]
                }],
                ambr: {
                    uplink:   { value: 1, unit: 3 },
                    downlink: { value: 1, unit: 3 }
                },
                security: {
                    k:   '${cur_k^^}',
                    opc: '${OPC^^}',
                    amf: '${AMF_FIELD}',
                    sqn: NumberLong(32)
                },
                schema_version: 1,
                __v: 0
            });
            print('Provisioned: ${cur_imsi}');
        " 2>/dev/null && ok "  [${cur_imsi}]" || warn "  [${cur_imsi}] FAILED"
    done

    local total
    total=$(docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
        --quiet --eval "db.subscribers.countDocuments()" 2>/dev/null | tail -1)
    hdr ""
    ok "Bulk provision complete. Total subscribers: ${total}"
    hdr ""
}

cmd_ue() {
    local sub_cmd="${1:-status}"
    shift || true

    case "$sub_cmd" in
        start)
            log "Starting UERANSIM UE..."
            docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
            sleep 3
            log "Checking UE status..."
            docker exec open5gs-ueransim ./nr-cli imsi-${IMSI#imsi-} --exec "status" 2>/dev/null || \
                log "UE CLI not yet available, check logs: ./5gsa.sh logs gnb"
            ;;
        stop)
            docker exec open5gs-ueransim pkill -f "nr-ue" 2>/dev/null || true
            ok "UE stopped"
            ;;
        status)
            docker exec open5gs-ueransim ./nr-cli imsi-${IMSI#imsi-} --exec "status" 2>/dev/null || \
                warn "UERANSIM not running or UE not connected"
            ;;
        *)
            echo "Usage: ./5gsa.sh ue [start|stop|status]"
            ;;
    esac
}

cmd_help() {
    hdr ""
    hdr "  5gsa.sh - open5GS 5G SA Core Manager"
    hdr ""
    echo "  ${BOLD}Build commands:${NC}"
    echo "    build                     Build all NFs + UERANSIM from source (~20 min)"
    echo "    build --quick             Rebuild Docker images only (skip source compile)"
    echo ""
    echo "  ${BOLD}Run commands:${NC}"
    echo "    start                     Start core network"
    echo "    start --ueransim          Start core + UERANSIM gNB"
    echo "    start --debug             Start with debug logging"
    echo "    start --mcc X --mnc Y --tac Z  Custom single PLMN"
    echo "    start --plmn MCC:MNC [--plmn MCC2:MNC2] [--tac Z]  Multi-PLMN"
    echo "    start --sst X --sd Y           Custom slice (SST/SD)"
    echo "    stop                      Stop all containers"
    echo "    remove                    Remove containers + volumes"
    echo ""
    echo "  ${BOLD}Subscriber commands:${NC}"
    echo "    provision                 Provision default subscriber"
    echo "    bulk-provision --count N  Provision N subscribers"
    echo ""
    echo "  ${BOLD}UE commands:${NC}"
    echo "    ue start                  Launch UE simulator"
    echo "    ue stop                   Stop UE simulator"
    echo "    ue status                 Check UE PDU session"
    echo ""
    echo "  ${BOLD}Monitor commands:${NC}"
    echo "    status                    Show full system status"
    echo "    logs [nf]                 Tail logs (nf: amf/smf/upf/nrf/ausf/udm/udr/pcf/nssf/bsf/gnb)"
    hdr ""
    echo "  ${BOLD}Default PLMN:${NC}  MCC=${MCC} MNC=${MNC} TAC=${TAC}"
    echo "  ${BOLD}Default IMSI:${NC}  ${IMSI}"
    echo "  ${BOLD}Default K:${NC}     ${K}"
    echo "  ${BOLD}Default OPC:${NC}   ${OPC}"
    echo "  ${BOLD}Slice:${NC}         SST=${SST} SD=${SD}"
    echo "  ${BOLD}DNN:${NC}           ${DNN}"
    echo "  ${BOLD}WebUI:${NC}         http://<host>:${WEBUI_PORT}  (admin / 1423)"
    hdr ""
}

# ── Main ─────────────────────────────────────────────────────
case "${1:-help}" in
    build)          cmd_build "${@:2}" ;;
    start)          cmd_start "${@:2}" ;;
    stop)           cmd_stop ;;
    remove)         cmd_remove ;;
    status)         cmd_status ;;
    logs)           cmd_logs "${2:-}" ;;
    provision)      cmd_provision ;;
    bulk-provision) cmd_bulk_provision "${@:2}" ;;
    ue)             cmd_ue "${@:2}" ;;
    help|--help|-h) cmd_help ;;
    *)              err "Unknown command: ${1}"; cmd_help; exit 1 ;;
esac
