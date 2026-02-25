#!/bin/bash
# ============================================================
# TC02: Component Crash & Recovery
# Test resilience after UPF, CP, and MongoDB restarts
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC02: Component Crash & Recovery"

ensure_core_running

IMSI="$DEFAULT_IMSI"

# ── Test A: UPF Crash & Recovery ──────────────────────────────
echo ""
info "=== Test A: UPF Crash & Recovery ==="

# Register baseline UE
docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
sleep 12

status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Baseline UE registered"
else
    fail "Baseline registration failed — aborting TC02"
    kill_all_ues
    exit 1
fi

# Kill and restart UPF
info "Restarting UPF (simulating crash)..."
kill_all_ues
docker restart open5gs-upf >/dev/null 2>&1
sleep 15

# Restart gNB to clear stale state, then re-register
docker restart open5gs-ueransim >/dev/null 2>&1
sleep 10
docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
sleep 12

status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Test A: UE re-registered after UPF restart"
else
    fail "Test A: UE failed to re-register after UPF restart"
fi
kill_all_ues

# ── Test B: Control Plane Crash & Recovery ─────────────────────
echo ""
info "=== Test B: Control Plane (CP) Crash & Recovery ==="

info "Restarting open5gs-cp (simulating CP crash)..."
docker restart open5gs-cp >/dev/null 2>&1

# Wait for CP to become healthy (NRF SBI check)
info "Waiting for CP to recover (up to 120s)..."
if wait_cp_healthy 120; then
    pass "CP recovered and is healthy"
else
    fail "CP did not recover within 120s"
fi

# Restart UERANSIM to reconnect gNB after CP restart
docker restart open5gs-ueransim >/dev/null 2>&1
sleep 10

docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
sleep 12

status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Test B: UE re-registered after CP restart"
else
    fail "Test B: UE failed to re-register after CP restart"
fi
kill_all_ues

# ── Test C: MongoDB Crash & Recovery ──────────────────────────
echo ""
info "=== Test C: MongoDB Crash & Recovery ==="

info "Restarting open5gs-mongodb (simulating DB crash)..."
docker restart open5gs-mongodb >/dev/null 2>&1
sleep 15

# CP should reconnect to MongoDB automatically; also restart CP to force reconnect
info "Restarting CP after MongoDB recovery..."
docker restart open5gs-cp >/dev/null 2>&1
if wait_cp_healthy 120; then
    pass "CP healthy after MongoDB restart"
else
    fail "CP unhealthy after MongoDB restart"
fi

docker restart open5gs-ueransim >/dev/null 2>&1
sleep 10
docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
sleep 12

status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Test C: UE re-registered after MongoDB restart"
else
    fail "Test C: UE failed to re-register after MongoDB restart"
fi
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC02 Complete${NC}: Crash recovery tested for UPF, CP, and MongoDB."
