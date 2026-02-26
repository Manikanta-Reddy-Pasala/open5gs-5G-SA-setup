#!/bin/bash
# ============================================================
# run_all.sh - Run all open5GS test cases
# ============================================================
# Usage:
#   ./run_all.sh              # Run all tests
#   ./run_all.sh 1 3 5        # Run TC01, TC03, TC05 only
#   ./run_all.sh --list       # List available tests
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SUMMARY_LOG="$LOG_DIR/run_${TIMESTAMP}.log"

# Test registry
declare -A TC_NAME
TC_NAME[1]="Parallel Registration"
TC_NAME[2]="Crash Recovery"
TC_NAME[3]="Multi-APN (Two DNNs)"
TC_NAME[4]="Multi-UE De-Registration"
TC_NAME[5]="Paging / Idle UE"
TC_NAME[6]="UE Context Release"
TC_NAME[7]="RAN Config Update"
TC_NAME[8]="NG Reset"
TC_NAME[9]="AMF TCP Health Check"
TC_NAME[10]="Memory Leak / Stability"

declare -A TC_SCRIPT
TC_SCRIPT[1]="tc01_parallel_registration.sh"
TC_SCRIPT[2]="tc02_crash_recovery.sh"
TC_SCRIPT[3]="tc03_multi_apn.sh"
TC_SCRIPT[4]="tc04_multi_ue_deregistration.sh"
TC_SCRIPT[5]="tc05_paging_idle_ue.sh"
TC_SCRIPT[6]="tc06_ue_context_release.sh"
TC_SCRIPT[7]="tc07_ran_config_update.sh"
TC_SCRIPT[8]="tc08_ng_reset.sh"
TC_SCRIPT[9]="tc09_amf_health_check.sh"
TC_SCRIPT[10]="tc10_memory_leak.sh"

# Parse arguments
if [ "${1:-}" = "--list" ]; then
    echo ""
    echo -e "${BOLD}Available open5GS Test Cases:${NC}"
    echo ""
    for i in $(seq 1 10); do
        printf "  TC%02d: %s  [%s]\n" "$i" "${TC_NAME[$i]}" "${TC_SCRIPT[$i]}"
    done
    echo ""
    exit 0
fi

# Determine which tests to run
TESTS_TO_RUN=()
if [ $# -eq 0 ]; then
    TESTS_TO_RUN=(1 2 3 4 5 6 7 8 9 10)
else
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            TESTS_TO_RUN+=("$arg")
        fi
    done
fi

header "open5GS Test Suite"
echo "  Running ${#TESTS_TO_RUN[@]} test(s)"
echo "  Log: $SUMMARY_LOG"
echo ""

# Verify core is reachable before running tests
cp_state=$(docker inspect --format='{{.State.Status}}' open5gs-cp 2>/dev/null || echo "not found")
if [ "$cp_state" != "running" ]; then
    echo -e "${RED}ERROR: open5gs-cp is not running. Start with: ./open5gs.sh start --ueransim${NC}"
    exit 1
fi

# Run tests
declare -A RESULTS
for tc_num in "${TESTS_TO_RUN[@]}"; do
    script="${TC_SCRIPT[$tc_num]}"
    name="${TC_NAME[$tc_num]}"
    script_path="$SCRIPT_DIR/$script"
    tc_log="$LOG_DIR/tc$(printf '%02d' $tc_num)_${TIMESTAMP}.log"

    echo -e "${BOLD}Running TC$(printf '%02d' $tc_num): ${name}${NC}"

    if [ ! -f "$script_path" ]; then
        echo -e "  ${YELLOW}SKIP${NC}: Script not found: $script"
        RESULTS[$tc_num]="SKIP"
        continue
    fi

    # Run the test, capture output to log and display
    set +e
    bash "$script_path" 2>&1 | tee "$tc_log"
    exit_code=${PIPESTATUS[0]}
    set -e

    if grep -q "PASSED\|PASS\b" "$tc_log" 2>/dev/null; then
        RESULTS[$tc_num]="PASSED"
    elif grep -q "FAILED\|FAIL\b" "$tc_log" 2>/dev/null; then
        RESULTS[$tc_num]="FAILED"
    else
        RESULTS[$tc_num]="COMPLETED"
    fi

    echo ""
done

# Summary
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Suite Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo "" | tee -a "$SUMMARY_LOG"

passed=0
failed=0
skipped=0
for tc_num in "${TESTS_TO_RUN[@]}"; do
    result="${RESULTS[$tc_num]:-SKIP}"
    name="${TC_NAME[$tc_num]}"
    case "$result" in
        PASSED)
            printf "  ${GREEN}PASSED${NC}  TC%02d: %s\n" "$tc_num" "$name" | tee -a "$SUMMARY_LOG"
            passed=$((passed + 1))
            ;;
        FAILED)
            printf "  ${RED}FAILED${NC}  TC%02d: %s\n" "$tc_num" "$name" | tee -a "$SUMMARY_LOG"
            failed=$((failed + 1))
            ;;
        SKIP)
            printf "  ${YELLOW}SKIP${NC}    TC%02d: %s\n" "$tc_num" "$name" | tee -a "$SUMMARY_LOG"
            skipped=$((skipped + 1))
            ;;
        *)
            printf "  ${CYAN}DONE${NC}    TC%02d: %s\n" "$tc_num" "$name" | tee -a "$SUMMARY_LOG"
            ;;
    esac
done

echo "" | tee -a "$SUMMARY_LOG"
echo -e "  Total: ${#TESTS_TO_RUN[@]}  |  ${GREEN}Passed: ${passed}${NC}  |  ${RED}Failed: ${failed}${NC}  |  Skipped: ${skipped}" | tee -a "$SUMMARY_LOG"
echo -e "  Logs saved to: $LOG_DIR/" | tee -a "$SUMMARY_LOG"
echo ""

[ "$failed" -eq 0 ]
