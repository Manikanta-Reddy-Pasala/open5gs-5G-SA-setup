#!/bin/bash
# ============================================================
# start.sh — Start a CN (Core Network) instance for a BTS
# ============================================================
# Usage:
#   ./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP>
#   ./scripts/start.sh --id 2 --amf-ip <AMF_IP> --upf-ip <UPF_IP> --mcc 404 --mnc 30
#   ./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> --plmn 404:30 --plmn 404:20
#   ./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> --debug
#
# Each instance gets:
#   - Macvlan network on host's physical interface
#   - AMF/CP at --amf-ip, UPF at --upf-ip (real IPs on host network)
#   - Shared host MongoDB (db: open5gs)
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

# ── Parse arguments ──────────────────────────────────────────
INSTANCE_ID=""
AMF_IP=""
UPF_IP=""
IFACE_OVERRIDE=""
MCC="$DEFAULT_MCC"
MNC="$DEFAULT_MNC"
TAC="$DEFAULT_TAC"
SST="$DEFAULT_SST"
SD="$DEFAULT_SD"
DNN="$DEFAULT_DNN"
UE_SUBNET="$DEFAULT_UE_SUBNET"
UE_GW="$DEFAULT_UE_GW"
DEBUG_MODE=false
PLMN_LIST=()       # Multi-PLMN: --plmn MCC:MNC (repeatable)
MCC_MNC_SET=false   # Track if --mcc/--mnc was used

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)        INSTANCE_ID="$2"; shift ;;
        --amf-ip)    AMF_IP="$2"; shift ;;
        --upf-ip)    UPF_IP="$2"; shift ;;
        --iface)     IFACE_OVERRIDE="$2"; shift ;;
        --mcc)       MCC="$2"; MCC_MNC_SET=true; shift ;;
        --mnc)       MNC="$2"; MCC_MNC_SET=true; shift ;;
        --plmn)      PLMN_LIST+=("$2"); shift ;;
        --tac)       TAC="$2"; shift ;;
        --sst)       SST="$2"; shift ;;
        --sd)        SD="$2"; shift ;;
        --dnn)       DNN="$2"; shift ;;
        --ue-subnet) UE_SUBNET="$2"; shift ;;
        --ue-gw)     UE_GW="$2"; shift ;;
        --debug)     DEBUG_MODE=true ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Build final PLMN list: --plmn takes priority, else use --mcc/--mnc, else default
if [ ${#PLMN_LIST[@]} -eq 0 ]; then
    PLMN_LIST=("${MCC}:${MNC}")
fi

if [ -z "$INSTANCE_ID" ] || [ -z "$AMF_IP" ] || [ -z "$UPF_IP" ]; then
    err "Usage: ./scripts/start.sh --id <N> --amf-ip <IP> --upf-ip <IP> [options]"
    err ""
    err "Required:"
    err "  --id N          Instance number (1, 2, 3, ...)"
    err "  --amf-ip IP     AMF/CP IP address (on host network)"
    err "  --upf-ip IP     UPF IP address (on host network)"
    err ""
    err "Optional:"
    err "  --mcc X         MCC (default: ${DEFAULT_MCC})  — single PLMN"
    err "  --mnc Y         MNC (default: ${DEFAULT_MNC})  — single PLMN"
    err "  --plmn MCC:MNC  PLMN (repeatable for multi-PLMN, overrides --mcc/--mnc)"
    err "  --tac Z         TAC (default: ${DEFAULT_TAC})"
    err "  --sst S         SST (default: ${DEFAULT_SST})"
    err "  --sd SD         SD (default: ${DEFAULT_SD})"
    err "  --dnn D         DNN (default: ${DEFAULT_DNN})"
    err "  --ue-subnet X   UE pool subnet (default: ${DEFAULT_UE_SUBNET})"
    err "  --ue-gw X       UE pool gateway (default: ${DEFAULT_UE_GW})"
    err "  --iface NAME    Force network interface (default: auto-detect from AMF IP)"
    err "  --debug         Enable debug logging"
    exit 1
fi

# ── Auto-detect network config ────────────────────────────────
if [ -n "$IFACE_OVERRIDE" ]; then
    # User explicitly specified the interface
    PARENT_IFACE="$IFACE_OVERRIDE"
    log "Using user-specified interface: ${PARENT_IFACE}"
else
    # Try route-based detection first (works when AMF IP is on a known subnet)
    PARENT_IFACE=$(detect_interface "$AMF_IP")

    # If route-based detection returns a virtual/shim interface, fall back to smart detection
    case "$PARENT_IFACE" in
        mac-*|docker*|veth*|virbr*|"")
            log "Route-based detection returned '${PARENT_IFACE:-nothing}', trying smart detection..."
            PARENT_IFACE=$(detect_physical_interface)
            if [ -n "$PARENT_IFACE" ]; then
                log "Auto-detected physical interface: ${PARENT_IFACE}"
            fi
            ;;
        *)
            log "Auto-detected interface from routing: ${PARENT_IFACE}"
            ;;
    esac
fi

if [ -z "$PARENT_IFACE" ]; then
    err "Cannot determine network interface for AMF IP ${AMF_IP}"
    err "Available interfaces:"
    ip -4 -br addr show | while read -r line; do err "  $line"; done
    err ""
    err "Use --iface <name> to specify manually, e.g.:"
    err "  ./scripts/start.sh --id 1 --amf-ip ${AMF_IP} --upf-ip ${UPF_IP} --iface enp1s0"
    exit 1
fi

# Validate the interface supports macvlan
if ! validate_macvlan_interface "$PARENT_IFACE"; then
    err "Interface '${PARENT_IFACE}' failed macvlan validation"
    err "Use --iface <name> to specify a different interface"
    exit 1
fi

HOST_IP=$(get_host_ip "$PARENT_IFACE")
HOST_SUBNET=$(get_interface_subnet "$PARENT_IFACE")
HOST_GW=$(get_interface_gateway "$PARENT_IFACE")
# Fallback: use host IP as gateway (common for local bridges without default route)
HOST_GW="${HOST_GW:-$HOST_IP}"

if [ -z "$HOST_SUBNET" ]; then
    err "Cannot determine subnet for interface ${PARENT_IFACE}"
    exit 1
fi

# MongoDB on host — containers reach it via host's physical IP
MONGO_IP="$HOST_IP"
DB_NAME="open5gs"
INSTANCE_NAME="bts${INSTANCE_ID}"
COMPOSE_PROJECT="bts${INSTANCE_ID}"

LOG_LEVEL="info"
[ "$DEBUG_MODE" = true ] && LOG_LEVEL="debug"

# Internal private network for PFCP (SMF ↔ UPF) — not exposed externally
INTERNAL_SUBNET="10.33.${INSTANCE_ID}.0/24"
PFCP_CP_IP="10.33.${INSTANCE_ID}.2"
PFCP_UPF_IP="10.33.${INSTANCE_ID}.3"

PLMN_DISPLAY=$(IFS=', '; echo "${PLMN_LIST[*]}")

hdr ""
hdr "  Starting CN Instance: ${INSTANCE_NAME}"
hdr "  ─────────────────────────────────"
log "  AMF IP:     ${AMF_IP}  (NGAP:${NGAP_PORT})"
log "  UPF IP:     ${UPF_IP}  (GTP-U:${GTPU_PORT})"
log "  Interface:  ${PARENT_IFACE}  (subnet: ${HOST_SUBNET})"
log "  Host IP:    ${HOST_IP}"
log "  MongoDB:    ${MONGO_IP}:27017 (db: ${DB_NAME})"
log "  PLMN:       ${PLMN_DISPLAY}  TAC=${TAC}"
log "  Slice:      SST=${SST} SD=${SD}"
log "  UE Pool:    ${UE_SUBNET}"
hdr ""

# ── Generate instance config ─────────────────────────────────
INST_DIR="${PROJECT_DIR}/instances/${INSTANCE_NAME}"
INST_CONFIG="${INST_DIR}/config"
mkdir -p "${INST_CONFIG}" "${INST_DIR}/logs/cp" "${INST_DIR}/logs/upf"

# Copy base configs and replace all placeholders in one pass
for f in nrf.yaml scp.yaml amf.yaml smf.yaml upf.yaml ausf.yaml udm.yaml udr.yaml pcf.yaml nssf.yaml bsf.yaml; do
    sed -e "s|__MONGO_HOST__|${MONGO_IP}|g" \
        -e "s|__CP_IP__|${AMF_IP}|g" \
        -e "s|__UPF_IP__|${UPF_IP}|g" \
        -e "s|__PFCP_CP_IP__|${PFCP_CP_IP}|g" \
        -e "s|__PFCP_UPF_IP__|${PFCP_UPF_IP}|g" \
        -e "s|__UE_SUBNET__|${UE_SUBNET}|g" \
        -e "s|__UE_GW__|${UE_GW}|g" \
        "${PROJECT_DIR}/config/${f}" > "${INST_CONFIG}/${f}"
done

# Patch log level
if [ "$DEBUG_MODE" = true ]; then
    for f in "${INST_CONFIG}"/*.yaml; do
        sed -i "s/level: info/level: debug/" "$f"
    done
fi

# Patch PLMN(s) in AMF — supports multiple PLMNs
PLMN_JSON=$(printf '%s\n' "${PLMN_LIST[@]}" | python3 -c "
import sys, json
plmns = []
for line in sys.stdin:
    mcc, mnc = line.strip().split(':')
    plmns.append({'mcc': mcc, 'mnc': mnc})
print(json.dumps(plmns))
")

python3 - "${INST_CONFIG}/amf.yaml" "$TAC" "$SST" "$SD" "$PLMN_JSON" <<'PYEOF'
import sys, json, yaml

cfg_file, tac, sst, sd, plmn_json = sys.argv[1:6]
plmns = json.loads(plmn_json)

with open(cfg_file) as f:
    cfg = yaml.safe_load(f)

# guami: one entry per PLMN (same amf_id)
cfg['amf']['guami'] = [
    {'plmn_id': {'mcc': int(p['mcc']), 'mnc': int(p['mnc'])},
     'amf_id': {'region': 2, 'set': 1}}
    for p in plmns
]

# tai: one entry per PLMN (same tac)
cfg['amf']['tai'] = [
    {'plmn_id': {'mcc': int(p['mcc']), 'mnc': int(p['mnc'])},
     'tac': int(tac)}
    for p in plmns
]

# plmn_support: one entry per PLMN (same slice)
cfg['amf']['plmn_support'] = [
    {'plmn_id': {'mcc': int(p['mcc']), 'mnc': int(p['mnc'])},
     's_nssai': [{'sst': int(sst), 'sd': int(sd)}]}
    for p in plmns
]

with open(cfg_file, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
PYEOF

# Patch slice in SMF
sed -i "s/sst: [0-9]*/sst: ${SST}/g" "${INST_CONFIG}/smf.yaml"
sed -i "s/sd: [0-9a-fA-F]*/sd: ${SD}/g" "${INST_CONFIG}/smf.yaml"

# Patch slice in NSSF
sed -i "s/sst: [0-9]*/sst: ${SST}/g" "${INST_CONFIG}/nssf.yaml"
sed -i "s/sd: [0-9a-fA-F]*/sd: ${SD}/g" "${INST_CONFIG}/nssf.yaml"

# ── Create macvlan network ────────────────────────────────────
log "Creating macvlan network on ${PARENT_IFACE}..."
MACVLAN_NET=$(create_macvlan_network "$INSTANCE_ID" "$PARENT_IFACE" "$HOST_SUBNET" "$HOST_GW")

# Host-side macvlan shim for host<->container communication
log "Creating macvlan shim for host access..."
create_macvlan_shim "$INSTANCE_ID" "$PARENT_IFACE" "$AMF_IP" "$UPF_IP"

# ── Generate .env for docker-compose ─────────────────────────
ENV_FILE="${INST_DIR}/.env"

cat > "${ENV_FILE}" <<ENVEOF
# Auto-generated for ${INSTANCE_NAME} — used by docker-compose.yaml
INSTANCE_NAME=${INSTANCE_NAME}
IMAGE_CP=${IMAGE_CP}
IMAGE_UPF=${IMAGE_UPF}
INST_CONFIG=${INST_CONFIG}
INST_DIR=${INST_DIR}
AMF_IP=${AMF_IP}
UPF_IP=${UPF_IP}
PFCP_CP_IP=${PFCP_CP_IP}
PFCP_UPF_IP=${PFCP_UPF_IP}
INTERNAL_SUBNET=${INTERNAL_SUBNET}
MACVLAN_NET=${MACVLAN_NET}
MONGO_IP=${MONGO_IP}
DB_NAME=${DB_NAME}
ENVEOF

# ── Start the instance ────────────────────────────────────────
log "Starting containers..."
docker compose -p "${COMPOSE_PROJECT}" --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/docker-compose.yaml" up -d

log "Waiting for Control Plane (NRF on ${AMF_IP}:7777)..."
wait_port "${AMF_IP}" 7777 60

# ── Set up host routing for UE traffic ────────────────────────
log "Setting up data plane routing..."
ip route add "${UE_SUBNET}" via "${UPF_IP}" 2>/dev/null || true
iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE
iptables -C FORWARD -s "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -s "${UE_SUBNET}" -j ACCEPT
iptables -C FORWARD -d "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -d "${UE_SUBNET}" -j ACCEPT

# ── Save instance metadata ────────────────────────────────────
cat > "${INST_DIR}/metadata.env" <<METAEOF
INSTANCE_ID=${INSTANCE_ID}
AMF_IP=${AMF_IP}
UPF_IP=${UPF_IP}
PARENT_IFACE=${PARENT_IFACE}
HOST_IP=${HOST_IP}
HOST_SUBNET=${HOST_SUBNET}
HOST_GW=${HOST_GW}
MONGO_IP=${MONGO_IP}
UE_SUBNET=${UE_SUBNET}
UE_GW=${UE_GW}
PLMN_LIST="${PLMN_DISPLAY}"
TAC=${TAC}
SST=${SST}
SD=${SD}
DNN=${DNN}
DB_NAME=${DB_NAME}
METAEOF

hdr ""
hdr "  ========================================="
hdr "  CN Instance ${INSTANCE_NAME} is RUNNING"
hdr "  ========================================="
hdr ""
hdr "  ── gNB connects to (real IPs on ${PARENT_IFACE}) ──"
log "    NGAP/SCTP: ${AMF_IP}:${NGAP_PORT}"
log "    GTP-U/UDP: ${UPF_IP}:${GTPU_PORT}"
hdr ""
log "  PLMN:   ${PLMN_DISPLAY}  TAC=${TAC}"
log "  Slice:  SST=${SST} SD=${SD}"
log "  UE:     ${UE_SUBNET}"
log "  DB:     mongodb://${MONGO_IP}/${DB_NAME}"
hdr ""
log "  Provision: ./scripts/provision.sh [--count N]"
log "  Status:    ./scripts/status.sh [--id ${INSTANCE_ID}]"
log "  Logs:      ./scripts/logs.sh --id ${INSTANCE_ID} [nf]"
log "  Stop:      ./scripts/stop.sh --id ${INSTANCE_ID}"
hdr ""
