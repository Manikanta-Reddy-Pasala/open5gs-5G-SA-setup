#!/bin/bash
# ============================================================
# stop.sh — Stop a CN instance (or all)
# ============================================================
# Usage:
#   ./scripts/stop.sh --id 1         # Stop instance bts1
#   ./scripts/stop.sh --all           # Stop all instances
#   ./scripts/stop.sh --id 1 --rm    # Stop and remove (containers + network + shim)
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

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
    local inst_dir="${PROJECT_DIR}/instances/${name}"
    local compose_file="${inst_dir}/docker-compose.yaml"
    local metadata="${inst_dir}/metadata.env"

    if [ ! -f "$compose_file" ]; then
        warn "Instance ${name} not found (no compose file)"
        return 1
    fi

    # Load saved metadata for IP addresses
    local amf_ip="" upf_ip="" ue_subnet=""
    if [ -f "$metadata" ]; then
        source "$metadata"
        amf_ip="${AMF_IP:-}"
        upf_ip="${UPF_IP:-}"
        ue_subnet="${UE_SUBNET:-}"
    else
        warn "No metadata.env for ${name} — cannot clean up networking"
    fi

    if [ "$REMOVE" = true ]; then
        hdr "Removing instance ${name}..."
        docker compose -p "${name}" -f "${compose_file}" down -v --remove-orphans 2>/dev/null || true

        # Cleanup UE routes + iptables
        if [ -n "$ue_subnet" ] && [ -n "$upf_ip" ]; then
            ip route del "${ue_subnet}" via "${upf_ip}" 2>/dev/null || true
            iptables -t nat -D POSTROUTING -s "${ue_subnet}" -j MASQUERADE 2>/dev/null || true
            iptables -D FORWARD -s "${ue_subnet}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${ue_subnet}" -j ACCEPT 2>/dev/null || true
        fi

        # Cleanup macvlan shim + routes
        if [ -n "$amf_ip" ] && [ -n "$upf_ip" ]; then
            remove_macvlan_shim "$id" "$amf_ip" "$upf_ip"
        fi

        # Remove macvlan Docker network
        docker network rm "bts${id}-net" 2>/dev/null || true

        rm -rf "${inst_dir}"
        ok "Instance ${name} removed (containers + network + shim cleaned)"
    else
        hdr "Stopping instance ${name}..."
        docker compose -p "${name}" -f "${compose_file}" stop 2>/dev/null || true
        ok "Instance ${name} stopped"
    fi
}

if [ "$STOP_ALL" = true ]; then
    if [ -d "${PROJECT_DIR}/instances" ]; then
        for inst_dir in "${PROJECT_DIR}/instances"/bts*; do
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
    err "Usage: ./scripts/stop.sh --id <number> | --all [--rm]"
    exit 1
fi
