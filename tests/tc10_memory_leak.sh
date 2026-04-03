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

MEM_CORE_START=$(get_mem "$CONTAINER_NAME")

info "Baseline memory (MiB):"
printf "    %-25s %s\n" "${CONTAINER_NAME}:" "$MEM_CORE_START"

# Prepare UE config files
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    k=$(hex_add "$BASE_K" "$i")
    generate_ue_config "$supi_num" "$k" "$OPC" "${UE_CONFIG_DIR}/ue_mem${i}.yaml" "internet"
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
echo "Baseline: Core=${MEM_CORE_START}MiB"
echo ""
echo "Cycle | Core(MiB)"
echo "------|----------"
} > "$REPORT_FILE"

for (( cycle=1; cycle<=CYCLES; cycle++ )); do
    # Register all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        "${UERANSIM_DIR}/nr-ue" -c "${UE_CONFIG_DIR}/ue_mem${i}.yaml" > "${UE_CONFIG_DIR}/ue_mem${i}.log" 2>&1 &
    done
    sleep 12

    # Verify at least some registered
    reg=0
    for (( i=0; i<NUM_UES; i++ )); do
        supi_num=$(supi_add "$BASE_SUPI" "$i")
        imsi="imsi-${supi_num}"
        status=$("${UERANSIM_DIR}/nr-cli" "$imsi" -e "status" 2>/dev/null)
        echo "$status" | grep -q "RM-REGISTERED" && reg=$((reg + 1))
    done

    # Deregister all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        supi_num=$(supi_add "$BASE_SUPI" "$i")
        imsi="imsi-${supi_num}"
        "${UERANSIM_DIR}/nr-cli" "$imsi" -e "deregister normal" 2>/dev/null &
    done
    wait
    sleep 8
    kill_all_ues

    # Snapshot memory every 5 cycles
    if [ $((cycle % 5)) -eq 0 ] || [ "$cycle" -eq "$CYCLES" ]; then
        core_mem=$(get_mem "$CONTAINER_NAME")
        printf "  Cycle %2d: Core=%.1fMiB (registered: %d/%d)\n" \
            "$cycle" "$core_mem" "$reg" "$NUM_UES"
        printf "%5d | %9.1f\n" \
            "$cycle" "$core_mem" >> "$REPORT_FILE"
    else
        printf "  Cycle %2d/%d (registered: %d/%d)\r" "$cycle" "$CYCLES" "$reg" "$NUM_UES"
    fi
done
echo ""

# Step 4: Capture final memory
MEM_CORE_END=$(get_mem "$CONTAINER_NAME")

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

core_growth=$(calc_growth "$MEM_CORE_START" "$MEM_CORE_END")

{
echo ""
echo "Final: Core=${MEM_CORE_END}MiB"
echo "Growth: Core=${core_growth}"
} >> "$REPORT_FILE"

echo ""
info "Memory growth after ${CYCLES} cycles:"
printf "    %-20s start=%s MiB  end=%s MiB  growth=%s\n" "${CONTAINER_NAME}:" "$MEM_CORE_START" "$MEM_CORE_END" "$core_growth"

# Evaluate result
core_pct=$(python3 -c "
s,e = float('${MEM_CORE_START}' or 1), float('${MEM_CORE_END}' or 0)
print(int((e-s)/s*100) if s>0 else 0)
" 2>/dev/null || echo 0)

info "Report saved to: $REPORT_FILE"

echo ""
if [ "${core_pct:-0}" -gt "$LEAK_THRESHOLD" ]; then
    echo -e "${RED}${BOLD}TC10 FAILED${NC}: Core memory grew by ${core_pct}% (> ${LEAK_THRESHOLD}% threshold)"
elif [ "${core_pct:-0}" -gt "$WARN_THRESHOLD" ]; then
    echo -e "${YELLOW}${BOLD}TC10 WARNING${NC}: Core memory grew by ${core_pct}% (> ${WARN_THRESHOLD}% — monitor)"
else
    echo -e "${GREEN}${BOLD}TC10 PASSED${NC}: Memory growth within acceptable limits (Core: ${core_growth})"
fi
