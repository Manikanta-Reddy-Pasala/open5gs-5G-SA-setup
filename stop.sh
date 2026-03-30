#!/bin/bash
# ============================================================
# stop.sh — Stop a CN instance (or all)
# ============================================================
# Usage:
#   ./stop.sh --id 1         # Stop instance bts1
#   ./stop.sh --all           # Stop all instances
#   ./stop.sh --id 1 --rm    # Stop and remove containers+network
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

INSTANCE_ID=""
STOP_ALL=false
REMOVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)   INSTANCE_ID="$2"; shift ;;
        --all)  STOP_ALL=true ;;
        --rm)   REMOVE=true ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

stop_instance() {
    local id="$1"
    local name="bts${id}"
    local inst_dir="${SCRIPT_DIR}/instances/${name}"
    local compose_file="${inst_dir}/docker-compose.yaml"

    if [ ! -f "$compose_file" ]; then
        warn "Instance ${name} not found (no compose file)"
        return 1
    fi

    local ue_subnet="10.$((205 + id)).0.0/16"
    local upf_ip=$(instance_upf_ip "$id")
    local cp_ip=$(instance_cp_ip "$id")
    local bts_ip=$(instance_bts_ip "$id")

    if [ "$REMOVE" = true ]; then
        hdr "Removing instance ${name}..."
        docker compose -p "${name}" -f "${compose_file}" down -v --remove-orphans 2>/dev/null || true

        # Cleanup UE routes
        ip route del "${ue_subnet}" via "${upf_ip}" 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s "${ue_subnet}" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -s "${ue_subnet}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -d "${ue_subnet}" -j ACCEPT 2>/dev/null || true

        # Cleanup SCTP DNAT (BTS_IP based)
        iptables -t nat -D PREROUTING -d "${bts_ip}" -p sctp --dport "${NGAP_PORT}" -j DNAT --to-destination "${cp_ip}:${NGAP_PORT}" 2>/dev/null || true
        iptables -t nat -D OUTPUT     -d "${bts_ip}" -p sctp --dport "${NGAP_PORT}" -j DNAT --to-destination "${cp_ip}:${NGAP_PORT}" 2>/dev/null || true
        iptables -D FORWARD -p sctp -d "${cp_ip}" --dport "${NGAP_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p sctp -s "${cp_ip}" --sport "${NGAP_PORT}" -j ACCEPT 2>/dev/null || true

        # Cleanup GTP-U DNAT (BTS_IP based)
        iptables -t nat -D PREROUTING -d "${bts_ip}" -p udp --dport "${GTPU_PORT}" -j DNAT --to-destination "${upf_ip}:${GTPU_PORT}" 2>/dev/null || true
        iptables -t nat -D OUTPUT     -d "${bts_ip}" -p udp --dport "${GTPU_PORT}" -j DNAT --to-destination "${upf_ip}:${GTPU_PORT}" 2>/dev/null || true
        iptables -D FORWARD -p udp -d "${upf_ip}" --dport "${GTPU_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p udp -s "${upf_ip}" --sport "${GTPU_PORT}" -j ACCEPT 2>/dev/null || true

        # Remove BTS IP from dummy interface
        ip addr del "${bts_ip}/32" dev "${BTS_IFACE}" 2>/dev/null || true

        rm -rf "${inst_dir}"
        ok "Instance ${name} removed (containers + iptables + ${bts_ip} cleaned)"
    else
        hdr "Stopping instance ${name}..."
        docker compose -p "${name}" -f "${compose_file}" stop 2>/dev/null || true
        ok "Instance ${name} stopped"
    fi
}

if [ "$STOP_ALL" = true ]; then
    # Find all instance directories
    if [ -d "${SCRIPT_DIR}/instances" ]; then
        for inst_dir in "${SCRIPT_DIR}/instances"/bts*; do
            [ -d "$inst_dir" ] || continue
            id="${inst_dir##*bts}"
            stop_instance "$id"
        done
    else
        warn "No instances directory found"
    fi
elif [ -n "$INSTANCE_ID" ]; then
    stop_instance "$INSTANCE_ID"
else
    err "Usage: ./stop.sh --id <number> | --all [--rm]"
    exit 1
fi
