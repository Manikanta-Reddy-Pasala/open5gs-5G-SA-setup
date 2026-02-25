# open5GS Test Suite

A comprehensive bash test suite for the open5GS 5G SA Core deployment.

## Prerequisites

- Core must be running: `./open5gs.sh start --ueransim`
- All containers healthy: `./open5gs.sh status`
- UERANSIM container (`open5gs-ueransim`) must be active for UE tests

## Quick Start

```bash
# Run all 10 tests
cd tests && ./run_all.sh

# Run specific tests by number
./run_all.sh 1 3 9

# List available tests
./run_all.sh --list

# Run individual test
bash tc01_parallel_registration.sh

# Run with custom args
bash tc01_parallel_registration.sh 10    # 10 UEs instead of default 5
bash tc04_multi_ue_deregistration.sh 5   # 5 UEs
bash tc10_memory_leak.sh 20 5            # 20 cycles, 5 UEs
```

## Test Cases

| # | Script | Purpose | Default Args |
|---|--------|---------|--------------|
| TC01 | `tc01_parallel_registration.sh` | Register N UEs simultaneously | 5 UEs |
| TC02 | `tc02_crash_recovery.sh` | UPF/CP/MongoDB crash & recovery | — |
| TC03 | `tc03_multi_apn.sh` | Dual-DNN session (internet + ims) | — |
| TC04 | `tc04_multi_ue_deregistration.sh` | Deregister N UEs simultaneously | 3 UEs |
| TC05 | `tc05_paging_idle_ue.sh` | CM-IDLE paging trigger test | — |
| TC06 | `tc06_ue_context_release.sh` | RLF (kill) + graceful deregister | — |
| TC07 | `tc07_ran_config_update.sh` | TAC change + gNB reconnect | — |
| TC08 | `tc08_ng_reset.sh` | NG Reset (graceful + forced) | — |
| TC09 | `tc09_amf_health_check.sh` | AMF TCP health check on port 50051 | — |
| TC10 | `tc10_memory_leak.sh` | Register/deregister memory stability | 10 cycles, 3 UEs |

## Test Details

### TC01 — Parallel UE Registration
Provisions N subscribers in MongoDB, generates unique UERANSIM configs, launches all UEs simultaneously, then verifies each reaches `RM-REGISTERED` state.

### TC02 — Crash Recovery
Three sub-tests:
- **Test A**: Restart UPF mid-session, verify UE re-registers
- **Test B**: Restart CP (all NFs), wait for healthy, verify UE re-registers
- **Test C**: Restart MongoDB, recover CP, verify UE re-registers

### TC03 — Multi-APN (Two DNNs)
Provisions subscriber with `internet` + `ims` sessions in MongoDB. Launches UE with dual-DNN config and verifies both PDU sessions are established. Checks for two `uesimtun` TUN interfaces.

> **Note**: Requires `ims` DNN configured in `config/smf.yaml`. Falls back to manual `ps-establish` if auto-setup fails.

### TC04 — Multi-UE De-Registration
Registers N UEs simultaneously, then sends `deregister normal` to all concurrently, and verifies each reaches `RM-DEREGISTERED` (or process exits cleanly).

### TC05 — Paging / Idle UE
Registers UE, waits for CM-IDLE transition (up to 90s), pings the UE IP from UPF to trigger paging, checks AMF logs for Paging messages, and verifies UE transitions back to CM-CONNECTED.

> **Note**: UERANSIM UE may not auto-enter CM-IDLE until the inactivity timer expires (configurable in AMF).

### TC06 — UE Context Release
Tests two release paths:
1. **Ungraceful (RLF)**: Kill nr-ue process with `pkill -9`, check AMF detects and cleans up
2. **Graceful**: Send `deregister normal` via nr-cli, verify `RM-DEREGISTERED`

### TC07 — RAN Configuration Update
Reads current TAC from gnb.yaml, increments it, updates both AMF config and gNB config, restarts both containers, verifies gNB re-establishes NG Setup and UE reports the new TAC. Restores original TAC at the end.

### TC08 — NG Reset
**Phase 1** (graceful): Restart UERANSIM container, check AMF detects SCTP state change, verify gNB re-does NG Setup, verify UE re-registers.

**Phase 2** (forced): Kill nr-gnb with `pkill -9`, restart container, verify recovery.

### TC09 — AMF TCP Health Check ⭐
Tests the custom AMF TCP health check server (fork-specific feature):

1. Verifies `AMF_GRPC_ENABLE=1` env var
2. Checks port 50051 is listening in container
3. **Plain probe**: Connect, recv → expects `0x020801` (SERVING)
4. **Full protocol**: Send `HealthCheckRequest{}` (length-prefixed empty proto), verify SERVING response
5. Checks AMF log for health server startup message
6. **Concurrency**: 5 simultaneous connections — all must return SERVING

Wire format: `[varint:N][proto-bytes]` where SERVING = `0x02 0x08 0x01`

### TC10 — Memory Leak / Stability
Runs N register/deregister cycles with M UEs each. Samples memory every 5 cycles using `docker stats`. Reports growth percentage for each container. Fails if CP memory grows > 20%, warns if > 10%. Saves timestamped report to `tests/logs/`.

## How Tests Work

- All scripts `source common.sh` for shared helpers
- `common.sh` auto-detects PLMN (MCC/MNC) from running gNB config
- Subscribers are provisioned directly into MongoDB using `mongosh` (open5GS schema)
- UERANSIM is managed via `docker exec open5gs-ueransim ./nr-cli <imsi> -e <cmd>`
- AMF logs are read from `/var/log/open5gs/amf.log` inside `open5gs-cp`
- Each test calls `ensure_core_running` to guarantee clean state before starting
- Test logs are saved to `tests/logs/` with timestamps

## Output Format

```
═══════════════════════════════════════════════════
  TC01: Parallel UE Registration (5 UEs)
═══════════════════════════════════════════════════

  INFO: Core is already running.
  INFO: Resetting UERANSIM gNB (clearing residual state)...
  PASS: Provisioned 5 subscribers
  PASS: UE imsi-001010000050641: REGISTERED
  PASS: UE imsi-001010000050642: REGISTERED
  ...
TC01 PASSED: All 5 UEs registered simultaneously
```

## Key Configuration Differences vs free5GC

| Parameter | open5GS | free5GC |
|-----------|---------|---------|
| Container (CP) | `open5gs-cp` | `free5gc-cp` |
| Container (DB) | `open5gs-mongodb` | `mongodb` |
| Container (UE) | `open5gs-ueransim` | `ueransim` |
| MongoDB CLI | `mongosh` | `mongo` |
| Database | `open5gs` | `free5gc` |
| UE config | `ue.yaml` | `uecfg.yaml` |
| gNB config | `gnb.yaml` | `gnbcfg.yaml` |
| Slice | SST=1, SD=111111 | SST=3, SD=198153 |
| WebUI port | 9999 | 4000 |
| Provisioning | Direct MongoDB | WebUI REST API |
| AMF health | Port 50051 (TC09) | — |

## Known Limitations

- **TC03 (Multi-APN)**: `ims` DNN requires explicit entry in `config/smf.yaml`
- **TC05 (Paging)**: UERANSIM may not auto-enter CM-IDLE (depends on AMF inactivity timer)
- **TC07 (RAN Config)**: TAC update modifies in-container config; restores after test
- **TC10 (Memory)**: Needs ≥10 cycles for statistically meaningful results
