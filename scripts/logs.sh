#!/bin/bash
# ============================================================
# logs.sh — Tail logs for a CN instance
# ============================================================
# Usage:
#   ./scripts/logs.sh --trx-ip 10.100.0.11           # All container logs
#   ./scripts/logs.sh --trx-ip 10.100.0.11 amf       # AMF log only
#   ./scripts/logs.sh --trx-ip 10.100.0.11 upf       # UPF log only
#
# Logs stored at: /opt/logs/cn/trx-<IP>/{nf}.log
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

TRX_IP=""
NF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trx-ip) TRX_IP="$2"; shift ;;
        *)        NF="$1" ;;
    esac
    shift
done

if [ -z "$TRX_IP" ]; then
    err "Usage: ./scripts/logs.sh --trx-ip <IP> [nf]"
    exit 1
fi

INSTANCE_NAME="trx-${TRX_IP}"
LOG_DIR="/opt/logs/cn/${INSTANCE_NAME}"
INST_DIR="${PROJECT_DIR}/instances/${INSTANCE_NAME}"
ENV_FILE="${INST_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"
COMPOSE_PROJECT="${INSTANCE_NAME//./-}"

compose_cmd() {
    if [ -f "$ENV_FILE" ]; then
        docker compose -p "${COMPOSE_PROJECT}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
    else
        docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" "$@"
    fi
}

if [ -z "$NF" ]; then
    compose_cmd logs -f --tail=50
else
    local_log="${LOG_DIR}/${NF}.log"
    if [ -f "$local_log" ]; then
        tail -f "$local_log"
    else
        docker exec "open5gs_${TRX_IP}" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
            err "Log not found: ${local_log}"
    fi
fi
