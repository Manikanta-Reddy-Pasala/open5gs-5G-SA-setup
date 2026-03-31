#!/bin/bash
# ============================================================
# logs.sh — Tail logs for a CN instance
# ============================================================
# Usage:
#   ./scripts/logs.sh --id 1           # All container logs
#   ./scripts/logs.sh --id 1 amf       # AMF log only
#   ./scripts/logs.sh --id 1 upf       # UPF log only
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
    case "$NF" in
        amf|smf|nrf|scp|ausf|udm|udr|pcf|nssf|bsf)
            docker exec "${INSTANCE_NAME}-cp" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
                compose_cmd logs -f cp
            ;;
        upf)
            docker exec "${INSTANCE_NAME}-upf" tail -f /var/log/open5gs/upf.log 2>/dev/null || \
                compose_cmd logs -f upf
            ;;
        *)
            docker exec "${INSTANCE_NAME}-cp" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
                err "Unknown NF: ${NF}"
            ;;
    esac
fi
