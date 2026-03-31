#!/bin/bash
# ============================================================
# docker.sh — Build runtime Docker images for open5GS
# ============================================================
# Usage:
#   ./scripts/docker.sh             # Build CP + UPF images
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

if [ ! -d "build-output/open5gs" ]; then
    err "build-output/ not found. Run './scripts/build.sh' first."
    exit 1
fi

hdr ""
hdr "  Building runtime Docker images"
hdr ""

mkdir -p logs

log "Building CP image (${IMAGE_CP})..."
docker build -f Dockerfile.cp -t "${IMAGE_CP}" .

log "Building UPF image (${IMAGE_UPF})..."
docker build -f Dockerfile.upf -t "${IMAGE_UPF}" .

hdr ""
ok "DOCKER IMAGES BUILT"
hdr ""
log "Runtime images:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "open5gs-(cp|upf)" || true
hdr ""
log "Next: ./scripts/start.sh --id 1 --amf-ip <IP> --upf-ip <IP>"
hdr ""
