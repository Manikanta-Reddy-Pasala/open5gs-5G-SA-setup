# open5GS 5G SA Core - Multi-BTS Macvlan Deployment

A multi-instance 5G Standalone (SA) core network built from source using [open5GS](https://open5gs.org/) v2.7.5. Each BTS instance gets **real IPs on the host network** via macvlan — no NAT, no port mapping.

---

## Architecture

```
  Host
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  MongoDB 7.0 (host)  ◄── all instances share one DB         │
  │  <HOST_IP>:27017                                             │
  │                                                              │
  │  Physical NIC: eth0 (e.g., 192.168.1.0/24)                  │
  │                                                              │
  │    ┌── macvlan: bts1-net ────────┐                           │
  │    │ bts1-cp   192.168.1.153     │  (AMF + 9 CP NFs)        │
  │    │ bts1-upf  192.168.1.154     │  (User Plane)            │
  │    └─────────────────────────────┘                           │
  │    ┌── macvlan: bts2-net ────────┐                           │
  │    │ bts2-cp   192.168.1.155     │                           │
  │    │ bts2-upf  192.168.1.156     │                           │
  │    └─────────────────────────────┘                           │
  │                                                              │
  │  Host shim interfaces (for host <-> container access):       │
  │    mac-bts1 → routes to .153, .154                           │
  │    mac-bts2 → routes to .155, .156                           │
  └──────────────────────────────────────────────────────────────┘

  gNB connects directly to real IPs (same standard ports):
    BTS1 gNB  ──►  192.168.1.153:38412 (NGAP/SCTP)  +  192.168.1.154:2152 (GTP-U)
    BTS2 gNB  ──►  192.168.1.155:38412               +  192.168.1.156:2152
```

### How macvlan networking works

1. A Docker **macvlan network** is created on the host's physical interface (e.g., `eth0`)
2. Each container gets a **real IP** on the host's LAN — directly reachable by gNBs
3. A **macvlan shim interface** (`mac-btsN`) is created on the host so the host can also communicate with its own containers (Linux blocks this by default for macvlan)
4. Containers reach host MongoDB via the host's physical IP
5. No iptables DNAT, no dummy interfaces, no port mapping

---

## Quick Start

```bash
# 1. Build open5GS from source (first time only, ~20 min)
./scripts/build.sh

# 2. Build Docker images (CP + UPF)
./scripts/docker.sh

# 3. Start a CN instance — provide AMF + UPF IPs on your network
./scripts/start.sh --id 1 --amf-ip 192.168.1.153 --upf-ip 192.168.1.154

# 4. Provision the default test subscriber
./scripts/provision.sh

# 5. Check status
./scripts/status.sh --id 1

# 6. Start more instances (different IPs)
./scripts/start.sh --id 2 --amf-ip 192.168.1.155 --upf-ip 192.168.1.156

# 7. Stop and remove
./scripts/stop.sh --id 1 --rm
```

---

## Scripts Reference

All scripts are in the `scripts/` directory:

| Script | Description |
|---|---|
| `scripts/env.sh` | Shared environment variables, macvlan helpers, colors |
| `scripts/build.sh` | Compile open5GS from source (meson/ninja in Docker) |
| `scripts/docker.sh` | Build Docker images: CP + UPF |
| `scripts/start.sh --id N --amf-ip X --upf-ip Y` | Start CN instance (macvlan network, containers, routing) |
| `scripts/stop.sh --id N [--rm]` | Stop (and optionally remove) CN instance |
| `scripts/stop.sh --all [--rm]` | Stop/remove all instances |
| `scripts/status.sh [--id N]` | Show instance status (containers, NFs, connectivity) |
| `scripts/provision.sh [--count N]` | Provision subscribers into shared MongoDB |
| `scripts/logs.sh --id N [nf]` | Tail container logs (all or specific NF) |

### start.sh options

```
Required:
  --id N          Instance number (1, 2, 3, ...)
  --amf-ip IP     AMF/CP IP address (must be on host's network)
  --upf-ip IP     UPF IP address (must be on host's network)

Optional:
  --mcc X         MCC (default: 001)
  --mnc Y         MNC (default: 01)
  --tac Z         TAC (default: 1)
  --sst S         SST (default: 3)
  --sd SD         SD (default: 198153)
  --dnn D         DNN (default: internet)
  --ue-subnet X   UE pool subnet (default: 10.45.0.0/16)
  --ue-gw X       UE pool gateway (default: 10.45.0.1)
  --debug         Enable debug logging
```

The script **auto-detects** the host network interface from the AMF IP, derives the subnet and gateway, creates the macvlan network, and configures everything.

---

## Containers per Instance

Each CN instance runs **2 containers**:

| Container | Image | Role | IP |
|---|---|---|---|
| `btsN-cp` | `open5gs-cp:v2.7.5` | All 10 CP NFs (NRF, SCP, AMF, SMF, PCF, NSSF, AUSF, UDM, UDR, BSF) | `--amf-ip` |
| `btsN-upf` | `open5gs-upf:v2.7.5` | User Plane Function (GTP-U tunnel + TUN) | `--upf-ip` |

MongoDB runs on the **host** (not in Docker). Containers reach it via the host's physical IP.

---

## NF Ports (inside CP container)

| NF | SBI Port | Notes |
|---|---|---|
| NRF | 7777 | Network Repository Function — central registry |
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

### Source compilation (`scripts/build.sh`)

Builds open5GS v2.7.5 from source using a multi-stage Docker build:

1. **Builder stage** (`Dockerfile.build`): Ubuntu 22.04, installs deps, clones open5GS, applies AMF cnode patches, compiles with meson/ninja
2. **Export stage**: Copies binaries to `build-output/`

```
build-output/
  open5gs/
    bin/     # open5gs-amfd, open5gs-smfd, open5gs-nrfd, ...
    lib/     # shared libraries
  BUILD_MANIFEST.txt
```

### Docker images (`scripts/docker.sh`)

| Dockerfile | Image | Description |
|---|---|---|
| `Dockerfile.cp` | `open5gs-cp:v2.7.5` | CP runtime (all 10 NFs) |
| `Dockerfile.upf` | `open5gs-upf:v2.7.5` | UPF runtime (TUN + NAT) |

---

## Directory Structure

```
open5gs-5G-SA-setup/
├── Dockerfile.build          # Multi-stage source builder (applies AMF cnode patch)
├── Dockerfile.cp             # CP runtime image
├── Dockerfile.upf            # UPF runtime image
├── scripts/
│   ├── env.sh                # Shared env vars, macvlan helpers
│   ├── build.sh              # Source compilation script
│   ├── docker.sh             # Docker image builder
│   ├── start.sh              # Start CN instance (macvlan + args-based IPs)
│   ├── stop.sh               # Stop/remove CN instance
│   ├── status.sh             # Instance status
│   ├── provision.sh          # Subscriber provisioning
│   ├── logs.sh               # Log tailing
│   ├── start-cp.sh           # CP container entrypoint (starts all 10 NFs)
│   └── start-upf.sh          # UPF container entrypoint (TUN + NAT setup)
├── config/                   # NF config templates (patched per-instance at start)
│   ├── nrf.yaml, scp.yaml, amf.yaml, smf.yaml, upf.yaml
│   └── ausf.yaml, udm.yaml, udr.yaml, pcf.yaml, nssf.yaml, bsf.yaml
├── NFs/
│   └── amf/
│       └── cnode/
│           ├── amf_cnode.h   # AMF cnode client header
│           └── amf_cnode.c   # AMF cnode client implementation
├── proto/                    # Protobuf definitions (cnode wire format)
├── tests/                    # Test suite
├── build-output/             # Generated by build (git-ignored)
└── instances/                # Generated at runtime (git-ignored)
    └── btsN/                 # Per-instance configs + docker-compose + metadata
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

### Configuration

Set env vars in the generated `docker-compose.yaml` (or override in `scripts/start.sh`):

| Env var | Default | Description |
|---|---|---|
| `AMF_CNODE_ENABLE` | `1` | `1` = enabled |
| `AMF_CNODE_SERVER_IP` | _(unset)_ | cnode server IPv4 (required to activate) |
| `AMF_CNODE_SERVER_PORT` | `9090` | cnode server TCP port |

---

## Prerequisites

- Docker & Docker Compose
- MongoDB 7.0+ running on host (port 27017)
- Linux host with macvlan-capable network interface (physical, not WiFi)
- SCTP kernel module (`modprobe sctp`)
- Available IP addresses on the host's LAN for AMF + UPF per instance
- Python 3 (for subnet calculation)

---

## Troubleshooting

### Instance not starting

```bash
# Check if MongoDB is running on host
mongosh --eval "db.runCommand({ping:1})"

# Check Docker logs
./scripts/logs.sh --id 1

# Check NRF is up (use AMF IP)
curl -s --http2-prior-knowledge http://<amf-ip>:7777/nnrf-nfm/v1/nf-instances
```

### Host cannot reach containers

```bash
# Verify macvlan shim interface exists
ip link show mac-bts1

# Check routes to container IPs
ip route get <amf-ip>
ip route get <upf-ip>

# If shim is missing, recreate it
ip link add mac-bts1 link eth0 type macvlan mode bridge
ip link set mac-bts1 up
ip route add <amf-ip>/32 dev mac-bts1
ip route add <upf-ip>/32 dev mac-bts1
```

### gNB cannot reach AMF

```bash
# Verify AMF is listening on NGAP
docker exec bts1-cp ss -lnp | grep 38412

# Check macvlan network
docker network inspect bts1-net

# Verify the AMF IP is reachable from the gNB's network
ping <amf-ip>
```

### Cleaning up stale state

```bash
# Stop and remove all instances
./scripts/stop.sh --all --rm

# Manual cleanup if needed
ip link del mac-bts1 2>/dev/null
docker network rm bts1-net 2>/dev/null
```

---

## Comparison: open5GS vs free5GC

| Feature | open5GS (this repo) | free5GC |
|---------|---------------------|---------|
| Language | C (meson/ninja) | Go |
| Version | v2.7.5 | v4.x |
| Deployment | Multi-BTS (N instances) | Single instance |
| MongoDB | Host (shared across instances) | Docker container |
| Containers per instance | 2 (CP, UPF) | 5 |
| Networking | Macvlan (real IPs on host LAN) | Bridge + port forward |
| BTS IPs | Passed as args (`--amf-ip`, `--upf-ip`) | Hardcoded |
| Provisioning | Direct `mongosh` on host | WebUI REST API |
| Slice (default) | SST=3, SD=198153 | SST=3, SD=198153 |
| AMF Health Check | cnode outbound client (custom fork) | cnode outbound client (custom fork) |
| NGAP port | 38412 | 38412 |
