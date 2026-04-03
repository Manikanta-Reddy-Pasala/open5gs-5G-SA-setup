#!/bin/bash
# ============================================================
# open5gs.sh — Unified management script for open5GS 5G SA Core
# ============================================================
# Usage:
#   ./open5gs.sh build [--quick]
#   ./open5gs.sh start --lm-ip <IP> --trx-ip <IP> --cp-ip <IP> --upf-ip <IP> [options]
#   ./open5gs.sh start --ueransim    (reserved for future UERANSIM integration)
#   ./open5gs.sh stop --trx-ip <IP> [--rm] | --all [--rm]
#   ./open5gs.sh status [--trx-ip <IP>]
#   ./open5gs.sh logs --trx-ip <IP> [nf]
#   ./open5gs.sh provision [--count N] [--imsi X --k K --opc O]
#   ./open5gs.sh sctp-test <target_ip> [port]
#   ./open5gs.sh bulk-provision --count N
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/scripts"

RED=$'\033[0;31m'
NC=$'\033[0m'

usage() {
    cat <<'EOF'
open5GS 5G SA Core — Management Script

Usage: ./open5gs.sh <command> [options]

Commands:
  build                Build open5GS from source
    --quick              Skip source build, just rebuild runtime image

  start                Start a CN instance
    --lm-ip IP           LAN Management IP (for interface detection)
    --trx-ip IP          TRX identifier
    --cp-ip IP           Control Plane IP (NGAP, SBI)
    --upf-ip IP          User Plane IP (GTP-U)
    --mcc X              MCC (default: 001)
    --mnc Y              MNC (default: 01)
    --plmn MCC:MNC       Multi-PLMN (repeatable)
    --tac Z              TAC (default: 1)
    --debug              Enable debug logging

  stop                 Stop CN instance(s)
    --trx-ip IP          Stop specific instance
    --all                Stop all instances
    --rm                 Remove instance (cleanup IPs, TUN, DNAT)

  status               Show instance status
    --trx-ip IP          Show specific instance (default: all)

  logs                 Tail logs
    --trx-ip IP          Instance to tail
    [nf]                 Specific NF: amf, smf, upf, nrf, etc.

  provision            Provision subscriber(s)
    --count N            Number of subscribers (default: 1)
    --imsi X             Starting IMSI
    --k KEY              Subscriber key
    --opc OPC            OPc value

  bulk-provision       Alias for: provision --count N

  sctp-test            Test SCTP/NGAP connectivity
    <target_ip> [port]   IP to test (e.g., public IP or CP IP)

Examples:
  ./open5gs.sh build
  ./open5gs.sh start --lm-ip 10.0.0.1 --trx-ip 10.100.0.11 --cp-ip 10.100.0.15 --upf-ip 10.100.0.16
  ./open5gs.sh start --lm-ip 10.0.0.1 --trx-ip 10.100.0.11 --cp-ip 10.100.0.15 --upf-ip 10.100.0.16 --mcc 404 --mnc 30
  ./open5gs.sh status
  ./open5gs.sh logs --trx-ip 10.100.0.11 amf
  ./open5gs.sh provision --count 10
  ./open5gs.sh sctp-test 135.181.93.114
  ./open5gs.sh stop --trx-ip 10.100.0.11 --rm
  ./open5gs.sh stop --all
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
    build)
        exec bash "${SCRIPTS}/build.sh" "$@"
        ;;

    start)
        # Check for --ueransim flag (placeholder for future)
        for arg in "$@"; do
            if [ "$arg" = "--ueransim" ]; then
                echo "${RED}[$(date '+%H:%M:%S')] --ueransim not yet integrated into multi-TRX mode${NC}" >&2
                echo "  Use UERANSIM separately or start without --ueransim" >&2
                exit 1
            fi
        done
        exec bash "${SCRIPTS}/start.sh" "$@"
        ;;

    stop)
        exec bash "${SCRIPTS}/stop.sh" "$@"
        ;;

    status)
        exec bash "${SCRIPTS}/status.sh" "$@"
        ;;

    logs)
        exec bash "${SCRIPTS}/logs.sh" "$@"
        ;;

    provision)
        exec bash "${SCRIPTS}/provision.sh" "$@"
        ;;

    bulk-provision)
        # Alias: ./open5gs.sh bulk-provision --count 10
        exec bash "${SCRIPTS}/provision.sh" "$@"
        ;;

    sctp-test)
        exec python3 "${SCRIPTS}/sctp_test.py" "$@"
        ;;

    docker)
        exec bash "${SCRIPTS}/docker.sh" "$@"
        ;;

    help|--help|-h)
        usage
        exit 0
        ;;

    *)
        echo "${RED}Unknown command: ${COMMAND}${NC}" >&2
        echo "Run './open5gs.sh help' for usage" >&2
        exit 1
        ;;
esac
