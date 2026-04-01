# open5GS 5G SA Core - Multi-TRX Host Networking

A multi-instance 5G Standalone (SA) core network built from source using [open5GS](https://open5gs.org/) v2.7.5. Each TRX instance runs **all 11 NFs in a single container** with host networking — no NAT, no port mapping. Instances are identified by their TRX IP address.

---

## Architecture

```
  Host (e.g., <HOST_IP>)
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  MongoDB (host)  ◄── all instances share one DB              │
  │  127.0.0.1:27017                                             │
  │                                                              │
  │  Physical NIC: eth0 (<SUBNET>)                               │
  │  + secondary IPs added per instance                          │
  │                                                              │
  │    ┌── trx-10.100.0.11 (single container, host net) ──┐     │
  │    │  10 CP NFs + UPF   TRX: 10.100.0.11              │     │
  │    │  ogstun11           UPF: 10.100.0.12              │     │
  │    └───────────────────────────────────────────────────┘     │
  │                                                              │
  │    ┌── trx-10.100.0.13 (single container, host net) ──┐     │
  │    │  10 CP NFs + UPF   TRX: 10.100.0.13              │     │
  │    │  ogstun13           UPF: 10.100.0.14              │     │
  │    └───────────────────────────────────────────────────┘     │
  │                                                              │
  │  Logs: /opt/logs/cn/trx-10.100.0.11/                        │
  │        /opt/logs/cn/trx-10.100.0.13/  ...                   │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  gNB connects directly to secondary IPs:
    TRX1 gNB ──► 10.100.0.11:38412 (NGAP)  +  10.100.0.12:2152 (GTP-U)
    TRX2 gNB ──► 10.100.0.13:38412          +  10.100.0.14:2152
```

### Single-container design

Each instance runs **one container** (`trx-<IP>`) with all 11 NFs:

| NFs in container | Count | Role |
|---|---|---|
| NRF, SCP, AMF, SMF, PCF, NSSF, AUSF, UDM, UDR, BSF | 10 | Control Plane |
| UPF | 1 | User Plane (GTP-U + TUN) |

### Host networking

Containers use `network_mode: host` — all NFs bind directly to secondary IPs added to the host's physical interface. No Docker bridge, no macvlan, no NAT.

### How IPs flow from CLI to NF configs

When you run:
```bash
./scripts/start.sh --trx-ip 10.100.0.11 --upf-ip 10.100.0.12
```

1. **Network detection** — auto-detects host interface from the TRX IP
2. **Secondary IPs** — adds TRX IP and UPF IP to the host interface
3. **Instance name** — derived from TRX IP: `trx-10.100.0.11`
4. **TUN device** — derived from last octet: `ogstun11`
5. **Config templates patched** — placeholders in `config/*.yaml` get replaced:
   ```
   __CP_IP__      → 10.100.0.11    (AMF NGAP bind, all SBI binds)
   __UPF_IP__     → 10.100.0.12    (UPF GTP-U bind, PFCP bind)
   __MONGO_HOST__ → 127.0.0.1      (localhost MongoDB)
   __UE_SUBNET__  → 10.45.0.0/16   (UE pool)
   __UE_GW__      → 10.45.0.1      (UE gateway on TUN)
   __TUN_DEV__    → ogstun11        (unique per instance)
   ```
6. **`.env` file generated** at `instances/trx-10.100.0.11/.env`
7. **Log directory created** at `/opt/logs/cn/trx-10.100.0.11/`
8. **`docker compose up`** starts the single container
9. **UE routing** — adds route for UE subnet via UPF IP + iptables NAT

---

## Quick Start

```bash
# 1. Build open5GS from source + runtime image (~20 min first time)
./scripts/build.sh

# 2. Start a CN instance
./scripts/start.sh --trx-ip 10.100.0.11 --upf-ip 10.100.0.12

# 3. Provision the default test subscriber
./scripts/provision.sh

# 4. Check status
./scripts/status.sh --trx-ip 10.100.0.11

# 5. View logs
./scripts/logs.sh --trx-ip 10.100.0.11 amf

# 6. Start more instances (different IPs, different UE pools)
./scripts/start.sh --trx-ip 10.100.0.13 --upf-ip 10.100.0.14 \
    --ue-subnet 10.46.0.0/16 --ue-gw 10.46.0.1

# 7. Stop and remove
./scripts/stop.sh --trx-ip 10.100.0.11 --rm
```

---

## Scripts Reference

All scripts are in `scripts/`. Run from the repo root.

### build.sh — Compile open5GS + build runtime image

Builds open5GS v2.7.5 from source using Docker, then builds the unified runtime image.

```bash
./scripts/build.sh              # Full build: source compile + runtime image
./scripts/build.sh --quick      # Skip source compile, rebuild runtime image only
```

Three steps:
1. `Dockerfile.build` — compiles open5GS from source (meson/ninja), applies AMF cnode patches
2. Extracts binaries to `build-output/`
3. `Dockerfile.all` — builds unified runtime image `open5gs:v2.7.5`

### docker.sh — Build runtime image only

Builds the runtime image from existing `build-output/` (skips source compilation):

```bash
./scripts/docker.sh
```

### start.sh — Start a CN instance

Adds secondary IPs, generates configs, starts the container.

```bash
# Basic
./scripts/start.sh --trx-ip <TRX_IP> --upf-ip <UPF_IP>

# Custom PLMN
./scripts/start.sh --trx-ip <TRX_IP> --upf-ip <UPF_IP> --mcc 404 --mnc 30

# Multi-PLMN
./scripts/start.sh --trx-ip <TRX_IP> --upf-ip <UPF_IP> \
    --plmn 404:30 --plmn 404:20 --tac 7

# Debug logging
./scripts/start.sh --trx-ip <TRX_IP> --upf-ip <UPF_IP> --debug

# Custom UE pool and slice
./scripts/start.sh --trx-ip <TRX_IP> --upf-ip <UPF_IP> \
    --ue-subnet 10.46.0.0/16 --ue-gw 10.46.0.1 --sst 1 --sd 000001
```

**All options:**

```
Required:
  --trx-ip IP     TRX/AMF/CP IP address (secondary IP on host interface)
  --upf-ip IP     UPF IP address (secondary IP on host interface)

Optional — PLMN:
  --mcc X         MCC (default: 001)
  --mnc Y         MNC (default: 01)
  --plmn MCC:MNC  PLMN (repeatable for multi-PLMN, overrides --mcc/--mnc)
  --tac Z         TAC (default: 1)

Optional — Slice:
  --sst S         SST (default: 3)
  --sd SD         SD (default: 198153)
  --dnn D         DNN (default: internet)

Optional — UE pool:
  --ue-subnet X   UE IP pool (default: 10.45.0.0/16)
  --ue-gw X       UE gateway (default: 10.45.0.1)

Optional — Network:
  --iface NAME    Force network interface (default: auto-detect)

Optional — Other:
  --debug         Enable debug logging for all NFs
```

**What start.sh does:**
1. Auto-detects host NIC (or uses `--iface`)
2. Derives instance name from TRX IP (e.g., `trx-10.100.0.11`)
3. Adds TRX + UPF as secondary IPs on the interface
4. Copies config templates → `instances/trx-<IP>/config/`, replaces placeholders
5. Patches PLMN(s) into AMF config
6. Creates log dir at `/opt/logs/cn/trx-<IP>/`
7. Generates `.env` and runs `docker compose up -d`
8. Waits for NRF health check (port 7777)
9. Sets up UE traffic routing (NAT + forwarding)

### stop.sh — Stop / remove instances

```bash
./scripts/stop.sh --trx-ip 10.100.0.11         # Stop (container paused, config kept)
./scripts/stop.sh --trx-ip 10.100.0.11 --rm    # Stop + full cleanup
./scripts/stop.sh --all                          # Stop all
./scripts/stop.sh --all --rm                     # Stop + remove all
```

Cleanup with `--rm` removes: container, secondary IPs, UE routes, iptables rules, TUN device, instance directory.

### status.sh — Show instance status

```bash
./scripts/status.sh                              # All instances + host MongoDB
./scripts/status.sh --trx-ip 10.100.0.11         # Specific instance
```

Displays: container state + health, network info (IPs, ports), NRF registration count, subscriber count.

### provision.sh — Provision subscribers

All instances share one MongoDB (`open5gs`). Provision once, all TRX instances see the same subscribers.

```bash
./scripts/provision.sh                                    # Default test subscriber
./scripts/provision.sh --count 10                          # Bulk: 10 subscribers
./scripts/provision.sh --imsi 001010000050641 --k <key> --opc <opc>
```

### logs.sh — Tail NF logs

Logs are stored on the host at `/opt/logs/cn/trx-<IP>/`.

```bash
./scripts/logs.sh --trx-ip 10.100.0.11           # All container logs (docker compose)
./scripts/logs.sh --trx-ip 10.100.0.11 amf       # AMF log
./scripts/logs.sh --trx-ip 10.100.0.11 upf       # UPF log
./scripts/logs.sh --trx-ip 10.100.0.11 nrf       # NRF log
```

Available NFs: `amf`, `smf`, `nrf`, `scp`, `ausf`, `udm`, `udr`, `pcf`, `nssf`, `bsf`, `upf`

---

## NF Ports

All NFs bind to the TRX IP (`--trx-ip`), except UPF which binds to `--upf-ip`.

| NF | SBI Port | Other Ports | Bind IP |
|---|---|---|---|
| NRF | 7777 | | TRX IP |
| SCP | 7778 | | TRX IP |
| AMF | 7780 | 38412/SCTP (NGAP) | TRX IP |
| SMF | 7781 | 8805/UDP (PFCP client) | TRX IP |
| PCF | 7782 | | TRX IP |
| NSSF | 7783 | | TRX IP |
| AUSF | 7784 | | TRX IP |
| UDM | 7785 | | TRX IP |
| UDR | 7786 | | TRX IP |
| BSF | 7787 | | TRX IP |
| UPF | | 2152/UDP (GTP-U), 8805/UDP (PFCP server) | UPF IP |

---

## Logs

Each instance writes per-NF log files to `/opt/logs/cn/trx-<IP>/`:

```
/opt/logs/cn/
├── trx-10.100.0.11/
│   ├── amf.log
│   ├── smf.log
│   ├── upf.log
│   ├── nrf.log
│   ├── scp.log
│   ├── ausf.log
│   ├── udm.log
│   ├── udr.log
│   ├── pcf.log
│   ├── nssf.log
│   └── bsf.log
├── trx-10.100.0.13/
│   └── ...
```

Readable directly on the host — no `docker exec` needed.

---

## Default Subscriber

| Field | Value |
|---|---|
| IMSI | `001010000050641` |
| K | `0c57e15a2cb86087097a6b50d42531de` |
| OPC | `109ee52735ae6d3849112cf4175029c7` |
| AMF | `8000` |
| SST | `3` |
| SD | `198153` |
| DNN | `internet` |
| MCC/MNC | `001`/`01` |
| TAC | `1` |

All instances share the same subscriber database.

---

## Build Process

```
./scripts/build.sh
  Step 1/3: docker build -f Dockerfile.build     (compile C source ~20 min)
  Step 2/3: docker run → extract build-output/    (binaries + libs)
  Step 3/3: docker build -f Dockerfile.all        (runtime image)
  → open5gs:v2.7.5
```

### Source compilation

`Dockerfile.build` clones open5GS v2.7.5, applies AMF cnode patches (outbound registration + health check), compiles with meson/ninja, exports to `build-output/`.

### Runtime image

`Dockerfile.all` copies all 11 NF binaries + shared libraries into an Ubuntu 22.04 runtime image.

---

## Directory Structure

```
open5gs-5G-SA-setup/
├── docker-compose.yaml       # Compose file (single core service, host networking)
├── Dockerfile.build          # Multi-stage source builder (applies AMF cnode patch)
├── Dockerfile.all            # Unified runtime image (all 11 NFs)
├── scripts/
│   ├── env.sh                # Shared env vars and helpers
│   ├── build.sh              # Source compilation + image build
│   ├── docker.sh             # Runtime image build (standalone)
│   ├── start.sh              # Start CN instance (--trx-ip <IP>)
│   ├── stop.sh               # Stop/remove CN instance
│   ├── status.sh             # Instance status
│   ├── provision.sh          # Subscriber provisioning
│   └── logs.sh               # Log tailing
├── config/
│   ├── start-all.sh          # Container entrypoint (starts all 11 NFs)
│   ├── nrf.yaml, scp.yaml, amf.yaml, smf.yaml, upf.yaml
│   └── ausf.yaml, udm.yaml, udr.yaml, pcf.yaml, nssf.yaml, bsf.yaml
├── NFs/
│   └── amf/cnode/            # AMF cnode client (amf_cnode.c, amf_cnode.h)
├── proto/                    # Protobuf definitions (cnode wire format)
├── tests/                    # Test suite
├── build-output/             # Generated by build (git-ignored)
└── instances/                # Generated at runtime (git-ignored)
    └── trx-<IP>/
        ├── .env              # Docker compose env vars
        ├── config/           # Patched NF configs + entrypoint
        └── metadata.env      # Instance metadata (IPs, PLMN, etc.)

/opt/logs/cn/                 # NF logs (host path, mounted into containers)
└── trx-<IP>/
    ├── amf.log, smf.log, upf.log, nrf.log, ...
```

---

## AMF Custom Fork - cnode Registration & Health Check

This repo ships a **forked open5GS AMF** with an outbound cnode client. The AMF dials **out** to a cnode registration server.

```
AMF  ──(TCP dial)──────────────────►  cnode server
AMF  ──NodeType_Message { AMF=13 }─►  server registers AMF
     ◄──HealthCheckRequest ─────────  server sends health check
AMF  ──HealthCheckResponse ────────►  { status: SERVING }
     (reconnects with exponential backoff: 1→2→4→...→30s)
```

### Wire format

C fork uses **LE 4-byte length prefix**: `[uint32_t LE length][proto payload]`

Registration message: `08 0D` (NodeType_Message with nodetype AMF=13)

### Configuration

Set env vars in `docker-compose.yaml` (under `core.environment`):

| Env var | Default | Description |
|---|---|---|
| `AMF_TCP_BIND_ADDR` | TRX IP | Health server bind address |
| `AMF_TCP_PORT` | `50051` | Health server port |
| `AMF_CNODE_ENABLE` | `1` | Enable cnode client |
| `AMF_CNODE_SERVER_IP` | _(unset)_ | cnode server IP (required to activate) |
| `AMF_CNODE_SERVER_PORT` | `9090` | cnode server TCP port |

### Mock server

```bash
python3 tests/cnode_mock_server.py --port 9090 [--framing le4|varint|auto]
```

---

## Prerequisites

- Docker & Docker Compose
- MongoDB running on host (port 27017)
- Linux host with a network interface that has a real subnet (not /32)
- SCTP kernel module (`modprobe sctp`)
- Available IP addresses on the host's LAN for TRX + UPF per instance
- Python 3 with PyYAML (`pip install pyyaml`)

---

## Troubleshooting

### Instance not starting

```bash
# Check MongoDB
mongosh --eval "db.runCommand({ping:1})"

# Check container logs
./scripts/logs.sh --trx-ip 10.100.0.11

# Check NRF
curl -s --http2-prior-knowledge http://10.100.0.11:7777/nnrf-nfm/v1/nf-instances
```

### gNB cannot reach AMF

```bash
# Verify secondary IPs are on the interface
ip addr show | grep 10.100.0.11

# Verify AMF is listening on NGAP
docker exec trx-10.100.0.11 ss -lnp | grep 38412

# Verify reachability
ping 10.100.0.11
```

### Cleaning up stale state

```bash
# Stop and remove all instances
./scripts/stop.sh --all --rm

# Manual cleanup if needed
ip addr del 10.100.0.11/24 dev eth0
ip addr del 10.100.0.12/24 dev eth0
```
