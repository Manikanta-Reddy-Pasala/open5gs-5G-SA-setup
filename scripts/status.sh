#!/bin/bash
# ============================================================
# status.sh — Show status of CN instances
# ============================================================
# Usage:
#   ./scripts/status.sh                       # Show all instances
#   ./scripts/status.sh --trx-ip 10.100.0.11  # Show specific instance
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

TRX_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trx-ip) TRX_IP="$2"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

show_instance() {
    local name="$1"
    local inst_dir="${PROJECT_DIR}/instances/${name}"
    local metadata="${inst_dir}/metadata.env"

    if [ ! -f "$metadata" ]; then
        warn "Instance ${name} not found (no metadata.env)"
        return
    fi

    source "$metadata"
    local trx_ip="${TRX_IP:-?}"
    local ng_ip="${NG_IP:-?}"
    local host_ip="${HOST_IP:-?}"
    local parent_iface="${PARENT_IFACE:-?}"
    local ue_subnet="${UE_SUBNET:-?}"
    local mongo_ip="${MONGO_IP:-?}"
    local db_name="${DB_NAME:-open5gs}"
    local container_name="${CONTAINER_NAME:-${name}}"

    hdr ""
    hdr "  ═══ Instance: ${name} ═══"
    hdr ""

    echo "${BOLD}Container:${NC}"
    local all_ok=true
    local state
    state=$(docker inspect --format='{{.State.Status}}' "${container_name}" 2>/dev/null || echo "not found")
    local health=""
    health=$(docker inspect --format='{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "${container_name}" 2>/dev/null || true)
    if [ "$state" = "running" ]; then
        printf "  ${GREEN}✓${NC} %-25s %s%s\n" "${container_name}" "$state" "$health"
    else
        printf "  ${RED}✗${NC} %-25s %s\n" "${container_name}" "$state"
        all_ok=false
    fi

    echo ""
    echo "${BOLD}Network (host on ${parent_iface}):${NC}"
    log "  TRX/NGAP:  ${trx_ip}:${NGAP_PORT}"
    log "  NG/GTPU:   ${ng_ip}:${GTPU_PORT}"
    log "  UE Pool:   ${ue_subnet}"

    echo ""
    echo "${BOLD}NRF Registrations:${NC}"
    local nrf_output
    nrf_output=$(curl -s --max-time 3 --http2-prior-knowledge \
        "http://${trx_ip}:7777/nnrf-nfm/v1/nf-instances" 2>/dev/null || echo "")
    if [ -n "$nrf_output" ]; then
        local nf_count
        nf_count=$(echo "$nrf_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    items = data.get('_links', {}).get('items', data.get('_links', {}).get('item', []))
    print(data.get('totalItemCount', len(items)))
except:
    print('?')
" 2>/dev/null || echo "?")
        ok "NRF reachable — ${nf_count} NFs registered"
    else
        warn "NRF not reachable at ${trx_ip}:7777"
    fi

    echo ""
    echo "${BOLD}Subscribers:${NC}"
    local sub_count
    sub_count=$(mongosh "mongodb://localhost:27017/${db_name}" --quiet \
        --eval "db.subscribers.countDocuments()" 2>/dev/null | tail -1 || echo "0")
    log "  Total: ${sub_count}"

    echo ""
    if [ "$all_ok" = true ]; then
        ok "Instance ${name} is UP"
    else
        warn "Some containers not running"
    fi
}

# ── Main ─────────────────────────────────────────────────────
hdr ""
hdr "  ========================================="
hdr "  open5GS Multi-TRX Status"
hdr "  ========================================="

# MongoDB host status
echo ""
echo "${BOLD}Host MongoDB:${NC}"
if mongosh --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q 1; then
    ok "MongoDB running on host"
    local_dbs=$(mongosh --quiet --eval "db.adminCommand('listDatabases').databases.filter(d=>d.name.startsWith('open5gs')).map(d=>d.name).join(', ')" 2>/dev/null || echo "")
    [ -n "$local_dbs" ] && log "  Databases: ${local_dbs}"
else
    err "MongoDB NOT running on host!"
fi

if [ -n "$TRX_IP" ]; then
    show_instance "trx-${TRX_IP}"
else
    # Show all instances
    if [ -d "${PROJECT_DIR}/instances" ]; then
        for inst_dir in "${PROJECT_DIR}/instances"/trx-*; do
            [ -d "$inst_dir" ] || continue
            name="$(basename "$inst_dir")"
            show_instance "$name"
        done
    else
        log "No instances running. Start one: ./scripts/start.sh --lm-ip <IP> --trx-ip <IP> --ng-ip <IP>"
    fi
fi

hdr ""
