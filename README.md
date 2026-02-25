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
                        └──────────────┬──────────────────────────────┘
                                       │ PFCP
                        ┌──────────────▼──────────────────────────────┐
                        │          open5gs-upf (10.200.100.17)         │
  ┌──────────────┐      │                                               │
  │ open5gs-     │      │  GTP-U tunnel                                 │
  │ webui        │      │  ogstun: 10.45.0.1/16 (UE subnet)           │
  │ (port 9999)  │      │  iptables NAT → internet                     │
  └──────────────┘      └──────────────────────────────────────────────┘
                                       │
                        ┌──────────────▼──────────────────────────────┐
                        │    UERANSIM (optional, --profile ueransim)   │
                        │    nr-gnb + nr-ue simulator                  │
                        └─────────────────────────────────────────────┘

  Docker network: open5gs-net (10.200.100.0/24), bridge: br-open5gs
  UE subnet:      10.45.0.0/16 (ogstun TUN interface on UPF)
```

---

## Quick Start (5 Commands)

```bash
# 1. Build everything from source (~20 minutes first time)
./open5gs.sh build

# 2. Start the core
./open5gs.sh start

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
| UE subnet (ogstun) | `10.45.0.0/16` |
| NGAP port | `38412/sctp` |
| WebUI port | `9999` |

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
| SST | `1` |
| SD | `111111` |
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

- **URL**: `http://<host-ip>:9999`
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
| UE subnet | 10.45.0.0/16 (ogstun) | 10.60.0.0/24 (upfgtp) |
| Config format | YAML | YAML |
| Docker network | 10.200.100.0/24 | 10.100.200.0/24 |
| CP IP | 10.200.100.16 | 10.100.200.16 |
| UPF IP | 10.200.100.17 | 10.100.200.17 |
| Health check | NRF HTTP API | AMF TCP/gRPC port 50051 |
| NGAP port | 38412 | 38412 |
| WebUI port | 9999 | 5000 |

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
├── Dockerfile.build-all        # Multi-stage source builder
├── Dockerfile.cp-local         # CP runtime image
├── Dockerfile.upf-local        # UPF runtime image
├── Dockerfile.webui            # WebUI image (Node.js)
├── Dockerfile.ueransim-local   # UERANSIM runtime image
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
│   ├── open5gs/bin/            # All open5GS NF binaries
│   ├── open5gs/lib/            # Shared libraries
│   └── ueransim/               # nr-gnb, nr-ue, nr-cli
└── logs/                       # Runtime logs (git-ignored)
    ├── cp/                     # Per-NF log files
    └── upf/                    # UPF log file
```
