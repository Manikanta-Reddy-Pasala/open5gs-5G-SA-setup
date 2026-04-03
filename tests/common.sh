#!/bin/bash
# ============================================================
# common.sh - Shared helpers for open5GS test scripts
# ============================================================
# Multi-TRX architecture:
#   - Single core container per TRX: open5gs_<TRX_IP>
#   - No UERANSIM container: gNB/UE run as bare host processes
#   - No MongoDB container: mongosh on host (localhost:27017)
#   - No separate UPF container: UPF inside the core container
#   - Container uses network_mode: host
#   - Logs at /opt/logs/cn/trx-<TRX_IP>/ (bind-mounted)
#   - Instance config at instances/trx-<TRX_IP>/config/
#   - Instance metadata at instances/trx-<TRX_IP>/metadata.env
#
# Key variables that TC scripts rely on:
#   MCC, MNC, PLMN, BASE_SUPI, SST, SD, DNN, BASE_K, OPC, AMF_FIELD
#   DEFAULT_IMSI
#   CONTAINER_NAME   — e.g. open5gs_10.100.0.11
#   UERANSIM_DIR     — path to UERANSIM binaries on host
#   UE_CONFIG_DIR    — temp dir for test UE/gNB configs
#   LOG_DIR          — host path to NF logs
#   INST_CONFIG      — host path to NF config YAMLs
#   CP_IP, UPF_IP, TRX_IP, MONGO_IP, DB_NAME
#
# Key functions TC scripts call:
#   pass(), fail(), warn(), info(), header()
#   provision_subscriber(), provision_subscriber_multi_apn()
#   hex_add(), supi_add()
#   generate_ue_config()
#   kill_all_ues()
#   reset_ueransim()
#   ensure_core_running()
#   wait_cp_healthy()
#   wait_gnb_connected()
#   check_amf_cnode_log()
#   check_amf_cnode_registered()
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$SCRIPT_DIR"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ============================================================
# Instance discovery: auto-detect TRX_IP or accept --trx-ip
# ============================================================
# TC scripts can pass --trx-ip <IP> as first arg. If not given,
# we auto-detect from the first running instance in instances/.

_parse_trx_ip_arg() {
    # Check if the calling script's $1 is --trx-ip
    # This is called at source-time, so we look at the parent script's args
    if [ "${1:-}" = "--trx-ip" ] && [ -n "${2:-}" ]; then
        TRX_IP="$2"
        # Shift these args out so TC scripts don't see them
        shift 2
        return 0
    fi
    return 1
}

_auto_detect_trx_ip() {
    # If TRX_IP is already set (e.g. via environment), use it
    [ -n "${TRX_IP:-}" ] && return 0

    # Scan instances/ for the first running instance
    local inst_dir
    if [ -d "${PROJECT_DIR}/instances" ]; then
        for inst_dir in "${PROJECT_DIR}/instances"/trx-*; do
            [ -d "$inst_dir" ] || continue
            local meta="${inst_dir}/metadata.env"
            [ -f "$meta" ] || continue
            # Read the container name and check if running
            local cname
            cname=$(grep '^CONTAINER_NAME=' "$meta" 2>/dev/null | cut -d= -f2)
            if [ -n "$cname" ]; then
                local state
                state=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")
                if [ "$state" = "running" ]; then
                    TRX_IP=$(grep '^TRX_IP=' "$meta" 2>/dev/null | cut -d= -f2)
                    return 0
                fi
            fi
        done
    fi

    # Last resort: check for any container named open5gs_*
    local cname
    cname=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^open5gs_' | head -1)
    if [ -n "$cname" ]; then
        TRX_IP="${cname#open5gs_}"
        return 0
    fi
}

TRX_IP="${TRX_IP:-}"
_auto_detect_trx_ip

# ============================================================
# Load instance metadata from metadata.env
# ============================================================

_load_metadata() {
    local meta="${PROJECT_DIR}/instances/trx-${TRX_IP}/metadata.env"
    if [ -n "${TRX_IP:-}" ] && [ -f "$meta" ]; then
        # Source metadata to get all instance variables
        # shellcheck disable=SC1090
        source "$meta"
    fi

    # Apply defaults for anything not set by metadata
    CONTAINER_NAME="${CONTAINER_NAME:-open5gs_${TRX_IP:-localhost}}"
    CP_IP="${CP_IP:-127.0.0.1}"
    UPF_IP="${UPF_IP:-127.0.0.2}"
    LOG_DIR="${LOG_DIR:-/opt/logs/cn/trx-${TRX_IP:-localhost}}"
    INST_CONFIG="${PROJECT_DIR}/instances/trx-${TRX_IP:-localhost}/config"
    MONGO_IP="${MONGO_IP:-127.0.0.1}"
    DB_NAME="${DB_NAME:-open5gs}"
}
_load_metadata

# ============================================================
# UERANSIM paths (bare host processes, no container)
# ============================================================

UERANSIM_DIR="${PROJECT_DIR}/build-output/ueransim"
UE_CONFIG_DIR="${UE_CONFIG_DIR:-$(mktemp -d /tmp/ueransim-test-XXXXXX)}"

# Ensure temp dir is cleaned up on exit (only if we created it)
_common_cleanup() {
    [ -d "${UE_CONFIG_DIR:-}" ] && rm -rf "$UE_CONFIG_DIR" 2>/dev/null || true
}
trap _common_cleanup EXIT

# ============================================================
# Test defaults (matching open5GS deployment)
# ============================================================

WEBUI_PORT=4000
AMF_FIELD="8000"
BASE_K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
AMF_CNODE_DEFAULT_PORT=9090

# SST, SD, DNN may come from metadata.env; apply defaults if not
SST="${SST:-1}"
SD="${SD:-}"
DNN="${DNN:-internet}"

# ============================================================
# PLMN detection — read from metadata.env or gNB config
# ============================================================

_detect_plmn() {
    # Try PLMN_LIST from metadata.env first (format: "MCC:MNC" or "MCC:MNC, MCC:MNC")
    if [ -n "${PLMN_LIST:-}" ]; then
        local first_plmn
        first_plmn=$(echo "$PLMN_LIST" | tr ',' '\n' | head -1 | xargs)
        MCC=$(echo "$first_plmn" | cut -d: -f1)
        MNC=$(echo "$first_plmn" | cut -d: -f2)
    fi

    # Fallback: read from a running gNB config in the instance config dir
    if [ -z "${MCC:-}" ] || [ -z "${MNC:-}" ]; then
        local gnb_cfg="${INST_CONFIG}/gnb.yaml"
        if [ -f "$gnb_cfg" ]; then
            MCC=$(grep '^mcc:' "$gnb_cfg" 2>/dev/null | head -1 | awk '{print $2}' | tr -d "'\"")
            MNC=$(grep '^mnc:' "$gnb_cfg" 2>/dev/null | head -1 | awk '{print $2}' | tr -d "'\"")
        fi
    fi

    # Final fallback defaults
    MCC="${MCC:-001}"
    MNC="${MNC:-01}"
    PLMN="${MCC}${MNC}"
    # BASE_SUPI: last 10 digits are the MSIN part
    BASE_SUPI="${MCC}${MNC}0000050641"

    # Detect all PLMNs from AMF config (multi-PLMN support)
    AMF_PLMNS=()
    local amf_cfg="${INST_CONFIG}/amf.yaml"
    if [ -f "$amf_cfg" ]; then
        local amf_plmn_data
        amf_plmn_data=$(python3 - "$amf_cfg" <<'PYEOF' 2>/dev/null
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    for p in cfg.get('amf', {}).get('plmn_support', []):
        pid = p.get('plmn_id', {})
        mcc = str(pid.get('mcc', '')).zfill(3)
        mnc = str(pid.get('mnc', '')).zfill(2)
        if mcc and mnc:
            print(f"{mcc}|{mnc}")
except Exception:
    pass
PYEOF
)
        while IFS='|' read -r amf_mcc amf_mnc; do
            [ -n "$amf_mcc" ] && AMF_PLMNS+=("${amf_mcc}${amf_mnc}")
        done <<< "$amf_plmn_data"
    fi

    # Also parse PLMN_LIST from metadata for AMF_PLMNS if AMF config wasn't readable
    if [ "${#AMF_PLMNS[@]}" -eq 0 ] && [ -n "${PLMN_LIST:-}" ]; then
        local pl
        for pl in $(echo "$PLMN_LIST" | tr ',' '\n'); do
            pl=$(echo "$pl" | xargs)
            local pmcc pmnc
            pmcc=$(echo "$pl" | cut -d: -f1)
            pmnc=$(echo "$pl" | cut -d: -f2)
            [ -n "$pmcc" ] && [ -n "$pmnc" ] && AMF_PLMNS+=("${pmcc}${pmnc}")
        done
    fi

    # Fall back to gNB PLMN if nothing else
    [ "${#AMF_PLMNS[@]}" -eq 0 ] && AMF_PLMNS=("${PLMN}")
}
_detect_plmn

# ============================================================
# NSSAI detection — read SST/SD from AMF config (authoritative)
# ============================================================

_detect_nssai() {
    local amf_cfg="${INST_CONFIG}/amf.yaml"
    if [ -f "$amf_cfg" ]; then
        local nssai_data
        nssai_data=$(python3 - "$amf_cfg" <<'PYEOF' 2>/dev/null
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    for p in cfg.get('amf', {}).get('plmn_support', []):
        for s in p.get('s_nssai', []):
            sst = s.get('sst', '')
            sd = s.get('sd', '')
            if sst != '':
                print(f"{sst}|{sd}")
                sys.exit(0)
except Exception:
    pass
PYEOF
)
        if [ -n "$nssai_data" ]; then
            SST=$(echo "$nssai_data" | cut -d'|' -f1)
            # Override SD from AMF config (may be empty = no SD)
            SD=$(echo "$nssai_data" | cut -d'|' -f2)
        fi
    fi
}
_detect_nssai

# Auto-detect the default IMSI from an existing UE config or use computed value
DEFAULT_IMSI="imsi-${MCC}${MNC}0000050641"
# Check for an existing UE config with a specific SUPI
if [ -f "${UE_CONFIG_DIR}/ue.yaml" ]; then
    _detected_imsi=$(grep '^supi:' "${UE_CONFIG_DIR}/ue.yaml" 2>/dev/null | awk '{print $2}' | tr -d "'\"")
    [ -n "$_detected_imsi" ] && DEFAULT_IMSI="$_detected_imsi"
fi

# ============================================================
# Output helpers
# ============================================================

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
header() {
    echo ""
    echo -e "${BOLD}=======================================================${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}=======================================================${NC}"
    echo ""
}

# ============================================================
# Container helpers
# ============================================================

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

# Wait for core container to be healthy (NRF SBI on CP_IP:7777)
wait_cp_healthy() {
    local max="${1:-120}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
        [ "$health" = "healthy" ] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Wait for gNB to show NG Setup success (checks AMF log on host filesystem)
wait_gnb_connected() {
    local max="${1:-60}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        # Check gNB log first (most reliable — shows exact NG Setup result)
        local gnb_log="${UE_CONFIG_DIR}/gnb.log"
        if [ -f "$gnb_log" ]; then
            if grep -qi "NG Setup procedure is successful\|SCTP connection established" "$gnb_log" 2>/dev/null; then
                return 0
            fi
        fi
        # Also check SCTP association directly
        if ss -Snp 2>/dev/null | grep -q "nr-gnb"; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# ============================================================
# MongoDB helpers (direct host access, no container)
# ============================================================

# Provision a subscriber directly into MongoDB (open5gs schema)
# Args: imsi_plain (no "imsi-" prefix), k, opc
provision_subscriber() {
    local imsi_plain="$1"
    local k="$2"
    local opc="$3"

    # Build slice object — only include sd if set
    local sd_field=""
    [ -n "${SD:-}" ] && sd_field="sd: '${SD}',"

    mongosh "mongodb://${MONGO_IP}/${DB_NAME}" \
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
                    ${sd_field}
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

    # Build slice object — only include sd if set
    local sd_field=""
    [ -n "${SD:-}" ] && sd_field="sd: '${SD}',"

    mongosh "mongodb://${MONGO_IP}/${DB_NAME}" \
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
                    ${sd_field}
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

# ============================================================
# Arithmetic helpers
# ============================================================

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

# ============================================================
# UE config generation (UERANSIM format)
# ============================================================

# Generate a UE config YAML for UERANSIM (open5GS slice format)
# gnbSearchList uses LM_IP to match gNB linkIp
generate_ue_config() {
    local supi="$1"      # full SUPI without "imsi-" prefix
    local k="$2"
    local opc="$3"
    local output="$4"
    local sessions="${5:-internet}"  # comma-separated DNN list
    local gnb_ip="${LM_IP:-127.0.0.1}"

    # Build session slice with optional SD
    local slice_sd_line=""
    [ -n "${SD:-}" ] && slice_sd_line="      sd: ${SD}"

    local session_block=""
    IFS=',' read -ra DNNS <<< "$sessions"
    for dnn in "${DNNS[@]}"; do
        session_block+="
  - type: 'IPv4'
    apn: '${dnn}'
    slice:
      sst: ${SST}"
        [ -n "${SD:-}" ] && session_block+="
      sd: ${SD}"
    done

    # Build NSSAI blocks with optional SD
    local nssai_entry="  - sst: ${SST}"
    [ -n "${SD:-}" ] && nssai_entry+=$'\n'"    sd: ${SD}"

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
  - ${gnb_ip}
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
${nssai_entry}
default-nssai:
${nssai_entry}
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

# ============================================================
# gNB config generation
# ============================================================

# Generate a gNB config YAML for UERANSIM (host network mode)
# AMF address uses CP_IP since container is on host network
# ngapIp/gtpIp use LM_IP (routable) for SCTP/GTP to AMF/UPF on CP_IP/UPF_IP
_generate_gnb_config() {
    local output="$1"
    local tac="${TAC:-1}"
    local gnb_ip="${LM_IP:-127.0.0.1}"

    # Build slice line with optional SD
    local slice_line="  - sst: ${SST}"
    [ -n "${SD:-}" ] && slice_line+=$'\n'"    sd: ${SD}"

    cat > "$output" <<GNBCFG
mcc: '${MCC}'
mnc: '${MNC}'
nci: '0x000000010'
idLength: 32
tac: ${tac}
linkIp: ${gnb_ip}
ngapIp: ${gnb_ip}
gtpIp: ${gnb_ip}
amfConfigs:
  - address: ${CP_IP}
    port: 38412
slices:
${slice_line}
ignoreStreamIds: true
GNBCFG
}

# ============================================================
# UERANSIM process management (bare host processes)
# ============================================================

# Kill all UE processes on the host
kill_all_ues() {
    pkill -f "nr-ue" 2>/dev/null || true
    sleep 2
}

# Reset UERANSIM: kill all gNB + UE processes and relaunch gNB
reset_ueransim() {
    kill_all_ues
    # Kill gNB processes
    pkill -f "nr-gnb" 2>/dev/null || true
    sleep 2
    # Relaunch gNB
    _ensure_gnb
    sleep 8
}

# Start gNB if not already running
_ensure_gnb() {
    if ! pgrep -f "nr-gnb" >/dev/null 2>&1; then
        info "Starting gNB..."
        local gnb_cfg="${UE_CONFIG_DIR}/gnb.yaml"
        if [ ! -f "$gnb_cfg" ]; then
            _generate_gnb_config "$gnb_cfg"
        fi
        "${UERANSIM_DIR}/nr-gnb" -c "$gnb_cfg" > "${UE_CONFIG_DIR}/gnb.log" 2>&1 &
        sleep 5
    fi
}

# ============================================================
# AMF cnode log helpers
# ============================================================

# check_amf_cnode_log() -- return 0 if AMF log shows cnode is active
check_amf_cnode_log() {
    [ -f "${LOG_DIR}/amf.log" ] && grep -q "\[AMF-cnode\]" "${LOG_DIR}/amf.log" 2>/dev/null
}

# check_amf_cnode_registered() -- return 0 if AMF log shows successful registration
check_amf_cnode_registered() {
    [ -f "${LOG_DIR}/amf.log" ] && grep -q "\[AMF-cnode\] registered as AMF" "${LOG_DIR}/amf.log" 2>/dev/null
}

# ============================================================
# Core lifecycle
# ============================================================

# Ensure core is running, or start it. Also clean residual UE state.
ensure_core_running() {
    local cp_state
    cp_state=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
    if [ "$cp_state" != "running" ]; then
        info "Core not running. Starting with: ./open5gs.sh start"
        cd "$PROJECT_DIR" && ./open5gs.sh start
        # Re-detect TRX_IP after start
        _auto_detect_trx_ip
        _load_metadata
    else
        info "Core is already running (${CONTAINER_NAME})."
    fi

    # Ensure gNB is running
    _ensure_gnb

    # Wait for gNB to connect
    if ! wait_gnb_connected 30; then
        warn "gNB did not show NG Setup within 30s (may still be connecting)"
    fi

    # Clean residual UE state from previous tests
    kill_all_ues

    # Restart gNB to clear accumulated UE context (avoids cross-test interference)
    info "Resetting gNB (clearing residual state)..."
    pkill -f "nr-gnb" 2>/dev/null || true
    sleep 2
    _ensure_gnb
    sleep 5

    # Auto-provision DEFAULT_IMSI if not already in DB
    _ensure_default_subscriber
}

# Provision the DEFAULT_IMSI subscriber if it doesn't exist in the database
_ensure_default_subscriber() {
    local supi_plain="${DEFAULT_IMSI#imsi-}"
    local count
    count=$(mongosh "mongodb://${MONGO_IP}/${DB_NAME}" \
        --quiet --eval "db.subscribers.countDocuments({ imsi: '${supi_plain}' })" 2>/dev/null | tail -1)
    if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        return 0  # already provisioned
    fi
    info "Auto-provisioning DEFAULT_IMSI (${DEFAULT_IMSI})..."
    provision_subscriber "$supi_plain" "$BASE_K" "$OPC"
}
