# open5GS 5G SA Core - Multi-BTS Docker Deployment

A multi-instance 5G Standalone (SA) core network built from source using [open5GS](https://open5gs.org/) v2.7.5. Supports running **multiple independent CN (Core Network) sets** on a single host, each serving its own BTS (gNB), sharing a single host MongoDB.

---

## Architecture

```
  Host VM (135.181.93.114)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                      │
  │  MongoDB 7.0 (host)  ◄──── all instances share one DB (open5gs)     │
  │  localhost:27017                                                      │
  │                                                                      │
  │  Dummy interface: bts0                                               │
  │    10.0.0.91/32  ──► BTS1 CN                                        │
  │    10.0.0.92/32  ──► BTS2 CN                                        │
  │    10.0.0.93/32  ──► BTS3 CN                                        │
  │    10.0.0.94/32  ──► BTS4 CN                                        │
  │                                                                      │
  │  ┌─── BTS1 (10.200.1.0/24) ───┐  ┌─── BTS2 (10.200.2.0/24) ───┐  │
  │  │ bts1-cp   10.200.1.16      │  │ bts2-cp   10.200.2.16      │  │
  │  │ bts1-upf  10.200.1.17      │  │ bts2-upf  10.200.2.17      │  │
  │  │ bts1-webui :4001            │  │ bts2-webui :4002            │  │
  │  └─────────────────────────────┘  └─────────────────────────────┘  │
  │  ┌─── BTS3 (10.200.3.0/24) ───┐  ┌─── BTS4 (10.200.4.0/24) ───┐  │
  │  │ bts3-cp   10.200.3.16      │  │ bts4-cp   10.200.4.16      │  │
  │  │ bts3-upf  10.200.3.17      │  │ bts4-upf  10.200.4.17      │  │
  │  │ bts3-webui :4003            │  │ bts4-webui :4004            │  │
  │  └─────────────────────────────┘  └─────────────────────────────┘  │
  └──────────────────────────────────────────────────────────────────────┘

  Each gNB connects to its CN via a unique IP, same standard ports:
    BTS1 gNB  ──►  10.0.0.91:38412 (NGAP/SCTP)  +  10.0.0.91:2152 (GTP-U)
    BTS2 gNB  ──►  10.0.0.92:38412               +  10.0.0.92:2152
    BTS3 gNB  ──►  10.0.0.93:38412               +  10.0.0.93:2152
    BTS4 gNB  ──►  10.0.0.94:38412               +  10.0.0.94:2152
```

### How IP-based routing works

1. A Linux **dummy interface** (`bts0`) is created on the host
2. Each BTS instance gets a `/32` IP added to `bts0`: `10.0.0.<90 + ID>`
3. **iptables DNAT** rules match on destination IP (not port), forwarding to the correct Docker bridge:
   - `10.0.0.91:38412` (SCTP) → `10.200.1.16:38412` (bts1 AMF)
   - `10.0.0.91:2152` (UDP) → `10.200.1.17:2152` (bts1 UPF)
4. All BTS use **standard ports** (`38412`/`2152`) — only the IP differs

---

## Quick Start

```bash
# 1. Build open5GS from source (first time only, ~20 min)
./build.sh

# 2. Build Docker images (CP, UPF, WebUI)
./docker.sh

# 3. Start a CN instance for BTS 1
./start.sh --id 1

# 4. Provision the default test subscriber
./provision.sh

# 5. Check status
./status.sh --id 1

# 6. Start more instances
./start.sh --id 2
./start.sh --id 3
./start.sh --id 4

# 7. Check all instances
./status.sh --all
```

---

## Scripts Reference

| Script | Description |
|---|---|
| `env.sh` | Shared environment variables, helper functions, colors |
| `build.sh` | Compile open5GS from source (meson/ninja) |
| `docker.sh` | Build Docker images: CP, UPF, WebUI |
| `start.sh --id N` | Start CN instance N (creates network, containers, iptables) |
| `stop.sh --id N` | Stop CN instance N |
| `stop.sh --id N --rm` | Stop and fully remove instance (containers + iptables + BTS IP) |
| `stop.sh --all [--rm]` | Stop/remove all instances |
| `status.sh --id N` | Show instance status (containers, NFs, connectivity) |
| `status.sh --all` | Show all instances status |
| `provision.sh` | Provision default test subscriber |
| `provision.sh --count 10` | Bulk provision 10 subscribers |
| `logs.sh --id N` | Tail all container logs for instance N |
| `logs.sh --id N amf` | Tail AMF log only |

---

## Per-Instance Networking

Each instance gets its own isolated Docker bridge network:

| Instance | Docker Subnet | CP IP | UPF IP | BTS IP | WebUI | UE Pool |
|---|---|---|---|---|---|---|
| bts1 | `10.200.1.0/24` | `10.200.1.16` | `10.200.1.17` | `10.0.0.91` | `:4001` | `10.206.0.0/16` |
| bts2 | `10.200.2.0/24` | `10.200.2.16` | `10.200.2.17` | `10.0.0.92` | `:4002` | `10.207.0.0/16` |
| bts3 | `10.200.3.0/24` | `10.200.3.16` | `10.200.3.17` | `10.0.0.93` | `:4003` | `10.208.0.0/16` |
| bts4 | `10.200.4.0/24` | `10.200.4.16` | `10.200.4.17` | `10.0.0.94` | `:4004` | `10.209.0.0/16` |

**Pattern**: Instance N → subnet `10.200.N.0/24`, BTS IP `10.0.0.<90+N>`, WebUI port `4000+N`, UE pool `10.<205+N>.0.0/16`

---

## Containers per Instance

Each CN instance runs **3 containers**:

| Container | Image | Role | Fixed IP |
|---|---|---|---|
| `btsN-cp` | `open5gs-cp-local:v2.7.5` | All 10 CP NFs (NRF, SCP, AMF, SMF, PCF, NSSF, AUSF, UDM, UDR, BSF) | `10.200.N.16` |
| `btsN-upf` | `open5gs-upf-local:v2.7.5` | User Plane Function (GTP-U tunnel) | `10.200.N.17` |
| `btsN-webui` | `open5gs-webui-local:v2.7.5` | Subscriber management UI | DHCP |

MongoDB runs on the **host** (not in Docker). Containers reach it via the Docker bridge gateway (`172.17.0.1:27017`).

---

## NF Ports (inside CP container)

| NF | SBI Port | Notes |
|---|---|---|
| NRF | 7777 | Network Repository Function - central registry |
| SCP | 7778 | Service Communication Proxy |
| AMF | 7780 | Access & Mobility Management; NGAP on 38412/SCTP |
| SMF | 7781 | Session Management; PFCP to UPF |
| PCF | 7782 | Policy Control |
| NSSF | 7783 | Network Slice Selection |
| AUSF | 7784 | Authentication Server |
| UDM | 7785 | Unified Data Management |
| UDR | 7786 | Unified Data Repository |
| BSF | 7787 | Binding Support Function |

---

## Default Subscriber

| Field | Value |
|---|---|
| IMSI | `001010000050641` |
| K (key) | `0c57e15a2cb86087097a6b50d42531de` |
| OPC | `109ee52735ae6d3849112cf4175029c7` |
| AMF | `8000` |
| SST | `3` |
| SD | `198153` |
| DNN | `internet` |
| MCC/MNC | `001`/`01` |
| TAC | `1` |

All instances share the same subscriber database (`open5gs`).

---

## Build Process

### Source compilation (`build.sh`)

Builds open5GS v2.7.5 from source using a multi-stage Docker build:

1. **Builder stage** (`Dockerfile.build-all`): Ubuntu 22.04, installs deps, clones open5GS, applies AMF cnode patches, compiles with meson/ninja
2. **Export stage**: Copies binaries to `build-output/`

```
build-output/
  open5gs/
    bin/     # open5gs-amfd, open5gs-smfd, open5gs-nrfd, ...
    lib/     # shared libraries
  BUILD_MANIFEST.txt
```

### Docker images (`docker.sh`)

| Dockerfile | Image | Description |
|---|---|---|
| `Dockerfile.cp-local` | `open5gs-cp-local:v2.7.5` | CP runtime (all 10 NFs) |
| `Dockerfile.upf-local` | `open5gs-upf-local:v2.7.5` | UPF runtime |
| `Dockerfile.webui` | `open5gs-webui-local:v2.7.5` | WebUI (Node.js/Next.js) |

UERANSIM is **not** included in the Docker images.

---

## WebUI

Each instance runs its own WebUI for subscriber management:

- **URL**: `http://<host-ip>:<4000 + instance_id>`
- **Login**: `admin` / `1423`
- **Features**: Add/edit/delete subscribers, view sessions, manage slices

---

## AMF Custom Fork - cnode Registration & Health Check

This repo ships a **forked open5GS AMF** with an outbound cnode client. The AMF dials **out** to a cnode registration server (no inbound TCP server on AMF).

```
AMF  ──(TCP dial)──────────────────►  cnode server
AMF  ──NodeType_Message { AMF=13 }─►  server registers AMF
     ◄──HealthCheckRequest ─────────  server sends health check
AMF  ──HealthCheckResponse ────────►  { status: SERVING }
     (reconnects with exponential backoff: 1→2→4→...→30s)
```

### Wire Format (4-byte LE length header)

| Message | Direction | Proto bytes | Full frame |
|---|---|---|---|
| `NodeType_Message { nodetype: AMF=13 }` | AMF → server | `08 0D` | `02 00 00 00  08 0D` |
| `HealthCheckRequest { service: "" }` | server → AMF | `0A 00` | `02 00 00 00  0A 00` |
| `HealthCheckResponse { status: SERVING=1 }` | AMF → server | `08 01` | `02 00 00 00  08 01` |

### Configuration

Set env vars in the generated `docker-compose.yaml` (or override in `start.sh`):

| Env var | Default | Description |
|---|---|---|
| `AMF_CNODE_ENABLE` | `1` | `1` = enabled |
| `AMF_CNODE_SERVER_IP` | _(unset)_ | cnode server IPv4 (required to activate) |
| `AMF_CNODE_SERVER_PORT` | `9090` | cnode server TCP port |

### Fork structure

```
NFs/amf/
└── cnode/
    ├── amf_cnode.h   # Public API: amf_cnode_start() / amf_cnode_stop()
    └── amf_cnode.c   # Outbound client: dial, register, poll loop, backoff
```

### Testing with mock server

```bash
# Start mock server
python3 tests/cnode_mock_server.py --port 9090 --loop --count 5

# Start CN with cnode pointed at mock server
# (set AMF_CNODE_SERVER_IP in env before start)
./start.sh --id 1
```

---

## Directory Structure

```
open5gs-5G-SA-setup/
├── env.sh                    # Shared env vars & helper functions
├── build.sh                  # Source compilation script
├── docker.sh                 # Docker image builder
├── start.sh                  # Start CN instance (--id N)
├── stop.sh                   # Stop/remove CN instance
├── status.sh                 # Instance status
├── provision.sh              # Subscriber provisioning
├── logs.sh                   # Log tailing
├── Dockerfile.build-all      # Multi-stage source builder (applies AMF cnode patch)
├── Dockerfile.cp-local       # CP runtime image
├── Dockerfile.upf-local      # UPF runtime image
├── Dockerfile.webui          # WebUI image (Node.js)
├── NFs/
│   └── amf/
│       └── cnode/
│           ├── amf_cnode.h   # AMF cnode client header
│           └── amf_cnode.c   # AMF cnode client implementation
├── consolidated/
│   ├── start-cp-nfs.sh       # CP container entrypoint (starts all 10 NFs)
│   └── start-upf.sh          # UPF container entrypoint (TUN + NAT setup)
├── config/                   # NF config templates (patched per-instance at start)
│   ├── nrf.yaml, scp.yaml, amf.yaml, smf.yaml, upf.yaml
│   ├── ausf.yaml, udm.yaml, udr.yaml, pcf.yaml, nssf.yaml, bsf.yaml
├── proto/                    # Protobuf definitions (cnode wire format)
├── tests/                    # Test suite
│   ├── cnode_mock_server.py  # Mock cnode server
│   ├── common.sh, run_all.sh
│   └── tc01-tc10             # Test cases
├── build-output/             # Generated by build (git-ignored)
│   └── open5gs/bin/, lib/
└── instances/                # Generated at runtime (git-ignored)
    ├── bts1/                 # Per-instance configs + docker-compose
    ├── bts2/
    ├── bts3/
    └── bts4/
```

---

## Prerequisites

- Docker & Docker Compose
- MongoDB 7.0 running on host (port 27017)
- Linux host with iptables and dummy kernel module (`modprobe dummy`)
- SCTP kernel module (`modprobe sctp`)

---

## Troubleshooting

### Instance not starting

```bash
# Check if MongoDB is running on host
mongosh --eval "db.runCommand({ping:1})"

# Check Docker logs
./logs.sh --id 1

# Check NRF is up
docker exec bts1-cp wget -qO- http://127.0.0.1:7777/nnrf-nfm/v1/nf-instances
```

### BTS cannot reach AMF

```bash
# Verify dummy interface IPs
ip addr show bts0

# Check DNAT rules
iptables -t nat -L PREROUTING -n

# Verify AMF is listening on NGAP
docker exec bts1-cp ss -lnp | grep 38412
```

### Cleaning up stale state

```bash
# Stop and remove all instances
./stop.sh --all --rm

# Flush iptables if needed
iptables -t nat -F PREROUTING
iptables -t nat -F OUTPUT
iptables -t nat -F POSTROUTING
iptables -F FORWARD

# Remove dummy interface
ip link del bts0
```

---

## Comparison: open5GS vs free5GC

| Feature | open5GS (this repo) | free5GC |
|---------|---------------------|---------|
| Language | C (meson/ninja) | Go |
| Version | v2.7.5 | v4.x |
| Deployment | Multi-BTS (N instances) | Single instance |
| MongoDB | Host (shared across instances) | Docker container |
| Containers per instance | 3 (CP, UPF, WebUI) | 5 |
| BTS routing | IP-based (dummy iface + DNAT) | Port forwarding |
| Provisioning | Direct `mongosh` on host | WebUI REST API |
| Slice (default) | SST=3, SD=198153 | SST=3, SD=198153 |
| WebUI | Port 4000+N, admin/1423 | Port 5000, admin/free5gc |
| AMF Health Check | cnode outbound client (custom fork) | cnode outbound client (custom fork) |
| NGAP port | 38412 | 38412 |
