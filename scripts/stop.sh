#!/bin/bash
# ============================================================
# stop.sh — Stop a CN instance (or all)
# ============================================================
# Usage:
#   ./scripts/stop.sh --trx-ip 10.100.0.11         # Stop instance
#   ./scripts/stop.sh --all                          # Stop all instances
#   ./scripts/stop.sh --trx-ip 10.100.0.11 --rm    # Stop and remove
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

TRX_IP=""
STOP_ALL=false
REMOVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trx-ip) TRX_IP="$2"; shift ;;
        --all)    STOP_ALL=true ;;
        --rm)     REMOVE=true ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

compose_cmd() {
    local project="$1" inst_dir="$2"; shift 2
    local env_file="${inst_dir}/.env"
    if [ -f "$env_file" ]; then
        docker compose -p "${project}" --env-file "${env_file}" -f "${PROJECT_DIR}/docker-compose.yaml" "$@"
    else
        docker compose -p "${project}" -f "${PROJECT_DIR}/docker-compose.yaml" "$@"
    fi
}

stop_instance() {
    local name="$1"
    local inst_dir="${PROJECT_DIR}/instances/${name}"
    local metadata="${inst_dir}/metadata.env"
    local project="${name//./-}"    # dots → dashes for compose project

    if [ ! -d "$inst_dir" ]; then
        warn "Instance ${name} not found"
        return 1
    fi

    # Load saved metadata for IP addresses
    local trx_ip="" ng_ip="" ue_subnet="" parent_iface="" host_prefix="" tun_dev="" container_name=""
    if [ -f "$metadata" ]; then
        source "$metadata"
        trx_ip="${TRX_IP:-}"
        ng_ip="${NG_IP:-}"
        ue_subnet="${UE_SUBNET:-}"
        parent_iface="${PARENT_IFACE:-}"
        host_prefix="${HOST_PREFIX:-}"
        tun_dev="${TUN_DEV:-}"
        container_name="${CONTAINER_NAME:-}"
    else
        warn "No metadata.env for ${name} — cannot clean up networking"
    fi

    if [ "$REMOVE" = true ]; then
        hdr "Removing instance ${name}..."
        compose_cmd "${project}" "${inst_dir}" down -v --remove-orphans 2>/dev/null || true

        # Cleanup TUN device
        if [ -n "$tun_dev" ]; then
            ip link set "$tun_dev" down 2>/dev/null || true
            ip tuntap del name "$tun_dev" mode tun 2>/dev/null || true
            log "Removed TUN device ${tun_dev}"
        fi

        # Cleanup UE routes + iptables
        if [ -n "$ue_subnet" ] && [ -n "$ng_ip" ]; then
            ip route del "${ue_subnet}" via "${ng_ip}" 2>/dev/null || true
            iptables -t nat -D POSTROUTING -s "${ue_subnet}" -j MASQUERADE 2>/dev/null || true
            iptables -D FORWARD -s "${ue_subnet}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${ue_subnet}" -j ACCEPT 2>/dev/null || true
        fi

        # Remove NG secondary IP from host interface
        if [ -n "$parent_iface" ] && [ -n "$host_prefix" ] && [ -n "$ng_ip" ]; then
            ip addr del "${ng_ip}/${host_prefix}" dev "$parent_iface" 2>/dev/null || true
            log "Removed ${ng_ip}/${host_prefix} from ${parent_iface}"
        fi

        rm -rf "${inst_dir}"
        ok "Instance ${name} removed (containers + secondary IPs cleaned)"
    else
        hdr "Stopping instance ${name}..."
        compose_cmd "${project}" "${inst_dir}" stop 2>/dev/null || true
        ok "Instance ${name} stopped"
    fi
}

if [ "$STOP_ALL" = true ]; then
    if [ -d "${PROJECT_DIR}/instances" ]; then
        for inst_dir in "${PROJECT_DIR}/instances"/trx-*; do
            [ -d "$inst_dir" ] || continue
            name="$(basename "$inst_dir")"
            stop_instance "$name"
        done
    else
        warn "No instances directory found"
    fi
elif [ -n "$TRX_IP" ]; then
    stop_instance "trx-${TRX_IP}"
else
    err "Usage: ./scripts/stop.sh --trx-ip <IP> | --all [--rm]"
    exit 1
fi
