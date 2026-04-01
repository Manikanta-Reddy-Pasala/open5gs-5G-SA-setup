#!/bin/bash
# ============================================================
# logs.sh — Tail logs for a CN instance
# ============================================================
# Usage:
#   ./scripts/logs.sh --id 1           # All container logs
#   ./scripts/logs.sh --id 1 amf       # AMF log only
#   ./scripts/logs.sh --id 1 upf       # UPF log only
#
# Logs stored at: /opt/logs/cn/bts{N}/{nf}.log
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

INSTANCE_ID=""
NF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id) INSTANCE_ID="$2"; shift ;;
        *)    NF="$1" ;;
    esac
    shift
done

if [ -z "$INSTANCE_ID" ]; then
    err "Usage: ./scripts/logs.sh --id <number> [nf]"
    exit 1
fi

INSTANCE_NAME="bts${INSTANCE_ID}"
LOG_DIR="/opt/logs/cn/${INSTANCE_NAME}"
INST_DIR="${PROJECT_DIR}/instances/${INSTANCE_NAME}"
ENV_FILE="${INST_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"

compose_cmd() {
    if [ -f "$ENV_FILE" ]; then
        docker compose -p "${INSTANCE_NAME}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
    else
        docker compose -p "${INSTANCE_NAME}" -f "${COMPOSE_FILE}" "$@"
    fi
}

if [ -z "$NF" ]; then
    compose_cmd logs -f --tail=50
else
    local_log="${LOG_DIR}/${NF}.log"
    if [ -f "$local_log" ]; then
        tail -f "$local_log"
    else
        docker exec "${INSTANCE_NAME}" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
            err "Log not found: ${local_log}"
    fi
fi
