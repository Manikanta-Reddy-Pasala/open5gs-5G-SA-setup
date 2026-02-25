#!/bin/bash
# ============================================================
# TC10: Memory Leak / Long-running Stability
# Register/deregister UEs in cycles and monitor memory growth
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CYCLES="${1:-10}"
NUM_UES="${2:-3}"
LEAK_THRESHOLD=20   # fail if memory grows > 20%
WARN_THRESHOLD=10   # warn if memory grows > 10%

header "TC10: Memory Leak / Stability (${CYCLES} cycles, ${NUM_UES} UEs)"

ensure_core_running

# Step 1: Provision subscribers
info "Provisioning ${NUM_UES} test subscribers..."
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    provision_subscriber "$supi_num" "$k" "$OPC"
done
pass "Provisioned ${NUM_UES} subscribers"

# Step 2: Capture baseline memory
info "Capturing baseline memory usage..."
get_mem() {
    local container="$1"
    docker stats "$container" --no-stream --format "{{.MemUsage}}" 2>/dev/null | \
        awk -F'[/ ]' '{print $1}' | sed 's/MiB//' | sed 's/GiB/*1024/' | \
        python3 -c "import sys; s=sys.stdin.read().strip(); print(eval(s) if s else 0)" 2>/dev/null || echo 0
}

MEM_CP_START=$(get_mem open5gs-cp)
MEM_UPF_START=$(get_mem open5gs-upf)
MEM_DB_START=$(get_mem open5gs-mongodb)
MEM_UE_START=$(get_mem open5gs-ueransim)

info "Baseline memory (MiB):"
printf "    %-25s %s\n" "open5gs-cp:"     "$MEM_CP_START"
printf "    %-25s %s\n" "open5gs-upf:"    "$MEM_UPF_START"
printf "    %-25s %s\n" "open5gs-mongodb:" "$MEM_DB_START"
printf "    %-25s %s\n" "open5gs-ueransim:" "$MEM_UE_START"

# Prepare UE config files
TMPDIR=$(mktemp -d)
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    generate_ue_config "$supi_num" "$k" "$OPC" "${TMPDIR}/ue${i}.yaml" "internet"
    docker cp "${TMPDIR}/ue${i}.yaml" open5gs-ueransim:/ueransim/config/ue_mem${i}.yaml
done

# Step 3: Run register/deregister cycles
info "Starting ${CYCLES} register/deregister cycles..."
REPORT_FILE="$TESTS_DIR/logs/memory_report_$(date '+%Y%m%d_%H%M%S').txt"
mkdir -p "$TESTS_DIR/logs"

{
echo "open5GS Memory Leak Test Report"
echo "Date: $(date)"
echo "Cycles: ${CYCLES}, UEs per cycle: ${NUM_UES}"
echo ""
echo "Baseline: CP=${MEM_CP_START}MiB  UPF=${MEM_UPF_START}MiB  DB=${MEM_DB_START}MiB  UE=${MEM_UE_START}MiB"
echo ""
echo "Cycle | CP(MiB) | UPF(MiB) | DB(MiB) | UE(MiB)"
echo "------|---------|----------|---------|--------"
} > "$REPORT_FILE"

for (( cycle=1; cycle<=CYCLES; cycle++ )); do
    # Register all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        docker exec -d open5gs-ueransim ./nr-ue -c ./config/ue_mem${i}.yaml
    done
    sleep 12

    # Verify at least some registered
    reg=0
    for (( i=0; i<NUM_UES; i++ )); do
        supi_num=$(supi_add "$BASE_SUPI" "$i")
        imsi="imsi-${supi_num}"
        status=$(docker exec open5gs-ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
        echo "$status" | grep -q "RM-REGISTERED" && reg=$((reg + 1))
    done

    # Deregister all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        supi_num=$(supi_add "$BASE_SUPI" "$i")
        imsi="imsi-${supi_num}"
        docker exec open5gs-ueransim ./nr-cli "$imsi" -e "deregister normal" 2>/dev/null &
    done
    wait
    sleep 8
    kill_all_ues

    # Snapshot memory every 5 cycles
    if [ $((cycle % 5)) -eq 0 ] || [ "$cycle" -eq "$CYCLES" ]; then
        cp_mem=$(get_mem open5gs-cp)
        upf_mem=$(get_mem open5gs-upf)
        db_mem=$(get_mem open5gs-mongodb)
        ue_mem=$(get_mem open5gs-ueransim)
        printf "  Cycle %2d: CP=%.1fMiB UPF=%.1fMiB DB=%.1fMiB UE=%.1fMiB (registered: %d/%d)\n" \
            "$cycle" "$cp_mem" "$upf_mem" "$db_mem" "$ue_mem" "$reg" "$NUM_UES"
        printf "%5d | %7.1f | %8.1f | %7.1f | %7.1f\n" \
            "$cycle" "$cp_mem" "$upf_mem" "$db_mem" "$ue_mem" >> "$REPORT_FILE"
    else
        printf "  Cycle %2d/%d (registered: %d/%d)\r" "$cycle" "$CYCLES" "$reg" "$NUM_UES"
    fi
done
echo ""

# Step 4: Capture final memory
MEM_CP_END=$(get_mem open5gs-cp)
MEM_UPF_END=$(get_mem open5gs-upf)
MEM_DB_END=$(get_mem open5gs-mongodb)
MEM_UE_END=$(get_mem open5gs-ueransim)

# Step 5: Calculate growth and report
calc_growth() {
    local start="$1" end="$2"
    python3 -c "
s,e = float('${start}' or 0), float('${end}' or 0)
if s > 0:
    print(f'{((e-s)/s*100):+.1f}%')
else:
    print('N/A')
" 2>/dev/null || echo "N/A"
}

cp_growth=$(calc_growth "$MEM_CP_START" "$MEM_CP_END")
upf_growth=$(calc_growth "$MEM_UPF_START" "$MEM_UPF_END")
db_growth=$(calc_growth "$MEM_DB_START" "$MEM_DB_END")

{
echo ""
echo "Final: CP=${MEM_CP_END}MiB  UPF=${MEM_UPF_END}MiB  DB=${MEM_DB_END}MiB  UE=${MEM_UE_END}MiB"
echo "Growth: CP=${cp_growth}  UPF=${upf_growth}  DB=${db_growth}"
} >> "$REPORT_FILE"

echo ""
info "Memory growth after ${CYCLES} cycles:"
printf "    %-20s start=%s MiB  end=%s MiB  growth=%s\n" "open5gs-cp:"    "$MEM_CP_START" "$MEM_CP_END"  "$cp_growth"
printf "    %-20s start=%s MiB  end=%s MiB  growth=%s\n" "open5gs-upf:"   "$MEM_UPF_START" "$MEM_UPF_END" "$upf_growth"
printf "    %-20s start=%s MiB  end=%s MiB  growth=%s\n" "open5gs-mongodb:" "$MEM_DB_START" "$MEM_DB_END"  "$db_growth"

# Cleanup
rm -rf "$TMPDIR"

# Evaluate result
cp_pct=$(python3 -c "
s,e = float('${MEM_CP_START}' or 1), float('${MEM_CP_END}' or 0)
print(int((e-s)/s*100) if s>0 else 0)
" 2>/dev/null || echo 0)

info "Report saved to: $REPORT_FILE"

echo ""
if [ "${cp_pct:-0}" -gt "$LEAK_THRESHOLD" ]; then
    echo -e "${RED}${BOLD}TC10 FAILED${NC}: CP memory grew by ${cp_pct}% (> ${LEAK_THRESHOLD}% threshold)"
elif [ "${cp_pct:-0}" -gt "$WARN_THRESHOLD" ]; then
    echo -e "${YELLOW}${BOLD}TC10 WARNING${NC}: CP memory grew by ${cp_pct}% (> ${WARN_THRESHOLD}% — monitor)"
else
    echo -e "${GREEN}${BOLD}TC10 PASSED${NC}: Memory growth within acceptable limits (CP: ${cp_growth})"
fi
