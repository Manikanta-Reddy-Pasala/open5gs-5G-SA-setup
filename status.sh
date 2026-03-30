#!/bin/bash
# ============================================================
# status.sh — Show status of CN instances
# ============================================================
# Usage:
#   ./status.sh              # Show all instances
#   ./status.sh --id 1       # Show specific instance
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

INSTANCE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id) INSTANCE_ID="$2"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

show_instance() {
    local id="$1"
    local name="bts${id}"
    local cp_ip=$(instance_cp_ip "$id")
    local upf_ip=$(instance_upf_ip "$id")
    local subnet=$(instance_network "$id")
    local ue_subnet="10.$((205 + id)).0.0/16"
    local webui_port=$((4000 + id))
    local mongo_ip=$(get_host_mongo_ip)
    local db_name="open5gs"
    local host_ip=$(hostname -I | awk '{print $1}')
    local bts_ip=$(instance_bts_ip "$id")

    hdr ""
    hdr "  ═══ Instance: ${name} ═══"
    hdr ""

    echo "${BOLD}Containers:${NC}"
    local all_ok=true
    for cname in "${name}-cp" "${name}-upf" "${name}-webui"; do
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
        local health=""
        health=$(docker inspect --format='{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$cname" 2>/dev/null || true)
        if [ "$state" = "running" ]; then
            printf "  ${GREEN}✓${NC} %-25s %s%s\n" "$cname" "$state" "$health"
        else
            printf "  ${RED}✗${NC} %-25s %s\n" "$cname" "$state"
            all_ok=false
        fi
    done

    echo ""
    echo "${BOLD}External BTS Access (IP-based routing):${NC}"
    log "  NGAP/SCTP: ${bts_ip}:${NGAP_PORT}"
    log "  GTP-U/UDP: ${bts_ip}:${GTPU_PORT}"
    log "  WebUI:     http://${host_ip}:${webui_port}"

    echo ""
    echo "${BOLD}Internal (Docker bridge):${NC}"
    log "  Subnet:     ${subnet}"
    log "  AMF (NGAP): ${cp_ip}:${NGAP_PORT}"
    log "  UPF (GTPU): ${upf_ip}:${GTPU_PORT}"
    log "  UE Pool:    ${ue_subnet}"

    echo ""
    echo "${BOLD}NRF Registrations:${NC}"
    local nrf_output
    nrf_output=$(curl -s --max-time 3 --http2-prior-knowledge \
        "http://${cp_ip}:7777/nnrf-nfm/v1/nf-instances" 2>/dev/null || echo "")
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
        ok "NRF reachable - ${nf_count} NFs registered"
    else
        warn "NRF not reachable"
    fi

    echo ""
    echo "${BOLD}Subscribers:${NC}"
    local sub_count
    sub_count=$(mongosh "mongodb://localhost:27017/open5gs" --quiet \
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
hdr "  open5GS Multi-BTS Status"
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

if [ -n "$INSTANCE_ID" ]; then
    show_instance "$INSTANCE_ID"
else
    # Show all instances
    if [ -d "${SCRIPT_DIR}/instances" ]; then
        for inst_dir in "${SCRIPT_DIR}/instances"/bts*; do
            [ -d "$inst_dir" ] || continue
            id="${inst_dir##*bts}"
            show_instance "$id"
        done
    else
        log "No instances running. Start one: ./start.sh --id 1"
    fi
fi

hdr ""
