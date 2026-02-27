#!/bin/bash
# ============================================================
# common.sh - Shared helpers for open5GS test scripts
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml"
CONFIG_DIR="$PROJECT_DIR/config"
TESTS_DIR="$SCRIPT_DIR"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Test defaults (matching open5GS deployment)
WEBUI_PORT=4000
SST=3
SD="198153"
DNN="internet"
AMF_FIELD="8000"
BASE_K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
AMF_CNODE_DEFAULT_PORT=9090

# Auto-detect PLMN from running gNB config inside UERANSIM container
_detect_plmn() {
    local gnb_cfg
    gnb_cfg=$(docker exec open5gs-ueransim cat ./config/gnb.yaml 2>/dev/null)
    if [ -n "$gnb_cfg" ]; then
        MCC=$(echo "$gnb_cfg" | grep '^mcc:' | head -1 | awk '{print $2}' | tr -d "'\"")
        MNC=$(echo "$gnb_cfg" | grep '^mnc:' | head -1 | awk '{print $2}' | tr -d "'\"")
    fi
    # Fallback defaults if detection fails
    MCC="${MCC:-001}"
    MNC="${MNC:-01}"
    PLMN="${MCC}${MNC}"
    # BASE_SUPI: last 10 digits are the MSIN part
    BASE_SUPI="${MCC}${MNC}0000050641"
}
_detect_plmn

# Auto-detect the default IMSI from the UE config inside the container
DEFAULT_IMSI=$(docker exec open5gs-ueransim grep '^supi:' ./config/ue.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"")
DEFAULT_IMSI="${DEFAULT_IMSI:-imsi-${MCC}${MNC}0000050641}"

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
}

# Wait for a container to be running (max 60s)
wait_container() {
    local name="$1"
    local max="${2:-60}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        [ "$state" = "running" ] && return 0
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Wait for open5gs-cp to be healthy (NRF SBI on port 7777)
wait_cp_healthy() {
    local max="${1:-120}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' open5gs-cp 2>/dev/null || echo "unknown")
        [ "$health" = "healthy" ] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Wait for UERANSIM gNB to show NG Setup in logs (polls with timeout)
wait_gnb_connected() {
    local max="${1:-60}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        local logs
        logs=$(docker logs open5gs-ueransim --tail 50 2>&1)
        if echo "$logs" | grep -qi "NG Setup\|ngSetup\|NGAP"; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Provision a subscriber directly into MongoDB (open5gs schema)
# Args: imsi_plain (no "imsi-" prefix), k, opc
provision_subscriber() {
    local imsi_plain="$1"
    local k="$2"
    local opc="$3"
    docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
        --quiet --eval "
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
                    k:   '${k^^}',
                    opc: '${opc^^}',
                    amf: '${AMF_FIELD}',
                    sqn: NumberLong(32)
                },
                schema_version: 1,
                __v: 0
            });
        " 2>/dev/null
}

# Provision a subscriber with both internet + ims sessions (for TC03)
provision_subscriber_multi_apn() {
    local imsi_plain="$1"
    local k="$2"
    local opc="$3"
    docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
        --quiet --eval "
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
                    session: [
                        {
                            name: 'internet',
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
                        },
                        {
                            name: 'ims',
                            type: 3,
                            pcc_rule: [],
                            ambr: {
                                uplink:   { value: 500, unit: 2 },
                                downlink: { value: 500, unit: 2 }
                            },
                            qos: {
                                index: 5,
                                arp: {
                                    priority_level: 1,
                                    pre_emption_capability: 1,
                                    pre_emption_vulnerability: 1
                                }
                            }
                        }
                    ]
                }],
                ambr: {
                    uplink:   { value: 1, unit: 3 },
                    downlink: { value: 1, unit: 3 }
                },
                security: {
                    k:   '${k^^}',
                    opc: '${opc^^}',
                    amf: '${AMF_FIELD}',
                    sqn: NumberLong(32)
                },
                schema_version: 1,
                __v: 0
            });
        " 2>/dev/null
}

# Increment hex string by offset (preserves length)
hex_add() {
    local hex_str="$1"
    local offset="$2"
    local len=${#hex_str}
    python3 -c "print(format(int('${hex_str}',16)+${offset},'0${len}x'))"
}

# Increment SUPI (decimal digit string) by offset (preserves length)
supi_add() {
    local supi="$1"
    local offset="$2"
    local len=${#supi}
    python3 -c "print(format(int('${supi}')+${offset},'0${len}d'))"
}

# Generate a UE config YAML for UERANSIM (open5GS slice format)
generate_ue_config() {
    local supi="$1"      # full SUPI without "imsi-" prefix
    local k="$2"
    local opc="$3"
    local output="$4"
    local sessions="${5:-internet}"  # comma-separated DNN list

    local session_block=""
    IFS=',' read -ra DNNS <<< "$sessions"
    for dnn in "${DNNS[@]}"; do
        session_block+="
  - type: 'IPv4'
    apn: '${dnn}'
    slice:
      sst: 0x03
      sd: 0x198153"
    done

    cat > "$output" <<UECFG
supi: 'imsi-${supi}'
mcc: '${MCC}'
mnc: '${MNC}'
protectionScheme: 0
key: '${k^^}'
op: '${opc^^}'
opType: 'OPC'
amf: '8000'
imei: '356938035643803'
imeiSv: '4370816125816151'
gnbSearchList:
  - 127.0.0.1
  - gnb.open5gs.org
uacAic:
  mps: false
  mcs: false
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false
sessions:${session_block}
configured-nssai:
  - sst: 3
    sd: 0x198153
default-nssai:
  - sst: 3
    sd: 0x198153
integrity:
  IA1: true
  IA2: true
  IA3: true
ciphering:
  EA1: true
  EA2: true
  EA3: true
integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
UECFG
}

# Kill all UE processes inside UERANSIM container
kill_all_ues() {
    docker exec open5gs-ueransim pkill -f "nr-ue" 2>/dev/null || true
    sleep 2
}

# Reset UERANSIM: kill UEs, restart container to clear accumulated UE context
reset_ueransim() {
    kill_all_ues
    docker restart open5gs-ueransim >/dev/null 2>&1
    sleep 10
}

# check_amf_cnode_log() — return 0 if AMF log shows cnode is active.
# Looks for "[AMF-cnode] connected" or "[AMF-cnode] registered" in the log.
check_amf_cnode_log() {
    docker exec open5gs-cp cat /var/log/open5gs/amf.log 2>/dev/null \
        | grep -q "\[AMF-cnode\]"
}

# check_amf_cnode_registered() — return 0 if AMF log shows successful registration.
check_amf_cnode_registered() {
    docker exec open5gs-cp cat /var/log/open5gs/amf.log 2>/dev/null \
        | grep -q "\[AMF-cnode\] registered as AMF"
}

# Ensure UERANSIM container is running (start if not)
_ensure_ueransim() {
    local state
    state=$(docker inspect --format='{{.State.Status}}' open5gs-ueransim 2>/dev/null || echo "missing")
    if [ "$state" != "running" ]; then
        info "Starting UERANSIM..."
        cd "$PROJECT_DIR" && CONFIG_DIR=config docker compose -f "$COMPOSE_FILE" --profile ueransim up -d ueransim >/dev/null 2>&1
        sleep 10
    fi
}

# Ensure core is running, or start it. Also clean residual UE state.
ensure_core_running() {
    local cp_state
    cp_state=$(docker inspect --format='{{.State.Status}}' open5gs-cp 2>/dev/null || echo "missing")
    if [ "$cp_state" != "running" ]; then
        info "Core not running. Starting with: ./open5gs.sh start --ueransim"
        cd "$PROJECT_DIR" && ./open5gs.sh start --ueransim
    else
        info "Core is already running."
        _ensure_ueransim
    fi
    # Clean residual UE state from previous tests
    kill_all_ues
    # Restart gNB to clear accumulated UE context (avoids cross-test interference)
    info "Resetting UERANSIM gNB (clearing residual state)..."
    docker restart open5gs-ueransim >/dev/null 2>&1
    sleep 10
    # Auto-provision DEFAULT_IMSI if not already in DB
    _ensure_default_subscriber
}

# Provision the DEFAULT_IMSI subscriber if it doesn't exist in the database
_ensure_default_subscriber() {
    local supi_plain="${DEFAULT_IMSI#imsi-}"
    local count
    count=$(docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
        --quiet --eval "db.subscribers.countDocuments({ imsi: '${supi_plain}' })" 2>/dev/null | tail -1)
    if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        return 0  # already provisioned
    fi
    info "Auto-provisioning DEFAULT_IMSI (${DEFAULT_IMSI})..."
    local ue_k ue_opc
    ue_k=$(docker exec open5gs-ueransim grep '^key:' ./config/ue.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"")
    ue_opc=$(docker exec open5gs-ueransim grep '^op:' ./config/ue.yaml 2>/dev/null | awk '{print $2}' | tr -d "'\"")
    ue_k="${ue_k:-$BASE_K}"
    ue_opc="${ue_opc:-$OPC}"
    provision_subscriber "$supi_plain" "$ue_k" "$ue_opc"
}
