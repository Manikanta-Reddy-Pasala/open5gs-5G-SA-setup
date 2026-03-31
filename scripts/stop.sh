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

compose_cmd() {
    local name="$1" inst_dir="$2"; shift 2
    local env_file="${inst_dir}/.env"
    if [ -f "$env_file" ]; then
        docker compose -p "${name}" --env-file "${env_file}" -f "${PROJECT_DIR}/docker-compose.yaml" "$@"
    else
        docker compose -p "${name}" -f "${PROJECT_DIR}/docker-compose.yaml" "$@"
    fi
}

stop_instance() {
    local id="$1"
    local name="bts${id}"
    local inst_dir="${PROJECT_DIR}/instances/${name}"
    local metadata="${inst_dir}/metadata.env"

    if [ ! -d "$inst_dir" ]; then
        warn "Instance ${name} not found"
        return 1
    fi

    # Load saved metadata for IP addresses
    local amf_ip="" upf_ip="" ue_subnet="" parent_iface="" host_prefix=""
    if [ -f "$metadata" ]; then
        source "$metadata"
        amf_ip="${AMF_IP:-}"
        upf_ip="${UPF_IP:-}"
        ue_subnet="${UE_SUBNET:-}"
        parent_iface="${PARENT_IFACE:-}"
        host_prefix="${HOST_PREFIX:-}"
    else
        warn "No metadata.env for ${name} — cannot clean up networking"
    fi

    if [ "$REMOVE" = true ]; then
        hdr "Removing instance ${name}..."
        compose_cmd "${name}" "${inst_dir}" down -v --remove-orphans 2>/dev/null || true

        # Cleanup UE routes + iptables
        if [ -n "$ue_subnet" ] && [ -n "$upf_ip" ]; then
            ip route del "${ue_subnet}" via "${upf_ip}" 2>/dev/null || true
            iptables -t nat -D POSTROUTING -s "${ue_subnet}" -j MASQUERADE 2>/dev/null || true
            iptables -D FORWARD -s "${ue_subnet}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${ue_subnet}" -j ACCEPT 2>/dev/null || true
        fi

        # Remove secondary IPs from host interface
        if [ -n "$parent_iface" ] && [ -n "$host_prefix" ]; then
            if [ -n "$amf_ip" ]; then
                ip addr del "${amf_ip}/${host_prefix}" dev "$parent_iface" 2>/dev/null || true
                log "Removed ${amf_ip}/${host_prefix} from ${parent_iface}"
            fi
            if [ -n "$upf_ip" ]; then
                ip addr del "${upf_ip}/${host_prefix}" dev "$parent_iface" 2>/dev/null || true
                log "Removed ${upf_ip}/${host_prefix} from ${parent_iface}"
            fi
        fi

        rm -rf "${inst_dir}"
        ok "Instance ${name} removed (containers + secondary IPs cleaned)"
    else
        hdr "Stopping instance ${name}..."
        compose_cmd "${name}" "${inst_dir}" stop 2>/dev/null || true
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
