#!/bin/bash
# ============================================================
# start.sh — Start a CN (Core Network) instance for a BTS
# ============================================================
# Usage:
#   ./scripts/start.sh --id 1 --amf-ip 192.168.1.153 --upf-ip 192.168.1.154
#   ./scripts/start.sh --id 2 --amf-ip 192.168.1.155 --upf-ip 192.168.1.156 --mcc 404 --mnc 30
#   ./scripts/start.sh --id 1 --amf-ip 10.0.0.153 --upf-ip 10.0.0.154 --debug
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
MCC="$DEFAULT_MCC"
MNC="$DEFAULT_MNC"
TAC="$DEFAULT_TAC"
SST="$DEFAULT_SST"
SD="$DEFAULT_SD"
DNN="$DEFAULT_DNN"
UE_SUBNET="$DEFAULT_UE_SUBNET"
UE_GW="$DEFAULT_UE_GW"
DEBUG_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)        INSTANCE_ID="$2"; shift ;;
        --amf-ip)    AMF_IP="$2"; shift ;;
        --upf-ip)    UPF_IP="$2"; shift ;;
        --mcc)       MCC="$2"; shift ;;
        --mnc)       MNC="$2"; shift ;;
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

if [ -z "$INSTANCE_ID" ] || [ -z "$AMF_IP" ] || [ -z "$UPF_IP" ]; then
    err "Usage: ./scripts/start.sh --id <N> --amf-ip <IP> --upf-ip <IP> [options]"
    err ""
    err "Required:"
    err "  --id N          Instance number (1, 2, 3, ...)"
    err "  --amf-ip IP     AMF/CP IP address (on host network)"
    err "  --upf-ip IP     UPF IP address (on host network)"
    err ""
    err "Optional:"
    err "  --mcc X         MCC (default: ${DEFAULT_MCC})"
    err "  --mnc Y         MNC (default: ${DEFAULT_MNC})"
    err "  --tac Z         TAC (default: ${DEFAULT_TAC})"
    err "  --sst S         SST (default: ${DEFAULT_SST})"
    err "  --sd SD         SD (default: ${DEFAULT_SD})"
    err "  --dnn D         DNN (default: ${DEFAULT_DNN})"
    err "  --ue-subnet X   UE pool subnet (default: ${DEFAULT_UE_SUBNET})"
    err "  --ue-gw X       UE pool gateway (default: ${DEFAULT_UE_GW})"
    err "  --debug         Enable debug logging"
    exit 1
fi

# ── Auto-detect network config ────────────────────────────────
PARENT_IFACE=$(detect_interface "$AMF_IP")
if [ -z "$PARENT_IFACE" ]; then
    err "Cannot determine network interface for AMF IP ${AMF_IP}"
    err "Ensure the IP is on a reachable subnet of this host"
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

hdr ""
hdr "  Starting CN Instance: ${INSTANCE_NAME}"
hdr "  ─────────────────────────────────"
log "  AMF IP:     ${AMF_IP}  (NGAP:${NGAP_PORT})"
log "  UPF IP:     ${UPF_IP}  (GTP-U:${GTPU_PORT})"
log "  Interface:  ${PARENT_IFACE}  (subnet: ${HOST_SUBNET})"
log "  Host IP:    ${HOST_IP}"
log "  MongoDB:    ${MONGO_IP}:27017 (db: ${DB_NAME})"
log "  PLMN:       MCC=${MCC} MNC=${MNC} TAC=${TAC}"
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

# Patch PLMN in AMF
python3 - "${INST_CONFIG}/amf.yaml" "$MCC" "$MNC" "$TAC" "$SST" "$SD" <<'PYEOF'
import sys, re
cfg_file, mcc, mnc, tac, sst, sd = sys.argv[1:7]
with open(cfg_file) as f:
    content = f.read()
content = re.sub(r'mcc: \d+', f'mcc: {mcc}', content)
content = re.sub(r'mnc: \d+', f'mnc: {mnc}', content)
content = re.sub(r'tac: \d+', f'tac: {tac}', content)
content = re.sub(r'sst: \d+', f'sst: {sst}', content)
content = re.sub(r'sd: [0-9a-fA-F]+', f'sd: {sd}', content)
with open(cfg_file, 'w') as f:
    f.write(content)
PYEOF

# Patch slice in SMF
sed -i "s/sst: [0-9]*/sst: ${SST}/g" "${INST_CONFIG}/smf.yaml"
sed -i "s/sd: [0-9a-fA-F]*/sd: ${SD}/g" "${INST_CONFIG}/smf.yaml"

# Patch slice in NSSF
sed -i "s/sst: [0-9]*/sst: ${SST}/g" "${INST_CONFIG}/nssf.yaml"
sed -i "s/sd: [0-9a-fA-F]*/sd: ${SD}/g" "${INST_CONFIG}/nssf.yaml"

# ── Create macvlan network ────────────────────────────────────
log "Creating macvlan network on ${PARENT_IFACE}..."
create_macvlan_network "$INSTANCE_ID" "$PARENT_IFACE" "$HOST_SUBNET" "$HOST_GW"

# Host-side macvlan shim for host<->container communication
log "Creating macvlan shim for host access..."
create_macvlan_shim "$INSTANCE_ID" "$PARENT_IFACE" "$AMF_IP" "$UPF_IP"

# ── Generate docker-compose for this instance ─────────────────
COMPOSE_FILE="${INST_DIR}/docker-compose.yaml"

cat > "${COMPOSE_FILE}" <<COMPEOF
# Auto-generated for ${INSTANCE_NAME}
services:

  cp:
    container_name: ${INSTANCE_NAME}-cp
    image: ${IMAGE_CP}
    volumes:
      - ${INST_CONFIG}/nrf.yaml:/etc/open5gs/nrf.yaml
      - ${INST_CONFIG}/scp.yaml:/etc/open5gs/scp.yaml
      - ${INST_CONFIG}/amf.yaml:/etc/open5gs/amf.yaml
      - ${INST_CONFIG}/smf.yaml:/etc/open5gs/smf.yaml
      - ${INST_CONFIG}/ausf.yaml:/etc/open5gs/ausf.yaml
      - ${INST_CONFIG}/udm.yaml:/etc/open5gs/udm.yaml
      - ${INST_CONFIG}/udr.yaml:/etc/open5gs/udr.yaml
      - ${INST_CONFIG}/pcf.yaml:/etc/open5gs/pcf.yaml
      - ${INST_CONFIG}/nssf.yaml:/etc/open5gs/nssf.yaml
      - ${INST_CONFIG}/bsf.yaml:/etc/open5gs/bsf.yaml
      - ${INST_DIR}/logs/cp:/var/log/open5gs
    environment:
      DB_URI: mongodb://${MONGO_IP}/${DB_NAME}
    networks:
      cn-net:
        ipv4_address: ${AMF_IP}
        aliases:
          - nrf.open5gs.org
          - scp.open5gs.org
          - amf.open5gs.org
          - smf.open5gs.org
          - ausf.open5gs.org
          - udm.open5gs.org
          - udr.open5gs.org
          - pcf.open5gs.org
          - nssf.open5gs.org
          - bsf.open5gs.org
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/7777 && echo ok"]
      interval: 1s
      timeout: 1s
      start_period: 1s
      retries: 60
    extra_hosts:
      - "mongohost:${MONGO_IP}"

  upf:
    container_name: ${INSTANCE_NAME}-upf
    image: ${IMAGE_UPF}
    volumes:
      - ${INST_CONFIG}/upf.yaml:/etc/open5gs/upf.yaml
      - ${INST_DIR}/logs/upf:/var/log/open5gs
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - "/dev/net/tun"
    networks:
      cn-net:
        ipv4_address: ${UPF_IP}
        aliases:
          - upf.open5gs.org
    depends_on:
      cp:
        condition: service_started

networks:
  cn-net:
    external: true
    name: ${INSTANCE_NAME}-net
COMPEOF

# ── Start the instance ────────────────────────────────────────
log "Starting containers..."
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d

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
MCC=${MCC}
MNC=${MNC}
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
log "  PLMN:   MCC=${MCC} MNC=${MNC} TAC=${TAC}"
log "  Slice:  SST=${SST} SD=${SD}"
log "  UE:     ${UE_SUBNET}"
log "  DB:     mongodb://${MONGO_IP}/${DB_NAME}"
hdr ""
log "  Provision: ./scripts/provision.sh [--count N]"
log "  Status:    ./scripts/status.sh [--id ${INSTANCE_ID}]"
log "  Logs:      ./scripts/logs.sh --id ${INSTANCE_ID} [nf]"
log "  Stop:      ./scripts/stop.sh --id ${INSTANCE_ID}"
hdr ""
