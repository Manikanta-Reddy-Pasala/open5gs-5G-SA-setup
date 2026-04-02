#!/bin/bash
# ============================================================
# build.sh — Compile open5GS from source
# ============================================================
# Usage:
#   ./scripts/build.sh              # Full source build (~20 min)
#   ./scripts/build.sh --quick      # Skip source build, just verify binaries
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

quick=false
[ "${1:-}" = "--quick" ] && quick=true

if [ "$quick" = false ]; then
    hdr ""
    hdr "  Building open5GS from source"
    hdr "  This compiles C code inside Docker (~20 minutes first run)"
    hdr ""

    log "Step 1/3: Building open5GS from source..."
    docker build -f Dockerfile.build -t "open5gs-builder:${OPEN5GS_VERSION}" .

    log "Source build complete."
    log "Step 2/3: Extracting built binaries to build-output/..."
    rm -rf build-output
    mkdir -p build-output

    docker run --rm -v "$(pwd)/build-output:/export" "open5gs-builder:${OPEN5GS_VERSION}"

    if [ ! -f "build-output/open5gs/bin/open5gs-amfd" ]; then
        err "Binary extraction failed. build-output/open5gs/bin/open5gs-amfd not found."
        exit 1
    fi

    log "Binaries extracted:"
    log "  open5GS: $(ls build-output/open5gs/bin/ | tr '\n' ' ')"

    [ -f "build-output/BUILD_MANIFEST.txt" ] && cat build-output/BUILD_MANIFEST.txt
else
    log "Quick mode: verifying existing build-output/"
    if [ ! -d "build-output/open5gs" ]; then
        err "build-output/open5gs/ not found. Run './scripts/build.sh' first (without --quick)."
        exit 1
    fi
    ok "build-output/ exists with binaries"
fi

hdr ""
log "Step 3/3: Building unified runtime image (${IMAGE})..."
docker build -f Dockerfile.all -t "${IMAGE}" .

hdr ""
ok "BUILD COMPLETE — Image: ${IMAGE}"
hdr ""
log "Runtime image:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep "open5gs" || true
hdr ""
log "Next: ./scripts/start.sh --lm-ip <LM_IP> --trx-ip <TRX_IP> --ng-ip <NG_IP>"
hdr ""
