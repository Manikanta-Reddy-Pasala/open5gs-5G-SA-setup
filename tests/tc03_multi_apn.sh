#!/bin/bash
# ============================================================
# TC03: Minimum Two APNs Connectivity per UE
# Verify UE can establish PDU sessions on two DNNs: internet + ims
#
# Prerequisites: SMF config must support DNN "ims" in addition to "internet".
# This test provisions the subscriber with both DNNs in MongoDB.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC03: Multi-APN (Two DNNs per UE)"

ensure_core_running

SUPI="$BASE_SUPI"
IMSI="imsi-${SUPI}"
K="$BASE_K"

# Step 1: Check if 'ims' DNN is configured in SMF
info "Checking if 'ims' DNN is configured in SMF..."
if docker exec open5gs-cp grep -q '"ims"\|ims:' /etc/open5gs/smf.yaml 2>/dev/null; then
    pass "'ims' DNN found in SMF config"
else
    warn "'ims' DNN not found in SMF config."
    info "The test will continue — PDU session on 'ims' may fail."
    info "To add 'ims' DNN: edit config/smf.yaml and add it to the DNN list."
fi

# Step 2: Provision subscriber with both internet + ims DNNs in MongoDB
info "Provisioning subscriber with internet + ims DNNs..."
provision_subscriber_multi_apn "$SUPI" "$K" "$OPC"
pass "Subscriber ${IMSI} provisioned with dual-DNN"

# Step 3: Generate UE config with TWO sessions (internet + ims)
info "Generating UE config with two PDU sessions..."
TMPDIR=$(mktemp -d)
generate_ue_config "$SUPI" "$K" "$OPC" "${TMPDIR}/ue_multi_apn.yaml" "internet,ims"
docker cp "${TMPDIR}/ue_multi_apn.yaml" open5gs-ueransim:/ueransim/config/ue_multi_apn.yaml

# Step 4: Launch UE
kill_all_ues
info "Launching UE with multi-APN config..."
docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue_multi_apn.yaml
sleep 18

# Step 5: Check registration
status=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered: ${IMSI}"
else
    fail "UE registration failed"
    echo "$status"
fi

# Step 6: Check PDU sessions
ps_list=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "ps-list" 2>/dev/null)
echo ""
info "PDU Session list:"
echo "$ps_list"
echo ""

internet_session=false
ims_session=false

if echo "$ps_list" | grep -q "internet"; then
    pass "PDU session on DNN 'internet' established"
    internet_session=true
else
    fail "No PDU session on DNN 'internet'"
fi

if echo "$ps_list" | grep -q "ims"; then
    pass "PDU session on DNN 'ims' established"
    ims_session=true
else
    warn "PDU session on DNN 'ims' not established"
    info "Attempting manual PDU session establishment..."
    docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "ps-establish IPv4 --dnn ims --sst 3 --sd 198153" 2>/dev/null
    sleep 5
    ps_list2=$(docker exec open5gs-ueransim ./nr-cli "$IMSI" -e "ps-list" 2>/dev/null)
    if echo "$ps_list2" | grep -q "ims"; then
        pass "PDU session on DNN 'ims' established (manual)"
        ims_session=true
    else
        fail "PDU session on DNN 'ims' could not be established"
        info "Ensure 'ims' is listed in config/smf.yaml snssai->dnn section."
    fi
fi

# Step 7: Check TUN interfaces
tun_list=$(docker exec open5gs-ueransim ip addr show 2>/dev/null | grep "uesimtun")
tun_count=$(echo "$tun_list" | grep -c "uesimtun" || echo 0)
info "TUN interfaces: ${tun_count}"
echo "$tun_list"

if [ "$tun_count" -ge 2 ]; then
    pass "Two or more TUN interfaces created (multi-APN confirmed)"
elif [ "$tun_count" -eq 1 ]; then
    warn "Only 1 TUN interface. Second DNN may need SMF config for 'ims'."
fi

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
if [ "$internet_session" = true ] && [ "$ims_session" = true ]; then
    echo -e "${GREEN}${BOLD}TC03 PASSED${NC}: UE has PDU sessions on both internet and ims"
else
    echo -e "${YELLOW}${BOLD}TC03 PARTIAL${NC}: internet=${internet_session}, ims=${ims_session}"
    info "To fully support 'ims' DNN, add it to config/smf.yaml and rebuild."
fi
