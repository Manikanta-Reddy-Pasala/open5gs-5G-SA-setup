# open5GS 5G SA Core - Portable Docker Deployment

A fully self-contained 5G Standalone (SA) core network built from source using [open5GS](https://open5gs.org/) v2.7.5, mirroring the free5gc-5G-SA-setup structure. Runs as 5 Docker containers with a single management script.

---

## What is open5GS?

[open5GS](https://open5gs.org/) is an open-source C-language implementation of the 5G Core and EPC (4G) specifications. It implements the full 5G SA core including NRF, AMF, SMF, UPF, UDM, UDR, AUSF, PCF, NSSF, BSF, and SCP. Unlike free5GC (Go), open5GS is written in C using the meson build system and ships a built-in WebUI for subscriber management.

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │          open5gs-cp (10.200.100.16)          │
  ┌──────────────┐      │                                               │
  │ open5gs-     │      │  NRF:7777  SCP:7778  AMF:7780  SMF:7781     │
  │ mongodb      │◄─────│  PCF:7782  NSSF:7783 AUSF:7784 UDM:7785     │
  │ (MongoDB)    │      │  UDR:7786  BSF:7787                           │
  └──────────────┘      │                                               │
                        │  NGAP/SCTP: 38412 (to gNB)                  │
                        │  AMF dials OUT → cnode server (no inbound)  │
                        └──────────────┬──────────────────────────────┘
                                       │ PFCP
                        ┌──────────────▼──────────────────────────────┐
                        │          open5gs-upf (10.200.100.17)         │
  ┌──────────────┐      │                                               │
  │ open5gs-     │      │  GTP-U tunnel                                 │
  │ webui        │      │  ogstun: 10.206.0.1/16 (UE subnet)          │
  │ (port 4000)  │      │  iptables NAT → internet                     │
  └──────────────┘      └──────────────────────────────────────────────┘
                                       │
                        ┌──────────────▼──────────────────────────────┐
                        │    UERANSIM (optional, --profile ueransim)   │
                        │    nr-gnb + nr-ue simulator                  │
                        └─────────────────────────────────────────────┘

  Docker network: open5gs-net (10.200.100.0/24), bridge: br-open5gs
  UE subnet:      10.206.0.0/16 (ogstun TUN interface on UPF)
```

---

## Quick Start (5 Commands)

```bash
# 1. Build everything from source (~20 minutes first time)
./open5gs.sh build

# 2. Start the core (use --sst / --sd to override slice at runtime)
./open5gs.sh start
# ./open5gs.sh start --sst 1 --sd 111111   # override slice

# 3. Provision the default test subscriber
./open5gs.sh provision

# 4. Check all NFs are running
./open5gs.sh status

# 5. Start UERANSIM to simulate a gNB + UE
./open5gs.sh start --ueransim
```

---

## All Commands Reference

### Build

| Command | Description |
|---|---|
| `./open5gs.sh build` | Full source compile of open5GS + UERANSIM (~20 min) |
| `./open5gs.sh build --quick` | Rebuild Docker runtime images only (skip source compile) |

### Run

| Command | Description |
|---|---|
| `./open5gs.sh start` | Start core (MongoDB + CP + UPF + WebUI) |
| `./open5gs.sh start --ueransim` | Start core + UERANSIM gNB simulator |
| `./open5gs.sh start --debug` | Start with debug-level logging |
| `./open5gs.sh start --mcc 404 --mnc 30 --tac 1` | Start with custom PLMN |
| `./open5gs.sh start --sst 1 --sd 111111` | Start with custom slice (SST/SD) |
| `./open5gs.sh stop` | Stop all containers |
| `./open5gs.sh remove` | Remove all containers and volumes |

### Subscribers

| Command | Description |
|---|---|
| `./open5gs.sh provision` | Provision the default test subscriber |
| `./open5gs.sh bulk-provision --count 10` | Provision 10 subscribers (incremented IMSIs) |
| `./open5gs.sh bulk-provision --count 5 --same-key` | Provision 5 subscribers sharing the same K |

### UE (UERANSIM)

| Command | Description |
|---|---|
| `./open5gs.sh ue start` | Launch UE simulator inside UERANSIM container |
| `./open5gs.sh ue stop` | Stop UE simulator |
| `./open5gs.sh ue status` | Check UE PDU session status |

### Monitor

| Command | Description |
|---|---|
| `./open5gs.sh status` | Full status: containers, NRF registrations, network, subscribers |
| `./open5gs.sh logs` | Tail all container logs |
| `./open5gs.sh logs amf` | Tail AMF log only |
| `./open5gs.sh logs smf` | Tail SMF log |
| `./open5gs.sh logs upf` | Tail UPF log |
| `./open5gs.sh logs nrf` | Tail NRF log |
| `./open5gs.sh logs gnb` | Tail UERANSIM gNB log |

---

## Container Architecture

| Container | Image | Role | Fixed IP |
|---|---|---|---|
| `open5gs-mongodb` | `mongo:6.0` | Subscriber database | DHCP |
| `open5gs-cp` | `open5gs-cp-local:v2.7.5` | All 10 CP NFs | 10.200.100.16 |
| `open5gs-upf` | `open5gs-upf-local:v2.7.5` | User plane / GTP-U | 10.200.100.17 |
| `open5gs-webui` | `open5gs-webui-local:v2.7.5` | Subscriber management UI | DHCP |
| `open5gs-ueransim` | `open5gs-ueransim-local:latest` | gNB + UE simulator (optional) | DHCP |

All containers share the `open5gs-net` bridge network (`10.200.100.0/24`, bridge `br-open5gs`).

---

## NF Ports

| NF | SBI Port | Notes |
|---|---|---|
| NRF | 7777 | Network Repository Function - central registry |
| SCP | 7778 | Service Communication Proxy |
| AMF | 7780 | Access & Mobility Management; NGAP on 38412/sctp |
| SMF | 7781 | Session Management |
| PCF | 7782 | Policy Control |
| NSSF | 7783 | Network Slice Selection |
| AUSF | 7784 | Authentication Server |
| UDM | 7785 | Unified Data Management |
| UDR | 7786 | Unified Data Repository |
| BSF | 7787 | Binding Support Function |
| Metrics | 9090-9093 | Prometheus metrics (AMF/SMF/PCF/UPF) |

---

## Network Configuration

| Parameter | Value |
|---|---|
| Docker network | `open5gs-net` |
| Subnet | `10.200.100.0/24` |
| Bridge name | `br-open5gs` |
| CP container IP | `10.200.100.16` |
| UPF container IP | `10.200.100.17` |
| UE subnet (ogstun) | `10.206.0.0/16` |
| NGAP port | `38412/sctp` |
| WebUI port | `4000` |

---

## Default Subscriber

| Field | Value |
|---|---|
| IMSI | `001010000050641` |
| SUPI | `imsi-001010000050641` |
| MCC | `001` |
| MNC | `01` |
| K (key) | `0c57e15a2cb86087097a6b50d42531de` |
| OPC | `109ee52735ae6d3849112cf4175029c7` |
| AMF | `8000` |
| SST | `3` |
| SD | `198153` |
| DNN | `internet` |
| TAC | `1` |

---

## UERANSIM Usage

UERANSIM simulates a 5G gNB (base station) and UE (phone).

```bash
# Start core + UERANSIM gNB
./open5gs.sh start --ueransim

# Provision the subscriber first
./open5gs.sh provision

# Start the UE (attach to network)
./open5gs.sh ue start

# Check UE PDU session
./open5gs.sh ue status

# Test data connectivity from inside the UE container
docker exec -it open5gs-ueransim bash
# Inside container:
./nr-cli imsi-001010000050641 --exec "ps-list"
```

The gNB config is at `config/gnb.yaml`, UE config at `config/ue.yaml`. Both connect to the AMF at `open5gs-cp:38412`.

---

## WebUI

The open5GS WebUI provides a browser-based subscriber management interface.

- **URL**: `http://<host-ip>:4000`
- **Login**: `admin` / `1423`
- **Features**: Add/edit/delete subscribers, view sessions, manage slices

The WebUI connects directly to MongoDB and provides a visual alternative to CLI provisioning.

---

## Build Process

The build uses a multi-stage Docker approach:

1. **Stage 1** (`Dockerfile.build-all`, open5gs-builder): Ubuntu 22.04, installs build deps, clones open5GS v2.7.5, compiles with meson/ninja, installs to `/output`
2. **Stage 2** (`Dockerfile.build-all`, ueransim-builder): Installs CMake 3.28.3, clones UERANSIM master, builds with make
3. **Stage 3** (`Dockerfile.build-all`, export): Collects all binaries into `/output`, CMD copies to mounted `/export`
4. **Runtime images**: `Dockerfile.cp-local`, `Dockerfile.upf-local`, `Dockerfile.ueransim-local` copy binaries from `build-output/` into minimal Ubuntu 22.04 runtime images

```
build-output/
  open5gs/
    bin/     ← open5gs-amfd, open5gs-smfd, open5gs-nrfd, ...
    lib/     ← shared libraries
  ueransim/
    nr-gnb, nr-ue, nr-cli
    binder/  ← nr-binder, libdevbnd.so
  BUILD_MANIFEST.txt
```

---

## AMF Custom Fork — cnode Registration & Health Check

This repo ships a **forked open5GS AMF** with an outbound cnode client grafted in, implementing the same registration + health-check protocol as the working MME (`CnmSendNodeType` / `sendData` / `recvData`).

### Architecture

The AMF dials **out** to the cnode registration server — there is **no inbound TCP server** on the AMF. Health checks flow back on the same persistent connection:

```
AMF  ──(TCP dial)────────────────────►  cnode server
AMF  ──NodeType_Message { AMF(13) }──►  server registers the AMF
                                         server sends HealthCheckRequest
AMF  ◄──────HealthCheckRequest ──────── (same TCP connection)
AMF  ──────HealthCheckResponse ─────►   { status: SERVING }
         (reconnects with exponential backoff: 1→2→4→…→30 s)
```

### Wire Format

Matches MME `sendData()` / `recvData()` exactly — **fixed 4-byte LE length header**:

```
[ uint32_t payload_length (4 bytes, native little-endian) ][ proto payload ]
```

| Message | Direction | Proto bytes | Full frame |
|---|---|---|---|
| `NodeType_Message { nodetype: AMF=13 }` | AMF → server | `08 0D` | `02 00 00 00  08 0D` |
| `HealthCheckRequest { service: "" }` | server → AMF | `0A 00` | `02 00 00 00  0A 00` |
| `HealthCheckResponse { status: SERVING=1 }` | AMF → server | `08 01` | `02 00 00 00  08 01` |

### Configuration

Set env vars in `docker-compose.yaml` under `open5gs-cp.environment`:

| Env var | Default | Description |
|---|---|---|
| `AMF_CNODE_ENABLE` | `1` | `1` = enabled, any other value = disabled |
| `AMF_CNODE_SERVER_IP` | _(unset)_ | cnode server IPv4 — **required to activate** |
| `AMF_CNODE_SERVER_PORT` | `9090` | cnode server TCP port |

If `AMF_CNODE_SERVER_IP` is unset the client is silently disabled and AMF starts normally.

**Example:**
```yaml
# docker-compose.yaml, under open5gs-cp environment:
AMF_CNODE_ENABLE: "1"
AMF_CNODE_SERVER_IP: "192.168.1.100"
AMF_CNODE_SERVER_PORT: "9090"
```

### Fork structure

```
NFs/amf/
└── cnode/
    ├── amf_cnode.h   # Public API: amf_cnode_start() / amf_cnode_stop()
    └── amf_cnode.c   # Outbound client: dial, NodeType_Message, poll loop, backoff
```

Patches applied by `Dockerfile.build-all` at build time (**two files only**):

| File | Change |
|---|---|
| `src/amf/meson.build` | Add `cnode/amf_cnode.c` to sources + `dependency('threads')` |
| `src/amf/init.c` | `#include "cnode/amf_cnode.h"`; call `amf_cnode_start()` on init, `amf_cnode_stop()` on terminate |

No upstream open5GS files are stored in this repo — only the cnode source and the patch script in `Dockerfile.build-all`.

### Testing with the mock server

`tests/cnode_mock_server.py` is a standalone Python server that implements the cnode server side. Use it to test the AMF registration + health-check flow without a real cnode deployment.

#### Quick test (one connection, 3 health checks)

```bash
# Terminal 1 — start mock server on port 9090
python3 tests/cnode_mock_server.py --port 9090

# Terminal 2 — start open5gs with cnode pointed at the mock server
# (add to docker-compose.yaml under open5gs-cp environment, then start)
AMF_CNODE_SERVER_IP=<host-ip>  AMF_CNODE_SERVER_PORT=9090 ./open5gs.sh start
```

Expected mock server output:
```
[mock cnode server] listening on 0.0.0.0:9090
[mock cnode server] session 1: connection from 10.200.100.16:xxxxx
  [server] ✓ NodeType_Message  nodetype=13 (AMF)
           frame: [02 00 00 00 08 0d]
  [server] → HealthCheckRequest  frame: [02 00 00 00 0a 00]
  [server] ← HealthCheckResponse  status=1 (SERVING) ✓
           frame: [02 00 00 00 08 01]
  ... (repeated --count times)
[mock cnode server] session 1: ✅ PASS
```

#### Test reconnect / backoff

```bash
# Start server that loops, accepting multiple reconnects
python3 tests/cnode_mock_server.py --port 9090 --loop --count 2 --interval 1

# Kill and restart the server mid-session to observe AMF reconnect with backoff
# AMF log will show:
#   [AMF-cnode] session ended; reconnecting in 1s
#   [AMF-cnode] connected to <ip>:9090
#   [AMF-cnode] registered as AMF ...
```

#### Standalone wire-format test (no Docker needed)

Runs C binary directly against the mock server to verify wire format without a full open5gs build:

```bash
# Terminal 1
python3 tests/cnode_mock_server.py --port 9090 --count 1

# Terminal 2 — compile and run the standalone C test client
gcc -o /tmp/cnode_test tests/cnode_mock_server.py  # (see below — use the C file)
# or run TC09 which includes a self-contained handshake simulation:
bash tests/tc09_amf_health_check.sh
```

#### Mock server options

| Flag | Default | Description |
|---|---|---|
| `--port` | `9090` | TCP port to listen on |
| `--interval` | `2.0` | Seconds between health checks |
| `--count` | `3` | Health checks per session (`0` = infinite) |
| `--loop` | off | Keep accepting new connections after disconnect |

---

## Comparison: open5GS vs free5GC

| Feature | open5GS | free5GC |
|---|---|---|
| Language | C | Go |
| Build system | meson + ninja | Go modules |
| Version | v2.7.5 | v3.x |
| NRF | open5gs-nrfd | nrf |
| SCP | open5gs-scpd | scp |
| AMF | open5gs-amfd | amf |
| SMF | open5gs-smfd | smf |
| UPF | open5gs-upfd | upf (C, separate) |
| AUSF | open5gs-ausfd | ausf |
| UDM | open5gs-udmd | udm |
| UDR | open5gs-udrd | udr |
| PCF | open5gs-pcfd | pcf |
| NSSF | open5gs-nssfd | nssf |
| BSF | open5gs-bsfd | (not in free5GC) |
| WebUI | Built-in (Node.js/Next.js) | Separate webui container |
| Database | MongoDB (subscribers + PCF + BSF) | MongoDB (subscribers only) |
| UE subnet | 10.206.0.0/16 (ogstun) | 10.60.0.0/24 (upfgtp) |
| Config format | YAML | YAML |
| Docker network | 10.200.100.0/24 | 10.100.200.0/24 |
| CP IP | 10.200.100.16 | 10.100.200.16 |
| UPF IP | 10.200.100.17 | 10.100.200.17 |
| Health check | AMF cnode outbound client (forked) | AMF cnode outbound client (forked) |
| NGAP port | 38412 | 38412 |
| WebUI port | 4000 | 5000 |

---

## Troubleshooting

### CP container not becoming healthy

```bash
# Check what's failing inside the container
./open5gs.sh logs nrf
./open5gs.sh logs amf

# Check if MongoDB is reachable
docker exec open5gs-cp nc -z db 27017 && echo "MongoDB OK"

# Force restart
./open5gs.sh stop && ./open5gs.sh start
```

### NRF not responding

```bash
# Direct API check inside container
docker exec open5gs-cp wget -qO- http://127.0.0.1:7777/nnrf-nfm/v1/nf-instances

# Check NRF log for errors
docker exec open5gs-cp tail -50 /var/log/open5gs/nrf.log
```

### UPF failing to start (TUN interface)

The UPF requires `NET_ADMIN` capability and `/dev/net/tun`. Ensure Docker host supports TUN:

```bash
ls -la /dev/net/tun
# Should exist; if not: modprobe tun

# Check UPF logs
./open5gs.sh logs upf
```

### UERANSIM gNB cannot reach AMF

```bash
# Verify SCTP DNAT rules are set
iptables -t nat -L PREROUTING -n | grep 38412

# Check AMF is listening on NGAP
docker exec open5gs-cp ss -lnp | grep 38412

# Re-apply SCTP rules
./open5gs.sh stop && ./open5gs.sh start --ueransim
```

### Subscriber not found during registration

```bash
# Check subscriber was provisioned
./open5gs.sh status
# Look for "Total subscribers in DB"

# Re-provision
./open5gs.sh provision

# Verify in MongoDB directly
docker exec open5gs-mongodb mongosh 'mongodb://localhost:27017/open5gs' \
  --quiet --eval "db.subscribers.find({},{imsi:1}).forEach(printjson)"
```

### Build fails (meson version)

The build image installs meson via pip3 to get the latest version. If you see meson errors:

```bash
# Check meson version inside builder
docker run --rm open5gs-builder:v2.7.5 meson --version

# Force full rebuild
docker rmi open5gs-builder:v2.7.5
./open5gs.sh build
```

### WebUI not loading

```bash
# Check WebUI container logs
./open5gs.sh logs webui

# Verify port binding
docker port open5gs-webui

# Check MongoDB connectivity from WebUI
docker exec open5gs-webui nc -z db 27017 && echo "DB OK"
```

---

## Directory Structure

```
open5gs-5G-SA-setup/
├── open5gs.sh                  # Main management script
├── docker-compose.yaml         # Service definitions
├── Dockerfile.build-all        # Multi-stage source builder (applies AMF fork patch)
├── Dockerfile.cp-local         # CP runtime image
├── Dockerfile.upf-local        # UPF runtime image
├── Dockerfile.webui            # WebUI image (Node.js)
├── Dockerfile.ueransim-local   # UERANSIM runtime image
├── NFs/
│   └── amf/
│       └── cnode/
│           ├── amf_cnode.h     # AMF fork: cnode client API header
│           └── amf_cnode.c     # AMF fork: outbound registration + health-check client
├── consolidated/
│   ├── start-cp-nfs.sh         # CP startup script (all 10 NFs)
│   └── start-upf.sh            # UPF startup + TUN setup
├── config/                     # Info-level configs (default)
│   ├── nrf.yaml, scp.yaml, amf.yaml, smf.yaml, upf.yaml
│   ├── ausf.yaml, udm.yaml, udr.yaml, pcf.yaml, nssf.yaml, bsf.yaml
│   ├── gnb.yaml                # UERANSIM gNB config
│   └── ue.yaml                 # UERANSIM UE config
├── config-debug/               # Debug-level configs (--debug flag)
│   └── (same files, level: debug)
├── build-output/               # Generated by build (git-ignored)
│   ├── open5gs/bin/            # All open5GS NF binaries (AMF includes health check)
│   ├── open5gs/lib/            # Shared libraries
│   └── ueransim/               # nr-gnb, nr-ue, nr-cli
├── tests/                      # Automated test suite
│   ├── common.sh               # Shared helpers (provisioning, UERANSIM, PLMN detection)
│   ├── run_all.sh              # Test runner (all or specific TCs)
│   ├── tc01_parallel_registration.sh
│   ├── tc02_crash_recovery.sh
│   ├── tc03_multi_apn.sh
│   ├── tc04_multi_ue_deregistration.sh
│   ├── tc05_paging_idle_ue.sh
│   ├── tc06_ue_context_release.sh
│   ├── tc07_ran_config_update.sh
│   ├── tc08_ng_reset.sh
│   ├── tc09_amf_health_check.sh
│   ├── tc10_memory_leak.sh
│   ├── logs/                   # Per-run test logs (git-ignored)
│   └── README.md               # Test suite documentation
└── logs/                       # Runtime logs (git-ignored)
    ├── cp/                     # Per-NF log files
    └── upf/                    # UPF log file
```

---

## Test Suite

A full automated test suite is included in `tests/`. Tests run against the live Docker deployment and cover registration, recovery, multi-UE, multi-APN, paging, NG Reset, and the custom AMF health check.

### Quick Start

```bash
# Ensure core + UERANSIM are running first
./open5gs.sh start --ueransim
./open5gs.sh provision

# Run all 10 tests
cd tests && ./run_all.sh

# Run specific tests
./run_all.sh 1 4 9

# Run a single test directly
bash tests/tc09_amf_health_check.sh

# List all tests
./run_all.sh --list
```

### Test Cases at a Glance

| # | Test | What it verifies |
|---|------|-----------------|
| TC01 | Parallel Registration | N UEs register simultaneously |
| TC02 | Crash Recovery | Core recovers after UPF/CP/MongoDB restart |
| TC03 | Multi-APN | UE holds sessions on both `internet` + `ims` DNNs |
| TC04 | Multi-UE Deregistration | N UEs deregister simultaneously |
| TC05 | Paging / Idle UE | AMF pages idle UE on downlink data |
| TC06 | UE Context Release | Ungraceful (RLF) + graceful deregister |
| TC07 | RAN Config Update | TAC change: gNB reconnects with new TAC |
| TC08 | NG Reset | gNB graceful restart + forced kill recovery |
| **TC09** | **AMF cnode** | **AMF connects to cnode server, registers, responds SERVING** |
| TC10 | Memory / Stability | Register/deregister cycles, memory growth < 20% |

> **TC09 is unique to this deployment** — it validates the custom AMF fork's cnode outbound registration + health-check client. See [AMF Custom Fork](#amf-custom-fork--cnode-registration--health-check) for details.

Test logs are saved to `tests/logs/` with timestamps. See [`tests/README.md`](tests/README.md) for full documentation.

---

## Comparison: open5GS vs free5GC

| Feature | open5GS (this repo) | free5GC |
|---------|---------------------|---------|
| Language | C (meson/ninja) | Go |
| Version | v2.7.5 | v4.x |
| Containers | 5 (MongoDB, CP, UPF, WebUI, UERANSIM) | 5 |
| Provisioning | Direct MongoDB (`mongosh`) | WebUI REST API |
| Slice (default) | SST=3, SD=198153 | SST=3, SD=198153 |
| WebUI | Port 4000, admin/1423 | Port 4000, admin/free5gc |
| AMF Health Check | ✅ cnode outbound client (custom fork) | ✅ cnode outbound client (custom fork) |
| Test suite | ✅ 10 TCs (`tests/`) | ✅ 10 TCs (`tests/`) |
