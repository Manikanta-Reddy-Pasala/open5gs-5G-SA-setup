#!/bin/bash
# ============================================================
# TC01: Parallel UE Registration
# Register multiple UEs simultaneously and verify all succeed
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NUM_UES="${1:-5}"

header "TC01: Parallel UE Registration (${NUM_UES} UEs)"

ensure_core_running

# Step 1: Provision subscribers
info "Provisioning ${NUM_UES} subscribers..."
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    provision_subscriber "$supi_num" "$k" "$OPC"
done
pass "Provisioned ${NUM_UES} subscribers"

# Step 2: Generate UE configs and launch all UEs simultaneously
info "Generating configs and launching ${NUM_UES} UEs in parallel..."
kill_all_ues
TMPDIR=$(mktemp -d)

for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    generate_ue_config "$supi_num" "$k" "$OPC" "${TMPDIR}/ue${i}.yaml" "internet"
    docker cp "${TMPDIR}/ue${i}.yaml" open5gs-ueransim:/ueransim/config/ue${i}.yaml
    docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue${i}.yaml
done

info "Waiting 20s for all UEs to register..."
sleep 20

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
        echo "$status" | head -3
    fi
done

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
if [ "$registered" -eq "$NUM_UES" ]; then
    echo -e "${GREEN}${BOLD}TC01 PASSED${NC}: All ${NUM_UES} UEs registered simultaneously"
else
    echo -e "${RED}${BOLD}TC01 FAILED${NC}: Only ${registered}/${NUM_UES} registered"
fi
