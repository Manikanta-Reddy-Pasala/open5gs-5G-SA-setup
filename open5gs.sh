#!/bin/bash
# ============================================================
# open5gs.sh - Build & Run for open5GS 5G SA Core
# ============================================================
# Single script to build and run a portable 5G SA core.
#
# Usage:
#   ./open5gs.sh build                # Compile from source (~20 min)
#   ./open5gs.sh build --quick        # Rebuild runtime images only
#   ./open5gs.sh start                # Start core (without UERANSIM)
#   ./open5gs.sh start --ueransim     # Start core + UERANSIM simulator
#   ./open5gs.sh start --debug        # Start with debug-level logging
#   ./open5gs.sh start --mcc 404 --mnc 30 --tac 1  # Custom PLMN
#   ./open5gs.sh provision            # Provision default subscriber
#   ./open5gs.sh bulk-provision --count 10  # Provision 10 subscribers
#   ./open5gs.sh ue start             # Launch UE (inside UERANSIM container)
#   ./open5gs.sh ue stop              # Stop UE
#   ./open5gs.sh ue status            # Check UE connectivity
#   ./open5gs.sh stop                 # Stop all containers
#   ./open5gs.sh remove               # Remove all containers and volumes
#   ./open5gs.sh status               # Show container status
#   ./open5gs.sh logs [nf]            # Tail logs
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Constants ────────────────────────────────────────────────
COMPOSE_FILE="docker-compose.yaml"
OPEN5GS_VERSION="v2.7.5"
AMF_IP="10.200.100.16"
NGAP_PORT="38412"

# Subscriber / PLMN defaults
IMSI="imsi-001010000050641"
MCC="001"
MNC="01"
TAC="1"
K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
AMF_FIELD="8000"
SST=1
SD="111111"
DNN="internet"
UE_SUBNET="10.45.0.0/16"
WEBUI_PORT=9999

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

wait_healthy() {
    local container="$1"
    local max_wait="${2:-120}"
    local waited=0

    while [ $waited -lt "$max_wait" ]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
            ok "$container is healthy (took ${waited}s)"
            return 0
        fi
        sleep 2; waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then
            log "  Still waiting for $container... (${waited}s, status: $status)"
        fi
    done
    warn "$container health check timed out after ${max_wait}s"
    return 1
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
    ok "Route ${UE_SUBNET} -> ${UPF_IP} added"
}

cleanup_dataplane() {
    local UPF_IP
    UPF_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' open5gs-upf 2>/dev/null | head -1)
    [ -n "$UPF_IP" ] && ip route del "${UE_SUBNET}" via "$UPF_IP" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || true
}

update_plmn_config() {
    local mcc="$1" mnc="$2" tac="$3"
    local cfg_dir="${4:-config}"

    log "Updating PLMN: MCC=${mcc} MNC=${mnc} TAC=${tac} in ${cfg_dir}/"

    sed -i "s/mcc: [0-9]*/mcc: ${mcc}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/mnc: [0-9]*/mnc: ${mnc}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/tac: [0-9]*/tac: ${tac}/g" "${cfg_dir}/amf.yaml"
    sed -i "s/mcc: [0-9]*/mcc: ${mcc}/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/mnc: '[0-9]*'/mnc: '${mnc}'/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/tac: [0-9]*/tac: ${tac}/g" "${cfg_dir}/gnb.yaml"
    sed -i "s/mcc: '[0-9]*'/mcc: '${mcc}'/g" "${cfg_dir}/ue.yaml"
    sed -i "s/mnc: '[0-9]*'/mnc: '${mnc}'/g" "${cfg_dir}/ue.yaml"

    MCC="$mcc"; MNC="$mnc"; TAC="$tac"
    log "  PLMN updated in config files"
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
            err "build-output/open5gs/ not found. Run './open5gs.sh build' first."
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
    log "Next: ./open5gs.sh start"
    hdr ""
}

cmd_start() {
    local with_ueransim=false
    local debug_mode=false
    local custom_mcc="" custom_mnc="" custom_tac=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ueransim) with_ueransim=true ;;
            --debug)    debug_mode=true ;;
            --mcc)      custom_mcc="$2";  shift ;;
            --mnc)      custom_mnc="$2";  shift ;;
            --tac)      custom_tac="$2";  shift ;;
        esac
        shift
    done

    local cfg_dir="config"
    if [ "$debug_mode" = true ]; then
        cfg_dir="config-debug"
        log "Using DEBUG logging (config-debug/)"
    fi

    if [ -n "$custom_mcc" ] || [ -n "$custom_mnc" ] || [ -n "$custom_tac" ]; then
        update_plmn_config \
            "${custom_mcc:-$MCC}" \
            "${custom_mnc:-$MNC}" \
            "${custom_tac:-$TAC}" \
            "$cfg_dir"
    fi

    mkdir -p logs/cp logs/upf

    hdr ""
    hdr "  Starting open5GS 5G SA Core"
    hdr ""

    log "Stopping any existing containers..."
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

    cleanup_sctp_forward 2>/dev/null || true

    log "Starting MongoDB + Control Plane..."
    CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d open5gs-mongodb open5gs-cp

    log "Waiting for Control Plane to be healthy..."
    wait_healthy "open5gs-cp" 120

    log "Starting UPF..."
    CONFIG_DIR="$cfg_dir" docker compose -f "$COMPOSE_FILE" up -d open5gs-upf

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
    log "Run './open5gs.sh provision' to add a test subscriber."
    log "Run './open5gs.sh status' to verify all NFs are running."
    hdr ""
}

cmd_stop() {
    hdr "Stopping open5GS..."
    cleanup_sctp_forward 2>/dev/null || true
    cleanup_dataplane 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" --profile ueransim down
    ok "Stopped."
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
    local ur_state
    ur_state=$(docker inspect --format='{{.State.Status}}' "open5gs-ueransim" 2>/dev/null || echo "not running")
    printf "  ${CYAN}○${NC} %-25s %s (optional)\n" "open5gs-ueransim" "$ur_state"

    echo ""
    echo "${BOLD}NRF Registrations:${NC}"
    local nrf_output
    nrf_output=$(docker exec open5gs-cp wget -qO- http://127.0.0.1:7777/nnrf-nfm/v1/nf-instances 2>/dev/null || echo "")
    if [ -n "$nrf_output" ]; then
        # Parse NF types from JSON
        local nf_list
        nf_list=$(echo "$nrf_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    items = data.get('_links', {}).get('item', [])
    print(f'  Registered NFs: {len(items)}')
    # If full profiles are available
    if isinstance(data, list):
        for nf in data:
            print(f'  - {nf.get(\"nfType\",\"?\")} [{nf.get(\"nfStatus\",\"?\")}]')
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
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:${NGAP_PORT}"; then
        ok "SCTP DNAT rule active (host:${NGAP_PORT} -> ${AMF_IP}:${NGAP_PORT})"
    else
        warn "SCTP DNAT rule not found"
    fi

    if ip route show "${UE_SUBNET}" 2>/dev/null | grep -q via; then
        ok "UE subnet route ${UE_SUBNET} active"
    else
        warn "UE subnet route not configured"
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
        echo "Run: ./open5gs.sh logs"
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
                log "UE CLI not yet available, check logs: ./open5gs.sh logs gnb"
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
            echo "Usage: ./open5gs.sh ue [start|stop|status]"
            ;;
    esac
}

cmd_help() {
    hdr ""
    hdr "  open5gs.sh - open5GS 5G SA Core Manager"
    hdr ""
    echo "  ${BOLD}Build commands:${NC}"
    echo "    build                     Build all NFs + UERANSIM from source (~20 min)"
    echo "    build --quick             Rebuild Docker images only (skip source compile)"
    echo ""
    echo "  ${BOLD}Run commands:${NC}"
    echo "    start                     Start core network"
    echo "    start --ueransim          Start core + UERANSIM gNB"
    echo "    start --debug             Start with debug logging"
    echo "    start --mcc X --mnc Y --tac Z  Custom PLMN"
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
