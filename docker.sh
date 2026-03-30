#!/bin/bash
# ============================================================
# docker.sh — Build runtime Docker images for open5GS
# ============================================================
# Usage:
#   ./docker.sh             # Build CP, UPF, WebUI images
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

if [ ! -d "build-output/open5gs" ]; then
    err "build-output/ not found. Run './build.sh' first."
    exit 1
fi

hdr ""
hdr "  Building runtime Docker images"
hdr ""

mkdir -p logs

log "Building CP image..."
docker build -f Dockerfile.cp-local -t "open5gs-cp-local:${OPEN5GS_VERSION}" .

log "Building UPF image..."
docker build -f Dockerfile.upf-local -t "open5gs-upf-local:${OPEN5GS_VERSION}" .

log "Building WebUI image..."
docker build -f Dockerfile.webui -t "open5gs-webui-local:${OPEN5GS_VERSION}" .

hdr ""
ok "DOCKER IMAGES BUILT"
hdr ""
log "Runtime images:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "open5gs-(cp|upf|webui)" || true
hdr ""
log "Next: ./start.sh --id 1   (to start a CN instance)"
hdr ""
