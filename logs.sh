#!/bin/bash
# ============================================================
# logs.sh — Tail logs for a CN instance
# ============================================================
# Usage:
#   ./logs.sh --id 1           # All container logs
#   ./logs.sh --id 1 amf       # AMF log only
#   ./logs.sh --id 1 upf       # UPF log only
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

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
    err "Usage: ./logs.sh --id <number> [nf]"
    exit 1
fi

INSTANCE_NAME="bts${INSTANCE_ID}"
INST_DIR="${SCRIPT_DIR}/instances/${INSTANCE_NAME}"
COMPOSE_FILE="${INST_DIR}/docker-compose.yaml"

if [ -z "$NF" ]; then
    docker compose -p "${INSTANCE_NAME}" -f "${COMPOSE_FILE}" logs -f --tail=50
else
    case "$NF" in
        amf|smf|nrf|scp|ausf|udm|udr|pcf|nssf|bsf)
            docker exec "${INSTANCE_NAME}-cp" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
                docker compose -p "${INSTANCE_NAME}" -f "${COMPOSE_FILE}" logs -f cp
            ;;
        upf)
            docker exec "${INSTANCE_NAME}-upf" tail -f /var/log/open5gs/upf.log 2>/dev/null || \
                docker compose -p "${INSTANCE_NAME}" -f "${COMPOSE_FILE}" logs -f upf
            ;;
        webui)
            docker compose -p "${INSTANCE_NAME}" -f "${COMPOSE_FILE}" logs -f webui
            ;;
        *)
            docker exec "${INSTANCE_NAME}-cp" tail -f "/var/log/open5gs/${NF}.log" 2>/dev/null || \
                err "Unknown NF: ${NF}"
            ;;
    esac
fi
