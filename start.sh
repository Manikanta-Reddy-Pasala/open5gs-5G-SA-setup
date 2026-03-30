#!/bin/bash
# ============================================================
# start.sh — Start a CN (Core Network) instance for a BTS
# ============================================================
# Usage:
#   ./start.sh --id 1                          # Start CN instance 1 (auto IPs)
#   ./start.sh --id 2 --mcc 404 --mnc 30      # Custom PLMN
#   ./start.sh --id 3 --debug                  # Debug logging
#   ./start.sh --id 1 --webui-port 4001        # Custom WebUI port
#
# Each instance gets:
#   - Docker bridge:  10.200.<ID>.0/24  (CP=.16, UPF=.17)
#   - BTS-facing IP:  10.0.0.<90+ID>    (standard ports 38412/2152)
#   - Shared host MongoDB (db: open5gs)
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

# ── Parse arguments ──────────────────────────────────────────
INSTANCE_ID=""
MCC="$DEFAULT_MCC"
MNC="$DEFAULT_MNC"
TAC="$DEFAULT_TAC"
SST="$DEFAULT_SST"
SD="$DEFAULT_SD"
DNN="$DEFAULT_DNN"
DEBUG_MODE=false
WEBUI_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)       INSTANCE_ID="$2"; shift ;;
        --mcc)      MCC="$2"; shift ;;
        --mnc)      MNC="$2"; shift ;;
        --tac)      TAC="$2"; shift ;;
        --sst)      SST="$2"; shift ;;
        --sd)       SD="$2"; shift ;;
        --dnn)      DNN="$2"; shift ;;
        --debug)    DEBUG_MODE=true ;;
        --webui-port) WEBUI_PORT="$2"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$INSTANCE_ID" ]; then
    err "Usage: ./start.sh --id <number> [--mcc X --mnc Y --tac Z] [--debug]"
    exit 1
fi

# ── Derive network config ───────────────────────────────────
SUBNET=$(instance_network "$INSTANCE_ID")
CP_IP=$(instance_cp_ip "$INSTANCE_ID")
UPF_IP=$(instance_upf_ip "$INSTANCE_ID")
GW_IP=$(instance_gateway "$INSTANCE_ID")
MONGO_IP=$(get_host_mongo_ip)
DB_NAME="open5gs"
INSTANCE_NAME="bts${INSTANCE_ID}"
COMPOSE_PROJECT="bts${INSTANCE_ID}"
WEBUI_PORT="${WEBUI_PORT:-$((4000 + INSTANCE_ID))}"

# BTS-facing IP (unique per instance, standard ports)
BTS_IP=$(instance_bts_ip "$INSTANCE_ID")  # bts1=10.0.0.91, bts2=10.0.0.92, ...
HOST_IP=$(hostname -I | awk '{print $1}')

LOG_LEVEL="info"
[ "$DEBUG_MODE" = true ] && LOG_LEVEL="debug"

UE_SUBNET="10.$((205 + INSTANCE_ID)).0.0/16"
UE_GW="10.$((205 + INSTANCE_ID)).0.1"

hdr ""
hdr "  Starting CN Instance: ${INSTANCE_NAME}"
hdr "  ─────────────────────────────────"
log "  BTS IP:     ${BTS_IP}  (NGAP:${NGAP_PORT} / GTP-U:${GTPU_PORT})"
log "  Docker net: ${SUBNET}  (CP:${CP_IP} / UPF:${UPF_IP})"
log "  MongoDB:    ${MONGO_IP}:27017 (db: ${DB_NAME})"
log "  PLMN:       MCC=${MCC} MNC=${MNC} TAC=${TAC}"
log "  Slice:      SST=${SST} SD=${SD}"
log "  WebUI:      http://${HOST_IP}:${WEBUI_PORT}"
log "  UE Pool:    ${UE_SUBNET}"
hdr ""

# ── Generate instance config ────────────────────────────────
INST_DIR="${SCRIPT_DIR}/instances/${INSTANCE_NAME}"
INST_CONFIG="${INST_DIR}/config"
mkdir -p "${INST_CONFIG}" "${INST_DIR}/logs/cp" "${INST_DIR}/logs/upf"

# Copy base configs and patch them
cp config/nrf.yaml   "${INST_CONFIG}/"
cp config/scp.yaml   "${INST_CONFIG}/"
cp config/amf.yaml   "${INST_CONFIG}/"
cp config/smf.yaml   "${INST_CONFIG}/"
cp config/upf.yaml   "${INST_CONFIG}/"
cp config/ausf.yaml  "${INST_CONFIG}/"
cp config/udm.yaml   "${INST_CONFIG}/"
cp config/udr.yaml   "${INST_CONFIG}/"
cp config/pcf.yaml   "${INST_CONFIG}/"
cp config/nssf.yaml  "${INST_CONFIG}/"
cp config/bsf.yaml   "${INST_CONFIG}/"

# Patch MongoDB URI — single shared database for all instances
for f in nrf.yaml bsf.yaml pcf.yaml udr.yaml; do
    sed -i "s|db_uri:.*|db_uri: mongodb://${MONGO_IP}/${DB_NAME}|" "${INST_CONFIG}/${f}"
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

# Patch SMF PFCP addresses (CP and UPF IPs are per-instance)
python3 - "${INST_CONFIG}/smf.yaml" "$CP_IP" "$UPF_IP" "$UE_SUBNET" "$UE_GW" <<'PYEOF'
import sys
cfg_file, cp_ip, upf_ip, ue_subnet, ue_gw = sys.argv[1:6]
with open(cfg_file) as f:
    content = f.read()
content = content.replace('address: 10.200.100.16', f'address: {cp_ip}', 1)
content = content.replace('address: 10.200.100.17', f'address: {upf_ip}', 1)
content = content.replace('10.206.0.0/16', ue_subnet)
content = content.replace('10.206.0.1', ue_gw)
with open(cfg_file, 'w') as f:
    f.write(content)
PYEOF

# Patch UPF config (bind to instance UPF IP)
python3 - "${INST_CONFIG}/upf.yaml" "$UPF_IP" "$UE_SUBNET" "$UE_GW" <<'PYEOF'
import sys
cfg_file, upf_ip, ue_subnet, ue_gw = sys.argv[1:5]
with open(cfg_file) as f:
    content = f.read()
content = content.replace('10.200.100.17', upf_ip)
content = content.replace('10.206.0.0/16', ue_subnet)
content = content.replace('10.206.0.1', ue_gw)
with open(cfg_file, 'w') as f:
    f.write(content)
PYEOF

# ── Generate docker-compose for this instance ───────────────
COMPOSE_FILE="${INST_DIR}/docker-compose.yaml"

cat > "${COMPOSE_FILE}" <<COMPEOF
# Auto-generated for ${INSTANCE_NAME}
services:

  cp:
    container_name: ${INSTANCE_NAME}-cp
    image: open5gs-cp-local:${OPEN5GS_VERSION}
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
      - ${SCRIPT_DIR}/consolidated/start-cp-nfs.sh:/open5gs/start-cp-nfs.sh
      - ${INST_DIR}/logs/cp:/var/log/open5gs
    environment:
      DB_URI: mongodb://${MONGO_IP}/${DB_NAME}
    networks:
      cn-net:
        ipv4_address: ${CP_IP}
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
    image: open5gs-upf-local:${OPEN5GS_VERSION}
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

  webui:
    container_name: ${INSTANCE_NAME}-webui
    image: open5gs-webui-local:${OPEN5GS_VERSION}
    environment:
      DB_URI: mongodb://${MONGO_IP}/${DB_NAME}
      NEXTAUTH_URL: http://localhost:9999
      NEXTAUTH_SECRET: open5gs-secret-key
      NODE_ENV: production
    ports:
      - "${WEBUI_PORT}:9999"
    networks:
      cn-net:
        aliases:
          - webui.open5gs.org
    extra_hosts:
      - "mongohost:${MONGO_IP}"

networks:
  cn-net:
    name: ${INSTANCE_NAME}-net
    ipam:
      driver: default
      config:
        - subnet: ${SUBNET}
    driver_opts:
      com.docker.network.bridge.name: br-${INSTANCE_NAME}
COMPEOF

# ── Start the instance ──────────────────────────────────────
log "Starting containers..."
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d

log "Waiting for Control Plane (NRF on ${CP_IP}:7777)..."
wait_port "${CP_IP}" 7777 60

# ── Set up host routing for UE traffic ──────────────────────
log "Setting up data plane routing..."
ip route add "${UE_SUBNET}" via "${UPF_IP}" 2>/dev/null || true
iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" -j MASQUERADE
iptables -C FORWARD -s "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -s "${UE_SUBNET}" -j ACCEPT
iptables -C FORWARD -d "${UE_SUBNET}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -d "${UE_SUBNET}" -j ACCEPT

# ── Set up BTS IP on dummy interface ─────────────────────────
log "Setting up BTS IP ${BTS_IP} on ${BTS_IFACE}..."
ensure_bts_iface
ip addr add "${BTS_IP}/32" dev "${BTS_IFACE}" 2>/dev/null || true

# ── DNAT: BTS_IP:38412 → CP, BTS_IP:2152 → UPF ────────────
modprobe sctp 2>/dev/null || true

log "  NGAP: ${BTS_IP}:${NGAP_PORT} → ${CP_IP}:${NGAP_PORT}"
iptables -t nat -A PREROUTING -d "${BTS_IP}" -p sctp --dport "${NGAP_PORT}" -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}"
iptables -t nat -A OUTPUT     -d "${BTS_IP}" -p sctp --dport "${NGAP_PORT}" -j DNAT --to-destination "${CP_IP}:${NGAP_PORT}"
iptables -A FORWARD -p sctp -d "${CP_IP}" --dport "${NGAP_PORT}" -j ACCEPT
iptables -A FORWARD -p sctp -s "${CP_IP}" --sport "${NGAP_PORT}" -j ACCEPT

log "  GTPU: ${BTS_IP}:${GTPU_PORT} → ${UPF_IP}:${GTPU_PORT}"
iptables -t nat -A PREROUTING -d "${BTS_IP}" -p udp --dport "${GTPU_PORT}" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
iptables -t nat -A OUTPUT     -d "${BTS_IP}" -p udp --dport "${GTPU_PORT}" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
iptables -I FORWARD 1 -p udp -d "${UPF_IP}" --dport "${GTPU_PORT}" -j ACCEPT
iptables -I FORWARD 1 -p udp -s "${UPF_IP}" --sport "${GTPU_PORT}" -j ACCEPT

hdr ""
hdr "  ========================================="
hdr "  CN Instance ${INSTANCE_NAME} is RUNNING"
hdr "  ========================================="
hdr ""
hdr "  ── BTS connects to (same ports, different IPs) ──"
log "    NGAP/SCTP: ${BTS_IP}:${NGAP_PORT}"
log "    GTP-U/UDP: ${BTS_IP}:${GTPU_PORT}"
hdr ""
hdr "  ── Internal (Docker bridge) ──"
log "    AMF:  ${CP_IP}:${NGAP_PORT}"
log "    UPF:  ${UPF_IP}:${GTPU_PORT}"
log "    NRF:  http://${CP_IP}:7777"
hdr ""
log "  WebUI:  http://${HOST_IP}:${WEBUI_PORT}  (admin / 1423)"
log "  PLMN:   MCC=${MCC} MNC=${MNC} TAC=${TAC}"
log "  Slice:  SST=${SST} SD=${SD}"
log "  UE:     ${UE_SUBNET}"
log "  DB:     mongodb://${MONGO_IP}/${DB_NAME}"
hdr ""
log "  Provision: ./provision.sh [--count N]"
log "  Status:    ./status.sh [--id ${INSTANCE_ID}]"
log "  Logs:      ./logs.sh --id ${INSTANCE_ID} [nf]"
log "  Stop:      ./stop.sh --id ${INSTANCE_ID}"
hdr ""
