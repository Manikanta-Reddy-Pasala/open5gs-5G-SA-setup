#!/bin/bash
# ============================================================
# docker.sh — Build unified runtime Docker image for open5GS
# ============================================================
# Usage:
#   ./scripts/docker.sh             # Build unified image (CP + UPF)
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

if [ ! -d "build-output/open5gs" ]; then
    err "build-output/ not found. Run './scripts/build.sh' first."
    exit 1
fi

hdr ""
hdr "  Building unified runtime Docker image"
hdr ""

log "Building ${IMAGE} (all 11 NFs: 10 CP + UPF)..."
docker build -f Dockerfile.all -t "${IMAGE}" .

hdr ""
ok "DOCKER IMAGE BUILT"
hdr ""
log "Runtime image:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep "open5gs" || true
hdr ""
log "Next: ./scripts/start.sh --lm-ip <LM_IP> --trx-ip <TRX_IP> --ng-ip <NG_IP>"
hdr ""
