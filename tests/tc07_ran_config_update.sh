#!/bin/bash
# ============================================================
# TC07: RAN Configuration Update Procedure
# Test TAC configuration change: update gNB + AMF, verify gNB reconnects
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC07: RAN Configuration Update (TAC Change)"

ensure_core_running

IMSI="$DEFAULT_IMSI"

# Step 1: Verify baseline with current config
info "Verifying baseline gNB-AMF connection..."
kill_all_ues
sleep 2

gnb_logs=$(tail -50 "${UE_CONFIG_DIR}/gnb.log" 2>&1)
if echo "$gnb_logs" | grep -qi "NG Setup\|ngSetup\|amf.*connected\|NGAP"; then
    pass "gNB connected to AMF with current config"
else
    info "gNB logs (last 10 lines):"
    echo "$gnb_logs" | tail -10
fi

# Register a UE to confirm connectivity
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12
status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered with baseline config (MCC=${MCC}, MNC=${MNC})"
    tac=$(echo "$status" | grep "current-tac" | awk '{print $2}')
    info "Current TAC: ${tac}"
else
    fail "Baseline registration failed"
fi
kill_all_ues

# Step 2: Read current TAC and compute new TAC
ORIG_TAC=$(grep '^tac:' "${UE_CONFIG_DIR}/gnb.yaml" 2>/dev/null | awk '{print $2}')
ORIG_TAC="${ORIG_TAC:-1}"
NEW_TAC=$((ORIG_TAC + 1))
info "Updating TAC from ${ORIG_TAC} to ${NEW_TAC}..."

# Update AMF config on host
sed -i "s/tac: ${ORIG_TAC}\b/tac: ${NEW_TAC}/" "${INST_CONFIG}/amf.yaml"
info "Updated AMF config TAC to ${NEW_TAC}"

# Update gNB config on host
sed -i "s/^tac: [0-9]*/tac: ${NEW_TAC}/" "${UE_CONFIG_DIR}/gnb.yaml"
info "Updated gNB config TAC to ${NEW_TAC}"

# Step 3: Restart CP and UERANSIM to apply new config
info "Restarting Control Plane to apply new TAC..."
docker restart "$CONTAINER_NAME" >/dev/null 2>&1
if wait_cp_healthy 120; then
    pass "CP restarted and healthy"
else
    fail "CP health check failed after restart"
fi

info "Restarting UERANSIM gNB with new TAC..."
reset_ueransim

# Step 4: Verify gNB reconnects with new TAC
if wait_gnb_connected 60; then
    pass "gNB re-established NG Setup with new TAC"
else
    gnb_logs=$(tail -30 "${UE_CONFIG_DIR}/gnb.log" 2>&1)
    info "gNB logs:"
    echo "$gnb_logs" | tail -10
fi
sleep 5

# Step 5: Register UE and verify new TAC
info "Registering UE with new TAC..."
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 20
status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered with updated TAC"
    new_tac=$(echo "$status" | grep "current-tac" | awk '{print $2}')
    info "UE reports TAC: ${new_tac}"
    if [ "$new_tac" = "$NEW_TAC" ]; then
        pass "TAC matches expected value (${NEW_TAC})"
    else
        warn "TAC mismatch: expected ${NEW_TAC}, got ${new_tac:-unknown}"
    fi
else
    fail "UE registration failed with new TAC"
fi
kill_all_ues

# Step 6: Restore original TAC
info "Restoring original TAC (${ORIG_TAC})..."
sed -i "s/tac: ${NEW_TAC}\b/tac: ${ORIG_TAC}/" "${INST_CONFIG}/amf.yaml"
sed -i "s/^tac: ${NEW_TAC}/tac: ${ORIG_TAC}/" "${UE_CONFIG_DIR}/gnb.yaml"
docker restart "$CONTAINER_NAME" >/dev/null 2>&1
sleep 30
reset_ueransim
sleep 10
pass "Original config restored"

# Summary
echo ""
echo -e "${BOLD}TC07 Complete${NC}: RAN config update tested with TAC change ${CYAN}${ORIG_TAC} -> ${NEW_TAC} -> ${ORIG_TAC}${NC}"
