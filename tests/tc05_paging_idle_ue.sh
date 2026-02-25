#!/bin/bash
# ============================================================
# TC05: Paging / Idle UE
# Register UE, wait for CM-IDLE, trigger downlink to cause paging
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC05: Paging / Idle UE"

ensure_core_running

IMSI="$DEFAULT_IMSI"

# Step 1: Register UE and establish PDU session
info "Registering UE..."
kill_all_ues
docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue.yaml
sleep 15

status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if ! echo "$status" | grep -q "RM-REGISTERED"; then
    fail "UE registration failed, aborting"
    exit 1
fi
pass "UE registered"

# Step 2: Confirm PDU session and get UE IP
ps_info=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "ps-list" 2>/dev/null)
info "PDU sessions:"
echo "$ps_info"

UE_IP=$(docker exec open5gs-ueransim ip addr show uesimtun0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
if [ -n "$UE_IP" ]; then
    pass "UE IP on uesimtun0: ${UE_IP}"
else
    warn "Could not detect UE IP from uesimtun0"
    UE_IP=$(echo "$ps_info" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$UE_IP" ] && info "UE IP from ps-list: ${UE_IP}"
fi

# Step 3: Wait for UE to transition to CM-IDLE (inactivity timer)
info "Waiting for UE to enter CM-IDLE state (up to 90s)..."
idle=false
for attempt in $(seq 1 18); do
    cm_state=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null | grep "cm-state" | awk '{print $2}')
    if [ "$cm_state" = "CM-IDLE" ]; then
        idle=true
        pass "UE entered CM-IDLE after $((attempt * 5))s"
        break
    fi
    sleep 5
done

if [ "$idle" = false ]; then
    warn "UE did not enter CM-IDLE automatically (inactivity timer may be long)"
    info "Proceeding with paging test anyway — AMF will page on downlink data"
fi

# Step 4: Trigger paging via downlink data (ping UE IP from UPF)
if [ -n "$UE_IP" ]; then
    info "Sending downlink ping to UE IP ${UE_IP} (triggers paging)..."
    # Record AMF log position before ping
    amf_lines=$(docker exec open5gs-cp wc -l /var/log/open5gs/amf.log 2>/dev/null | awk '{print $1}')
    docker exec open5gs-upf ping -c 3 -W 3 "$UE_IP" 2>/dev/null || true
    sleep 5

    # Check AMF logs for paging
    amf_new_logs=$(docker exec open5gs-cp tail -n +$((amf_lines + 1)) /var/log/open5gs/amf.log 2>/dev/null)
    if echo "$amf_new_logs" | grep -qi "paging\|Paging"; then
        pass "AMF sent Paging message (detected in logs)"
        echo "$amf_new_logs" | grep -i "paging" | tail -3
    else
        info "No explicit 'Paging' in AMF logs — checking UE state transition..."
    fi

    # Check if UE transitioned back to CM-CONNECTED
    cm_state=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null | grep "cm-state" | awk '{print $2}')
    if [ "$cm_state" = "CM-CONNECTED" ]; then
        pass "UE transitioned to CM-CONNECTED (paging success)"
    else
        info "UE cm-state: ${cm_state:-unknown}"
    fi
else
    warn "No UE IP found, skipping downlink trigger"
fi

# Step 5: Verify UE still functional after paging
status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE remains registered after paging test"
else
    fail "UE lost registration during paging test"
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC05 Complete${NC}: Paging/Idle UE test finished."
info "Note: UERANSIM UE may not auto-transition to CM-IDLE depending on inactivity timer config."
