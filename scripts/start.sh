#!/bin/bash
# ============================================================
# start.sh — Start a CN (Core Network) instance for a TRX
# ============================================================
# Usage:
#   ./scripts/start.sh --lm-ip <IP> --trx-ip <IP> --cp-ip <IP> --upf-ip <IP>
#   ./scripts/start.sh --lm-ip <IP> --trx-ip <IP> --cp-ip <IP> --upf-ip <IP> --mcc 404 --mnc 30
#   ./scripts/start.sh --lm-ip <IP> --trx-ip <IP> --cp-ip <IP> --upf-ip <IP> --debug
#
# --trx-ip:  TRX identifier (naming only: instance, container, logs)
# --cp-ip:   Control Plane bind IP (SBI, NGAP, PFCP-SMF)
# --upf-ip:  User Plane bind IP (GTP-U, PFCP-UPF)
# --lm-ip:   Existing management IP on host (for interface detection)
#
# Secondary IPs: cp-ip and upf-ip are added to the host interface.
# Container uses network_mode: host.
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

# ── Parse arguments ──────────────────────────────────────────
LM_IP=""
TRX_IP=""
CP_IP=""
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
        --lm-ip)     LM_IP="$2"; shift ;;
        --trx-ip)    TRX_IP="$2"; shift ;;
        --cp-ip)     CP_IP="$2"; shift ;;
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

if [ -z "$LM_IP" ] || [ -z "$TRX_IP" ] || [ -z "$CP_IP" ] || [ -z "$UPF_IP" ]; then
    err "Usage: ./scripts/start.sh --lm-ip <IP> --trx-ip <IP> --cp-ip <IP> --upf-ip <IP> [options]"
    err ""
    err "Required:"
    err "  --lm-ip IP      LAN Management IP (existing IP on host, used to detect interface)"
    err "  --trx-ip IP     TRX identifier (naming only: instance, container, logs)"
    err "  --cp-ip IP      Control Plane IP (SBI, NGAP, PFCP-SMF — added as secondary IP)"
    err "  --upf-ip IP     User Plane IP (GTP-U, PFCP-UPF — added as secondary IP)"
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
    err "  --iface NAME    Force network interface (default: auto-detect from LM IP)"
    err "  --debug         Enable debug logging"
    exit 1
fi

if [ "$CP_IP" = "$UPF_IP" ]; then
    err "--cp-ip and --upf-ip must be different IPs (PFCP port 8805 conflict)"
    exit 1
fi

# Derive instance name and compose project from TRX IP (naming only)
INSTANCE_NAME="trx-${TRX_IP}"
COMPOSE_PROJECT="${INSTANCE_NAME//./-}"    # dots → dashes for compose project
CONTAINER_NAME="open5gs_${TRX_IP}"

# Derive unique TUN device from last octet of TRX IP
TUN_SUFFIX="${TRX_IP##*.}"
TUN_DEV="ogstun${TUN_SUFFIX}"

# ── Detect network interface using LM IP ─────────────────────
if [ -n "$IFACE_OVERRIDE" ]; then
    PARENT_IFACE="$IFACE_OVERRIDE"
    log "Using user-specified interface: ${PARENT_IFACE}"
else
    # Find the interface that has the LM IP assigned
    PARENT_IFACE=$(find_interface_by_ip "$LM_IP")

    if [ -z "$PARENT_IFACE" ]; then
        log "LM IP ${LM_IP} not found on any interface, trying route-based detection..."
        PARENT_IFACE=$(detect_interface "$LM_IP")
        case "$PARENT_IFACE" in
            lo|mac-*|docker*|veth*|virbr*|"")
                log "Route-based detection returned '${PARENT_IFACE:-nothing}', trying smart detection..."
                PARENT_IFACE=$(detect_physical_interface)
                ;;
        esac
    fi

    [ -n "$PARENT_IFACE" ] && log "Detected interface from LM IP (${LM_IP}): ${PARENT_IFACE}"
fi

if [ -z "$PARENT_IFACE" ]; then
    err "Cannot determine network interface from LM IP ${LM_IP}"
    err "Available interfaces:"
    ip -4 -br addr show | while read -r line; do err "  $line"; done
    err ""
    err "Use --iface <name> to specify manually, e.g.:"
    err "  ./scripts/start.sh --lm-ip ${LM_IP} --trx-ip ${TRX_IP} --cp-ip ${CP_IP} --upf-ip ${UPF_IP} --iface enp1s0"
    exit 1
fi

HOST_IP=$(get_host_ip "$PARENT_IFACE")
HOST_SUBNET=$(get_interface_subnet "$PARENT_IFACE")
HOST_GW=$(get_interface_gateway "$PARENT_IFACE")
HOST_GW="${HOST_GW:-$HOST_IP}"

if [ -z "$HOST_SUBNET" ]; then
    err "Cannot determine subnet for interface ${PARENT_IFACE}"
    exit 1
fi

# Get subnet prefix for adding secondary IPs
HOST_PREFIX=$(ip -4 addr show "$PARENT_IFACE" | awk '/inet / {split($2,a,"/"); print a[2]; exit}')

# MongoDB — with host networking, containers reach it directly via localhost
MONGO_IP="127.0.0.1"
DB_NAME="open5gs"

LOG_LEVEL="info"
[ "$DEBUG_MODE" = true ] && LOG_LEVEL="debug"

PLMN_DISPLAY=$(IFS=', '; echo "${PLMN_LIST[*]}")

hdr ""
hdr "  Starting CN Instance: ${INSTANCE_NAME}"
hdr "  ─────────────────────────────────"
log "  LM IP:      ${LM_IP}  (management)"
log "  TRX IP:     ${TRX_IP}  (identifier)"
log "  CP IP:      ${CP_IP}  (NGAP:${NGAP_PORT}, SBI, PFCP)"
log "  UPF IP:     ${UPF_IP}  (GTP-U:${GTPU_PORT}, PFCP)"
log "  Container:  ${CONTAINER_NAME}"
log "  Interface:  ${PARENT_IFACE}  (subnet: ${HOST_SUBNET}, mode: host)"
log "  Host IP:    ${HOST_IP}"
log "  MongoDB:    ${MONGO_IP}:27017 (db: ${DB_NAME})"
log "  PLMN:       ${PLMN_DISPLAY}  TAC=${TAC}"
log "  Slice:      SST=${SST} SD=${SD}"
log "  UE Pool:    ${UE_SUBNET} (dev: ${TUN_DEV})"
hdr ""

# ── Generate instance config ─────────────────────────────────
INST_DIR="${PROJECT_DIR}/instances/${INSTANCE_NAME}"
INST_CONFIG="${INST_DIR}/config"
LOG_DIR="/opt/logs/cn/${INSTANCE_NAME}"
mkdir -p "${INST_CONFIG}" "${LOG_DIR}"

# Copy base configs and replace all placeholders in one pass
for f in nrf.yaml scp.yaml amf.yaml smf.yaml upf.yaml ausf.yaml udm.yaml udr.yaml pcf.yaml nssf.yaml bsf.yaml; do
    sed -e "s|__MONGO_HOST__|${MONGO_IP}|g" \
        -e "s|__CP_IP__|${CP_IP}|g" \
        -e "s|__UPF_IP__|${UPF_IP}|g" \
        -e "s|__PFCP_CP_IP__|${CP_IP}|g" \
        -e "s|__PFCP_UPF_IP__|${UPF_IP}|g" \
        -e "s|__UE_SUBNET__|${UE_SUBNET}|g" \
        -e "s|__UE_GW__|${UE_GW}|g" \
        -e "s|__TUN_DEV__|${TUN_DEV}|g" \
        "${PROJECT_DIR}/config/${f}" > "${INST_CONFIG}/${f}"
done

# Copy entrypoint script for container
cp "${PROJECT_DIR}/config/start-all.sh" "${INST_CONFIG}/start-all.sh"
chmod +x "${INST_CONFIG}/start-all.sh"

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

# ── Add secondary IPs to host interface ──────────────────────
log "Adding secondary IPs to ${PARENT_IFACE}..."
if ! ip addr show "$PARENT_IFACE" | grep -q "inet ${CP_IP}/"; then
    ip addr add "${CP_IP}/${HOST_PREFIX}" dev "$PARENT_IFACE" 2>/dev/null || true
    ok "Added ${CP_IP}/${HOST_PREFIX} to ${PARENT_IFACE}"
else
    log "${CP_IP} already on ${PARENT_IFACE}"
fi
if ! ip addr show "$PARENT_IFACE" | grep -q "inet ${UPF_IP}/"; then
    ip addr add "${UPF_IP}/${HOST_PREFIX}" dev "$PARENT_IFACE" 2>/dev/null || true
    ok "Added ${UPF_IP}/${HOST_PREFIX} to ${PARENT_IFACE}"
else
    log "${UPF_IP} already on ${PARENT_IFACE}"
fi

# ── Generate .env for docker-compose ─────────────────────────
ENV_FILE="${INST_DIR}/.env"

cat > "${ENV_FILE}" <<ENVEOF
# Auto-generated for ${INSTANCE_NAME} — used by docker-compose.yaml
INSTANCE_NAME=${INSTANCE_NAME}
CONTAINER_NAME=${CONTAINER_NAME}
IMAGE=${IMAGE}
INST_CONFIG=${INST_CONFIG}
INST_DIR=${INST_DIR}
LOG_DIR=${LOG_DIR}
CP_IP=${CP_IP}
UPF_IP=${UPF_IP}
MONGO_IP=${MONGO_IP}
DB_NAME=${DB_NAME}
TUN_DEV=${TUN_DEV}
ENVEOF

# ── Start the instance ────────────────────────────────────────
log "Starting containers (host networking)..."
docker compose -p "${COMPOSE_PROJECT}" --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/docker-compose.yaml" up -d

log "Waiting for Control Plane (NRF on ${CP_IP}:7777)..."
wait_port "${CP_IP}" 7777 60

# ── Set up host routing for UE traffic ────────────────────────
log "Setting up data plane routing..."
ip route add "${UE_SUBNET}" via "${UPF_IP}" 2>/dev/null || true
iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE
iptables -C FORWARD -s "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -s "${UE_SUBNET}" -j ACCEPT
iptables -C FORWARD -d "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -d "${UE_SUBNET}" -j ACCEPT

# ── Set up SCTP/GTP-U DNAT for external gNB access ───────────
# Detect public IP on default-route interface (e.g., eth0)
# and add DNAT rules so real base stations can reach AMF/UPF
# via the public IP even though NFs bind to internal bridge IPs.
PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
PUBLIC_IP=$(ip -4 addr show "$PUBLIC_IFACE" 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')

if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$CP_IP" ] && [ "$PUBLIC_IP" != "$UPF_IP" ]; then
    log "Setting up DNAT for external gNB access (${PUBLIC_IP} → ${CP_IP}/${UPF_IP})..."

    # SCTP DNAT: public_ip:38412 → cp_ip:38412 (NGAP/N2)
    iptables -t nat -C PREROUTING -i "$PUBLIC_IFACE" -p sctp --dport "${NGAP_PORT}" \
        -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$PUBLIC_IFACE" -p sctp --dport "${NGAP_PORT}" \
            -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}"
    ok "SCTP DNAT: ${PUBLIC_IP}:${NGAP_PORT} → ${CP_IP}:${NGAP_PORT}"

    # GTP-U DNAT: public_ip:2152 → upf_ip:2152 (N3)
    iptables -t nat -C PREROUTING -i "$PUBLIC_IFACE" -p udp --dport "${GTPU_PORT}" \
        -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$PUBLIC_IFACE" -p udp --dport "${GTPU_PORT}" \
            -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
    ok "GTP-U DNAT: ${PUBLIC_IP}:${GTPU_PORT} → ${UPF_IP}:${GTPU_PORT}"

    # FORWARD rules for DNATed traffic
    iptables -C FORWARD -p sctp --dport "${NGAP_PORT}" -d "${CP_IP}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -p sctp --dport "${NGAP_PORT}" -d "${CP_IP}" -j ACCEPT
    iptables -C FORWARD -p udp --dport "${GTPU_PORT}" -d "${UPF_IP}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -p udp --dport "${GTPU_PORT}" -d "${UPF_IP}" -j ACCEPT

    # OUTPUT DNAT for local SCTP testing (e.g., sctp_test.py from same host)
    iptables -t nat -C OUTPUT -p sctp -d "${PUBLIC_IP}" --dport "${NGAP_PORT}" \
        -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}" 2>/dev/null || \
        iptables -t nat -A OUTPUT -p sctp -d "${PUBLIC_IP}" --dport "${NGAP_PORT}" \
            -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}"

    ok "External gNB access ready via ${PUBLIC_IP}"
else
    log "CP/UPF IPs on public interface — no DNAT needed"
fi

# ── Save instance metadata ────────────────────────────────────
cat > "${INST_DIR}/metadata.env" <<METAEOF
LM_IP=${LM_IP}
TRX_IP=${TRX_IP}
CP_IP=${CP_IP}
UPF_IP=${UPF_IP}
CONTAINER_NAME=${CONTAINER_NAME}
LOG_DIR=${LOG_DIR}
PARENT_IFACE=${PARENT_IFACE}
HOST_PREFIX=${HOST_PREFIX}
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
TUN_DEV=${TUN_DEV}
PUBLIC_IP=${PUBLIC_IP:-}
PUBLIC_IFACE=${PUBLIC_IFACE:-}
METAEOF

hdr ""
hdr "  ========================================="
hdr "  CN Instance ${INSTANCE_NAME} is RUNNING"
hdr "  ========================================="
hdr ""
hdr "  ── gNB connection endpoints ──"
if [ -n "${PUBLIC_IP:-}" ] && [ "$PUBLIC_IP" != "$CP_IP" ]; then
    log "    External gNB:  ${PUBLIC_IP}:${NGAP_PORT} (SCTP) / ${PUBLIC_IP}:${GTPU_PORT} (GTP-U)"
    log "    Internal gNB:  ${CP_IP}:${NGAP_PORT} (SCTP) / ${UPF_IP}:${GTPU_PORT} (GTP-U)"
else
    log "    NGAP/SCTP: ${CP_IP}:${NGAP_PORT}"
    log "    GTP-U/UDP: ${UPF_IP}:${GTPU_PORT}"
fi
hdr ""
log "  Container: ${CONTAINER_NAME}"
log "  PLMN:   ${PLMN_DISPLAY}  TAC=${TAC}"
log "  Slice:  SST=${SST} SD=${SD}"
log "  UE:     ${UE_SUBNET}"
log "  DB:     mongodb://${MONGO_IP}/${DB_NAME}"
hdr ""
log "  Provision: ./scripts/provision.sh [--count N]"
log "  Status:    ./scripts/status.sh [--trx-ip ${TRX_IP}]"
log "  Logs:      ./scripts/logs.sh --trx-ip ${TRX_IP} [nf]"
log "  Stop:      ./scripts/stop.sh --trx-ip ${TRX_IP}"
hdr ""
