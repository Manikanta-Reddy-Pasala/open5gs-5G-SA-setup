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
  │  LM IP: <LM_IP> (existing management IP on host)            │
  │  + secondary IPs added per instance (CP + UPF)               │
  │                                                              │
  │    ┌── open5gs_10.100.0.11 (single container, host net) ─┐  │
  │    │  10 CP NFs + UPF   CP:  10.100.0.21                 │  │
  │    │  ogstun11           UPF: 10.100.0.31                 │  │
  │    └──────────────────────────────────────────────────────┘  │
  │                                                              │
  │    ┌── open5gs_10.100.0.12 (single container, host net) ─┐  │
  │    │  10 CP NFs + UPF   CP:  10.100.0.22                 │  │
  │    │  ogstun12           UPF: 10.100.0.32                 │  │
  │    └──────────────────────────────────────────────────────┘  │
  │                                                              │
  │  Logs: /opt/logs/cn/trx-10.100.0.11/                        │
  │        /opt/logs/cn/trx-10.100.0.12/  ...                   │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  gNB connects directly to secondary IPs:
    TRX1 gNB ──► 10.100.0.21:38412 (NGAP)  +  10.100.0.31:2152 (GTP-U)
    TRX2 gNB ──► 10.100.0.22:38412          +  10.100.0.32:2152
```

### IP roles

| Parameter | Purpose | Example |
|---|---|---|
| `--lm-ip` | LAN Management IP (already on host, for interface detection) | `192.168.1.100` |
| `--trx-ip` | TRX identifier (naming only: instance, container, logs) | `10.100.0.11` |
| `--cp-ip` | Control Plane bind IP (SBI, NGAP, PFCP-SMF) — secondary IP | `10.100.0.21` |
| `--upf-ip` | User Plane bind IP (GTP-U, PFCP-UPF) — secondary IP | `10.100.0.31` |

> **Note:** `--cp-ip` and `--upf-ip` must be different IPs (PFCP port 8805 conflict).

### Single-container design

Each instance runs **one container** (`open5gs_<TRX_IP>`) with all 11 NFs:

| NFs in container | Count | Role |
|---|---|---|
| NRF, SCP, AMF, SMF, PCF, NSSF, AUSF, UDM, UDR, BSF | 10 | Control Plane |
| UPF | 1 | User Plane (GTP-U + TUN) |

### Host networking

Containers use `network_mode: host` — all NFs bind directly to secondary IPs added to the host's physical interface. No Docker bridge, no macvlan, no NAT.

### How IPs flow from CLI to NF configs

When you run:
```bash
./scripts/start.sh --lm-ip 192.168.1.100 --trx-ip 10.100.0.11 --cp-ip 10.100.0.21 --upf-ip 10.100.0.31
```

1. **Interface detection** — finds host NIC using `--lm-ip` (existing IP on host)
2. **Secondary IPs** — adds CP IP and UPF IP to the detected interface
3. **Instance name** — derived from TRX IP: `trx-10.100.0.11`
4. **Container name** — `open5gs_10.100.0.11`
5. **TUN device** — derived from last octet of TRX IP: `ogstun11`
6. **Config templates patched** — placeholders in `config/*.yaml` get replaced:
   ```
   __CP_IP__      → 10.100.0.21    (AMF NGAP bind, all SBI binds)
   __UPF_IP__     → 10.100.0.31    (UPF GTP-U bind)
   __PFCP_CP_IP__ → 10.100.0.21    (SMF PFCP bind)
   __PFCP_UPF_IP__→ 10.100.0.31    (UPF PFCP bind)
   __MONGO_HOST__ → 127.0.0.1      (localhost MongoDB)
   __UE_SUBNET__  → 10.45.0.0/16   (UE pool)
   __UE_GW__      → 10.45.0.1      (UE gateway on TUN)
   __TUN_DEV__    → ogstun11        (unique per instance)
   ```
7. **`.env` file generated** at `instances/trx-10.100.0.11/.env`
8. **Log directory created** at `/opt/logs/cn/trx-10.100.0.11/`
9. **`docker compose up`** starts the single container
10. **UE routing** — adds route for UE subnet via UPF IP + iptables NAT

---

## Quick Start

```bash
# 1. Build open5GS from source + runtime image (~20 min first time)
./scripts/build.sh

# 2. Start a CN instance
./scripts/start.sh --lm-ip 192.168.1.100 --trx-ip 10.100.0.11 \
    --cp-ip 10.100.0.21 --upf-ip 10.100.0.31

# 3. Provision the default test subscriber
./scripts/provision.sh

# 4. Check status
./scripts/status.sh --trx-ip 10.100.0.11

# 5. View logs
./scripts/logs.sh --trx-ip 10.100.0.11 amf

# 6. Start more instances (different IPs, different UE pools)
./scripts/start.sh --lm-ip 192.168.1.100 --trx-ip 10.100.0.12 \
    --cp-ip 10.100.0.22 --upf-ip 10.100.0.32 \
    --ue-subnet 10.46.0.0/16 --ue-gw 10.46.0.1

# 7. Stop and remove
./scripts/stop.sh --trx-ip 10.100.0.11 --rm
```

---

## Scripts Reference

All scripts are in `scripts/`. Run from the repo root.

### build.sh — Compile open5GS + build runtime image

```bash
./scripts/build.sh              # Full build: source compile + runtime image
./scripts/build.sh --quick      # Skip source compile, rebuild runtime image only
```

### start.sh — Start a CN instance

```bash
# Basic
./scripts/start.sh --lm-ip <LM> --trx-ip <TRX> --cp-ip <CP> --upf-ip <UPF>

# Custom PLMN
./scripts/start.sh --lm-ip <LM> --trx-ip <TRX> --cp-ip <CP> --upf-ip <UPF> --mcc 404 --mnc 30

# Multi-PLMN
./scripts/start.sh --lm-ip <LM> --trx-ip <TRX> --cp-ip <CP> --upf-ip <UPF> \
    --plmn 404:30 --plmn 404:20 --tac 7

# Debug logging
./scripts/start.sh --lm-ip <LM> --trx-ip <TRX> --cp-ip <CP> --upf-ip <UPF> --debug
```

**All options:**

```
Required:
  --lm-ip IP      LAN Management IP (existing IP on host, for interface detection)
  --trx-ip IP     TRX identifier (naming only: instance, container, logs)
  --cp-ip IP      Control Plane IP (SBI, NGAP, PFCP-SMF — added as secondary)
  --upf-ip IP     User Plane IP (GTP-U, PFCP-UPF — added as secondary)

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
  --iface NAME    Force network interface (default: auto-detect from LM IP)

Optional — Other:
  --debug         Enable debug logging for all NFs
```

### stop.sh — Stop / remove instances

```bash
./scripts/stop.sh --trx-ip 10.100.0.11         # Stop (container paused, config kept)
./scripts/stop.sh --trx-ip 10.100.0.11 --rm    # Stop + full cleanup (removes CP+UPF secondary IPs)
./scripts/stop.sh --all                          # Stop all
./scripts/stop.sh --all --rm                     # Stop + remove all
```

### status.sh — Show instance status

```bash
./scripts/status.sh                              # All instances + host MongoDB
./scripts/status.sh --trx-ip 10.100.0.11         # Specific instance
```

### provision.sh — Provision subscribers

```bash
./scripts/provision.sh                                    # Default test subscriber
./scripts/provision.sh --count 10                          # Bulk: 10 subscribers
./scripts/provision.sh --imsi 001010000050641 --k <key> --opc <opc>
```

### logs.sh — Tail NF logs

```bash
./scripts/logs.sh --trx-ip 10.100.0.11           # All container logs (docker compose)
./scripts/logs.sh --trx-ip 10.100.0.11 amf       # AMF log
./scripts/logs.sh --trx-ip 10.100.0.11 upf       # UPF log
```

---

## NF Ports

All CP NFs bind to `--cp-ip`, UPF binds to `--upf-ip`.

| NF | SBI Port | Other Ports | Bind IP |
|---|---|---|---|
| NRF | 7777 | | CP IP |
| SCP | 7778 | | CP IP |
| AMF | 7780 | 38412/SCTP (NGAP) | CP IP |
| SMF | 7781 | 8805/UDP (PFCP client) | CP IP |
| PCF | 7782 | | CP IP |
| NSSF | 7783 | | CP IP |
| AUSF | 7784 | | CP IP |
| UDM | 7785 | | CP IP |
| UDR | 7786 | | CP IP |
| BSF | 7787 | | CP IP |
| UPF | | 2152/UDP (GTP-U), 8805/UDP (PFCP server) | UPF IP |

---

## Logs

Each instance writes per-NF log files to `/opt/logs/cn/trx-<TRX_IP>/`:

```
/opt/logs/cn/
├── trx-10.100.0.11/
│   ├── amf.log, smf.log, upf.log, nrf.log, scp.log
│   ├── ausf.log, udm.log, udr.log, pcf.log, nssf.log, bsf.log
├── trx-10.100.0.12/
│   └── ...
```

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
│   ├── start.sh              # Start CN instance (--lm-ip, --trx-ip, --cp-ip, --upf-ip)
│   ├── stop.sh               # Stop/remove CN instance
│   ├── status.sh             # Instance status
│   ├── provision.sh          # Subscriber provisioning
│   └── logs.sh               # Log tailing
├── config/
│   ├── start-all.sh          # Container entrypoint (starts all 11 NFs)
│   └── *.yaml                # NF config templates with placeholders
├── NFs/
│   └── amf/cnode/            # AMF cnode client (amf_cnode.c, amf_cnode.h)
├── proto/                    # Protobuf definitions (cnode wire format)
├── tests/                    # Test suite
├── build-output/             # Generated by build (git-ignored)
└── instances/                # Generated at runtime (git-ignored)
    └── trx-<TRX_IP>/
        ├── .env              # Docker compose env vars
        ├── config/           # Patched NF configs + entrypoint
        └── metadata.env      # Instance metadata (IPs, PLMN, etc.)
```

---

## AMF Custom Fork - cnode Registration & Health Check

This repo ships a **forked open5GS AMF** with an outbound cnode client. The AMF dials **out** to a cnode registration server.

### Configuration

Set env vars in `docker-compose.yaml` (under `core.environment`):

| Env var | Default | Description |
|---|---|---|
| `AMF_TCP_BIND_ADDR` | CP IP | Health server bind address |
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
- Two available IP addresses per instance (CP + UPF), must be different
- Python 3 with PyYAML (`pip install pyyaml`)
