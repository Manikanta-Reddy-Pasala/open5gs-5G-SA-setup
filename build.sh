#!/bin/bash
# ============================================================
# build.sh — Compile open5GS from source
# ============================================================
# Usage:
#   ./build.sh              # Full source build (~20 min)
#   ./build.sh --quick      # Skip source build, just verify binaries
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$SCRIPT_DIR"

quick=false
[ "${1:-}" = "--quick" ] && quick=true

if [ "$quick" = false ]; then
    hdr ""
    hdr "  Building open5GS from source (no UERANSIM)"
    hdr "  This compiles C code inside Docker (~20 minutes first run)"
    hdr ""

    log "Step 1/2: Building open5GS from source..."
    docker build -f Dockerfile.build-all -t "open5gs-builder:${OPEN5GS_VERSION}" .

    log "Source build complete."
    log "Step 2/2: Extracting built binaries to build-output/..."
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
        err "build-output/open5gs/ not found. Run './build.sh' first (without --quick)."
        exit 1
    fi
    ok "build-output/ exists with binaries"
fi

hdr ""
ok "BUILD COMPLETE"
hdr ""
log "Next: ./docker.sh   (to build runtime Docker images)"
hdr ""
