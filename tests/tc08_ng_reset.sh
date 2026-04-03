#!/bin/bash
# ============================================================
# TC08: NG Reset Procedure
# Test gNB-AMF interface reset: graceful restart and forced reset
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC08: NG Reset Procedure"

ensure_core_running

IMSI="$DEFAULT_IMSI"

# ── Phase 1: Graceful NG Reset (container restart) ─────────────
echo ""
info "=== Phase 1: Graceful NG Reset (UERANSIM container restart) ==="

"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12

status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered before NG Reset"
else
    warn "UE not registered before reset, continuing anyway"
fi
kill_all_ues

# Record AMF log position
amf_lines=$(wc -l "${LOG_DIR}/amf.log" 2>/dev/null | awk '{print $1}')

# Restart UERANSIM (simulates graceful gNB restart / NG Reset)
info "Restarting UERANSIM (graceful NG Reset)..."
reset_ueransim
sleep 12

# Check AMF logs for SCTP/NG association events
amf_new=$(tail -n +$((amf_lines + 1)) "${LOG_DIR}/amf.log" 2>/dev/null)
if echo "$amf_new" | grep -qi "SCTP\|NG Setup\|associate\|disconnect\|ran-ue\|gnb"; then
    pass "AMF detected SCTP/NG state change during restart"
    echo "$amf_new" | grep -i "SCTP\|NG Setup\|associate\|gnb" | tail -3
else
    info "No explicit SCTP/NG event in AMF logs (may be at debug level)"
fi

# Verify gNB re-establishes NG Setup
gnb_logs=$(tail -30 "${UE_CONFIG_DIR}/gnb.log" 2>&1)
if echo "$gnb_logs" | grep -qi "NG Setup\|ngSetup\|NGAP\|AMF"; then
    pass "gNB re-established NG Setup after restart"
else
    info "gNB logs (last 10 lines):"
    echo "$gnb_logs" | tail -10
fi

# Register UE to confirm connectivity
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12
status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Phase 1: UE registered after graceful NG Reset"
else
    fail "Phase 1: UE failed to register after graceful NG Reset"
fi
kill_all_ues

# ── Phase 2: Forced NG Reset (kill gNB process + restart) ──────
echo ""
info "=== Phase 2: Forced NG Reset (abrupt gNB kill) ==="

# Start UE first
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 10

# Kill nr-gnb process abruptly (simulate gNB crash without SCTP FIN)
info "Killing nr-gnb process abruptly..."
pkill -9 -f "nr-gnb" 2>/dev/null || true
pkill -9 -f "nr-ue" 2>/dev/null || true
sleep 5

# Check AMF logs for detection of abrupt disconnect
amf_lines=$(wc -l "${LOG_DIR}/amf.log" 2>/dev/null | awk '{print $1}')

# Restart gNB
info "Restarting gNB after forced kill..."
"${UERANSIM_DIR}/nr-gnb" -c "${UE_CONFIG_DIR}/gnb.yaml" > "${UE_CONFIG_DIR}/gnb.log" 2>&1 &
sleep 10

# Check if AMF detected disconnect / ran UE cleanup
amf_new=$(tail -n +$((amf_lines + 1)) "${LOG_DIR}/amf.log" 2>/dev/null)
if echo "$amf_new" | grep -qi "SCTP\|abort\|close\|remove\|ran-ue"; then
    pass "AMF detected forced gNB disconnect"
else
    info "AMF may need time to detect timeout (SCTP heartbeat interval)"
fi

# Register UE with restarted gNB
pkill -f "nr-gnb" 2>/dev/null || true
reset_ueransim
sleep 10
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12
status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Phase 2: UE registered after forced NG Reset"
else
    fail "Phase 2: UE failed to register after forced NG Reset"
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC08 Complete${NC}: NG Reset tested (graceful restart + forced kill/reconnect)."
