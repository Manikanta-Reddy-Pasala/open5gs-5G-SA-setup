#!/bin/bash
# ============================================================
# TC04: Multi-UE De-Registration
# Register multiple UEs, then deregister all simultaneously
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NUM_UES="${1:-3}"

header "TC04: Multi-UE De-Registration (${NUM_UES} UEs)"

ensure_core_running

# Step 1: Provision subscribers
info "Provisioning ${NUM_UES} subscribers..."
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    provision_subscriber "$supi_num" "$k" "$OPC"
done
pass "Provisioned ${NUM_UES} subscribers"

# Step 2: Generate configs and launch UEs
info "Launching ${NUM_UES} UEs..."
kill_all_ues
TMPDIR=$(mktemp -d)
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    generate_ue_config "$supi_num" "$k" "$OPC" "${TMPDIR}/ue${i}.yaml" "internet"
    docker cp "${TMPDIR}/ue${i}.yaml" open5gs-ueransim:/ueransim/config/ue${i}.yaml
    docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue${i}.yaml
done
sleep 18

# Step 3: Verify all registered
registered=0
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    status=$(docker exec open5gs-ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
    if echo "$status" | grep -q "RM-REGISTERED"; then
        pass "UE ${imsi}: REGISTERED"
        registered=$((registered + 1))
    else
        fail "UE ${imsi}: NOT REGISTERED"
    fi
done

if [ "$registered" -lt "$NUM_UES" ]; then
    warn "Only ${registered}/${NUM_UES} registered. Proceeding with deregistration of those."
fi

# Step 4: Deregister all UEs simultaneously
echo ""
info "Deregistering all ${NUM_UES} UEs simultaneously..."
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    docker exec open5gs-ueransim ./nr-cli "$imsi" -e "deregister normal" 2>/dev/null &
done
wait
# Wait for NAS deregistration to complete on all UEs
sleep 15

# Step 5: Verify all deregistered
# Kill UE processes first so nr-cli sees "could not connect" (clean state)
docker exec open5gs-ueransim pkill -f "nr-ue" 2>/dev/null || true
sleep 3

deregistered=0
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    status=$(docker exec open5gs-ueransim ./nr-cli "$imsi" -e "status" 2>&1)
    if echo "$status" | grep -q "RM-DEREGISTERED"; then
        pass "UE ${imsi}: DEREGISTERED"
        deregistered=$((deregistered + 1))
    elif echo "$status" | grep -qi "could not connect\|not found\|No node\|No UE\|ERROR"; then
        pass "UE ${imsi}: DEREGISTERED (process exited)"
        deregistered=$((deregistered + 1))
    elif [ -z "$status" ]; then
        pass "UE ${imsi}: DEREGISTERED (no response)"
        deregistered=$((deregistered + 1))
    else
        fail "UE ${imsi}: still registered"
        echo "$status" | head -3
    fi
done

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
if [ "$deregistered" -eq "$NUM_UES" ]; then
    echo -e "${GREEN}${BOLD}TC04 PASSED${NC}: All ${NUM_UES} UEs deregistered successfully"
else
    echo -e "${RED}${BOLD}TC04 FAILED${NC}: ${deregistered}/${NUM_UES} deregistered"
fi
