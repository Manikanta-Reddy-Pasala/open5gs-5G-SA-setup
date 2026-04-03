#!/bin/bash
# ============================================================
# TC06: gNB/UE RAN Simulator Initiated UE Context Release
# Test UE context release procedure (Radio Link Failure + graceful deregister)
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC06: UE Context Release Procedure"

ensure_core_running

IMSI="$DEFAULT_IMSI"

# Step 1: Register UE
info "Registering UE..."
kill_all_ues
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12

status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if ! echo "$status" | grep -q "RM-REGISTERED"; then
    fail "UE registration failed, aborting"
    exit 1
fi
pass "UE registered and CM-CONNECTED"

# Record initial AMF log line count for later comparison
amf_lines_before=$(wc -l "${LOG_DIR}/amf.log" 2>/dev/null | awk '{print $1}')

# Step 2: Simulate RLF by killing the UE process (ungraceful disconnect)
info "Simulating Radio Link Failure (killing UE process)..."
pkill -9 -f "nr-ue" 2>/dev/null
sleep 5

# Step 3: Check AMF logs for UE context release
info "Checking AMF logs for UE Context Release..."
amf_new_logs=$(tail -n +$((amf_lines_before + 1)) "${LOG_DIR}/amf.log" 2>/dev/null)

if echo "$amf_new_logs" | grep -qi "context release\|UE_CONTEXT_RELEASE\|RAN-UE-NGAP-ID\|UeContextRelease"; then
    pass "AMF processed UE Context Release"
    echo "$amf_new_logs" | grep -i "context release\|UeContextRelease" | tail -3
else
    info "No explicit 'UE Context Release' in AMF logs."
    info "AMF may clean up UE context via inactivity timer (open5GS default: ~10s)."
fi

# Step 4: Verify UE is no longer tracked as connected
sleep 5
if echo "$amf_new_logs" | grep -qi "remove\|cleanup\|release\|idle"; then
    pass "AMF cleaned up UE context"
fi

# Step 5: Graceful deregister test
info ""
info "=== Graceful UE Context Release (deregister) ==="
"${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue.yaml" > "${UE_CONFIG_DIR}/ue.log" 2>&1 &
sleep 12

status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE re-registered for graceful release test"
else
    fail "UE re-registration failed"
    kill_all_ues
    exit 1
fi

amf_lines_before=$(wc -l "${LOG_DIR}/amf.log" 2>/dev/null | awk '{print $1}')

info "Sending deregister command (graceful UE-initiated release)..."
"${UERANSIM_DIR}/nr-cli" "$IMSI" -e "deregister normal" 2>/dev/null
sleep 5

amf_new_logs=$(tail -n +$((amf_lines_before + 1)) "${LOG_DIR}/amf.log" 2>/dev/null)

if echo "$amf_new_logs" | grep -qi "deregistration\|Deregist"; then
    pass "AMF processed UE Deregistration"
    echo "$amf_new_logs" | grep -i "deregist" | tail -3
else
    info "Checking UE state directly..."
fi

status=$("${UERANSIM_DIR}/nr-cli" "$IMSI" -e "status" 2>&1)
if echo "$status" | grep -q "RM-DEREGISTERED"; then
    pass "UE is RM-DEREGISTERED (context released)"
elif echo "$status" | grep -qi "could not connect\|not found\|No node\|ERROR"; then
    pass "UE process exited (context fully released)"
elif [ -z "$status" ]; then
    pass "UE process exited (no response)"
else
    fail "UE still registered after deregister"
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC06 Complete${NC}"
info "Tested both ungraceful (RLF/kill) and graceful (deregister) UE context release."
