# open5GS 5G SA Core - Multi-BTS Macvlan Deployment

A multi-instance 5G Standalone (SA) core network built from source using [open5GS](https://open5gs.org/) v2.7.5. Each BTS instance gets **real IPs on the host network** via macvlan — no NAT, no port mapping.

---

## Architecture

```
  Host (e.g., <HOST_IP>)
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  MongoDB 7.0 (host)  ◄── all instances share one DB         │
  │  <HOST_IP>:27017                                            │
  │                                                              │
  │  Physical NIC: eth0 (<SUBNET>)                              │
  │                                                              │
  │    ┌── macvlan: bts1-net ──────────────────────┐             │
  │    │  bts1-cp   <AMF_IP_1>   (NGAP, SBI)      │             │
  │    │  bts1-upf  <UPF_IP_1>   (GTP-U)          │             │
  │    └───────────────────────────────────────────┘             │
  │    ┌── bridge: bts1_internal (10.33.1.0/24) ───┐             │
  │    │  bts1-cp   10.33.1.2  ◄──PFCP──► 10.33.1.3│             │
  │    │  bts1-upf  10.33.1.3              (isolated)│            │
  │    └───────────────────────────────────────────┘             │
  │                                                              │
  │    ┌── macvlan: bts2-net ──────────────────────┐             │
  │    │  bts2-cp   <AMF_IP_2>                      │             │
  │    │  bts2-upf  <UPF_IP_2>                      │             │
  │    └───────────────────────────────────────────┘             │
  │    ┌── bridge: bts2_internal (10.33.2.0/24) ───┐             │
  │    │  bts2-cp   10.33.2.2  ◄──PFCP──► 10.33.2.3│             │
  │    └───────────────────────────────────────────┘             │
  │                                                              │
  │  Host shim: mac-bts1 → <AMF_IP_1>, <UPF_IP_1>              │
  │  Host shim: mac-bts2 → <AMF_IP_2>, <UPF_IP_2>              │
  └──────────────────────────────────────────────────────────────┘

  gNB connects directly to real IPs:
    BTS1 gNB ──► <AMF_IP_1>:38412 (NGAP)  +  <UPF_IP_1>:2152 (GTP-U)
    BTS2 gNB ──► <AMF_IP_2>:38412          +  <UPF_IP_2>:2152
```

### Dual-network design

Each instance has **two Docker networks**:

| Network | Type | Purpose | Exposed? |
|---|---|---|---|
| `btsN-net` | macvlan on host NIC | NGAP (gNB↔AMF), GTP-U (gNB↔UPF), SBI, MongoDB | Yes — real IPs on host LAN |
| `btsN_internal` | bridge `10.33.N.0/24` | PFCP (SMF↔UPF control plane) | No — isolated, not routable |

### How IPs flow from CLI to NF configs

When you run:
```bash
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP>
```

Here's what happens step by step:

**1. Network detection** — `start.sh` auto-detects the host interface from the AMF IP:
```
<AMF_IP> → ip route get → finds eth0 (<SUBNET>)
                         → host IP: <HOST_IP> (for MongoDB)
                         → gateway: <GATEWAY>
```

**2. Internal PFCP IPs are derived** from the instance ID:
```
Instance --id 1 → PFCP CP: 10.33.1.2, PFCP UPF: 10.33.1.3
Instance --id 2 → PFCP CP: 10.33.2.2, PFCP UPF: 10.33.2.3
```

**3. Config templates are patched** — placeholders in `config/*.yaml` get replaced:
```
__CP_IP__        → <AMF_IP>      (AMF NGAP bind, SBI bind)
__UPF_IP__       → <UPF_IP>      (UPF GTP-U bind)
__PFCP_CP_IP__   → 10.33.N.2     (SMF PFCP server — internal only)
__PFCP_UPF_IP__  → 10.33.N.3     (UPF PFCP server — internal only)
__MONGO_HOST__   → <HOST_IP>     (host IP for MongoDB)
__UE_SUBNET__    → 10.45.0.0/16  (UE pool)
__UE_GW__        → 10.45.0.1     (UE gateway on ogstun)
```

**4. `.env` file is generated** at `instances/bts1/.env` with all resolved values.

**5. `docker-compose.yaml`** (static file in repo root) reads the `.env` and starts containers with both networks:
```
bts1-cp:   macvlan <AMF_IP>  +  internal 10.33.N.2
bts1-upf:  macvlan <UPF_IP>  +  internal 10.33.N.3
```

**6. Result** — each NF binds to the right IP for the right purpose:

| NF | Binds to | Network | What connects to it |
|---|---|---|---|
| AMF (NGAP) | `<AMF_IP>:38412` | macvlan | gNB over SCTP |
| AMF (SBI) | `<AMF_IP>:7780` | macvlan | Other NFs via NRF |
| UPF (GTP-U) | `<UPF_IP>:2152` | macvlan | gNB user plane |
| SMF (PFCP) | `10.33.N.2:8805` | internal bridge | UPF only |
| UPF (PFCP) | `10.33.N.3:8805` | internal bridge | SMF only |
| NRF (SBI) | `<AMF_IP>:7777` | macvlan | All NFs register here |

---

## Networking Concepts — VLAN, macvlan & bridge

### Why not regular Docker bridge + port mapping?

Telecom NFs use protocols that don't work well with NAT/port-mapping:

| Protocol | Problem with NAT |
|---|---|
| **SCTP** (NGAP, AMF↔gNB) | Multi-homed transport — NAT breaks path validation |
| **GTP-U** (user plane) | Inner IP tunneling — TEID-based demux doesn't survive NAT |
| **PFCP** (SMF↔UPF) | Node ID carries IP — NAT rewrites break association |

**Solution**: macvlan gives each container a **real IP on the physical network** — the gNB sees the AMF/UPF at a normal IP, no NAT involved.

### What is macvlan?

macvlan is a Linux kernel feature that creates virtual network interfaces (sub-interfaces) on a physical NIC, each with its own MAC address and IP:

```
Physical NIC: eth0 (<HOST_IP>)
  ├── macvlan child: bts1-cp  → <AMF_IP_1> (own MAC)
  ├── macvlan child: bts1-upf → <UPF_IP_1> (own MAC)
  ├── macvlan child: bts2-cp  → <AMF_IP_2> (own MAC)
  └── macvlan child: bts2-upf → <UPF_IP_2> (own MAC)
```

From the LAN's perspective, these look like **separate physical machines**. The switch/router sees distinct MAC addresses and routes traffic normally. No port mapping, no NAT — just real IPs.

Docker's macvlan driver wraps this into a Docker network:
```bash
docker network create -d macvlan \
    --subnet=<SUBNET> --gateway=<GATEWAY> \
    -o parent=eth0 bts1-net
```

### The macvlan shim (host ↔ container communication)

**Problem**: Linux blocks traffic between a macvlan child and its parent interface. This means the **host cannot reach its own containers** via macvlan IPs.

**Solution**: Create a macvlan **shim interface** on the host side and route through it:

```bash
# Create host-side macvlan sub-interface
ip link add mac-bts1 link eth0 type macvlan mode bridge
ip link set mac-bts1 up

# Route container IPs through the shim
ip route add <AMF_IP>/32 dev mac-bts1   # AMF
ip route add <UPF_IP>/32 dev mac-bts1   # UPF
```

Now the host can reach the containers (needed for MongoDB access, health checks, `status.sh`), and the containers can reach the host (needed for MongoDB on host port 27017).

`start.sh` creates the shim automatically. `stop.sh --rm` removes it.

### Why a separate internal bridge for PFCP?

PFCP (Packet Forwarding Control Protocol) is the control channel between SMF and UPF. It carries session management commands — create/modify/delete PDU sessions. This traffic is **internal to the core** and should never be exposed to the LAN.

Each instance gets a private Docker bridge network:
```
Instance 1: 10.33.1.0/24  →  SMF: 10.33.1.2  ↔  UPF: 10.33.1.3
Instance 2: 10.33.2.0/24  →  SMF: 10.33.2.2  ↔  UPF: 10.33.2.3
Instance 3: 10.33.3.0/24  →  SMF: 10.33.3.2  ↔  UPF: 10.33.3.3
```

This bridge is marked `internal: true` in Docker — no external routing, no internet access. PFCP stays isolated between SMF↔UPF within each instance.

### macvlan vs VLAN (802.1Q)

| | macvlan | VLAN (802.1Q) |
|---|---|---|
| **Layer** | Same VLAN/subnet | Creates separate broadcast domain |
| **Tagging** | No VLAN tags | Adds 802.1Q tag to frames |
| **Switch config** | None needed | Requires trunk port on switch |
| **Use case** | Multiple IPs on one subnet | Network segmentation across subnets |
| **This project** | ✅ Used for container IPs | Not required (single subnet) |

This project uses **macvlan** (not 802.1Q VLAN) because all BTS instances share the same LAN subnet. If your deployment requires traffic isolation between instances at the network level, you could combine both — create 802.1Q VLAN sub-interfaces on the host, then use macvlan on each VLAN interface.

---

## Quick Start

```bash
# 1. Build open5GS from source (first time only, ~20 min)
./scripts/build.sh

# 2. Build Docker images (CP + UPF)
./scripts/docker.sh

# 3. Start a CN instance — provide AMF + UPF IPs on your network
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP>

# 4. Provision the default test subscriber
./scripts/provision.sh

# 5. Check status
./scripts/status.sh --id 1

# 6. Start more instances (different IPs)
./scripts/start.sh --id 2 --amf-ip <AMF_IP_2> --upf-ip <UPF_IP_2>

# 7. Stop and remove
./scripts/stop.sh --id 1 --rm
```

---

## Scripts Reference

All scripts are in the `scripts/` directory. Each one is self-contained — run from the repo root.

### build.sh — Compile open5GS from source

Builds open5GS v2.7.5 using a multi-stage Docker build (meson/ninja). Takes ~20 minutes on first run (cached after).

```bash
./scripts/build.sh              # Full source build (clone + compile)
./scripts/build.sh --quick      # Skip build, verify existing binaries exist
```

| Option | Description |
|---|---|
| _(none)_ | Full build: `Dockerfile.build` → builder container → extracts to `build-output/` |
| `--quick` | Verify `build-output/open5gs/` exists (useful before `docker.sh`) |

Output: `build-output/open5gs/bin/` (all NF binaries) + `build-output/open5gs/lib/` (shared libs)

### docker.sh — Build runtime Docker images

Builds the two runtime images from pre-compiled binaries in `build-output/`:

```bash
./scripts/docker.sh             # Build CP + UPF images
```

| Image | Dockerfile | Description |
|---|---|---|
| `open5gs-cp:v2.7.5` | `Dockerfile.cp` | Control Plane runtime (all 10 NFs) |
| `open5gs-upf:v2.7.5` | `Dockerfile.upf` | User Plane runtime (TUN + NAT) |

Requires: `build-output/` from `build.sh`.

### start.sh — Start a CN instance

Creates macvlan network, generates `.env` + configs, starts CP + UPF containers.

```bash
# Basic: single PLMN, default slice
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP>

# Custom PLMN
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> --mcc 404 --mnc 30

# Multi-PLMN (repeatable --plmn flag)
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> \
    --plmn 404:30 --plmn 404:20 --tac 7

# Debug logging (all NFs)
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> --debug

# Custom UE pool and slice
./scripts/start.sh --id 1 --amf-ip <AMF_IP> --upf-ip <UPF_IP> \
    --ue-subnet 10.46.0.0/16 --ue-gw 10.46.0.1 --sst 1 --sd 000001
```

**All options:**

```
Required:
  --id N          Instance number (1, 2, 3, ...)
  --amf-ip IP     AMF/CP IP address (must be on host's network subnet)
  --upf-ip IP     UPF IP address (must be on host's network subnet)

Optional — PLMN:
  --mcc X         MCC (default: 001)  — single PLMN mode
  --mnc Y         MNC (default: 01)   — single PLMN mode
  --plmn MCC:MNC  PLMN (repeatable, overrides --mcc/--mnc for multi-PLMN)
  --tac Z         TAC (default: 1)

Optional — Slice:
  --sst S         SST (default: 3)
  --sd SD         SD (default: 198153)
  --dnn D         DNN (default: internet)

Optional — UE pool:
  --ue-subnet X   UE IP pool subnet (default: 10.45.0.0/16)
  --ue-gw X       UE pool gateway IP (default: 10.45.0.1)

Optional — Network:
  --iface NAME    Force network interface (default: auto-detect)

Optional — Other:
  --debug         Enable debug logging for all NFs
```

**Interface auto-detection:** The script automatically picks the right physical interface by:
1. Trying `ip route get <AMF_IP>` first (route-based)
2. Falling back to smart detection — skips virtual interfaces (docker, virbr, veth, br-*), /32 addresses, and scores candidates by subnet size + default route + naming convention
3. Use `--iface enp1s0` to override if auto-detection picks the wrong one

**What start.sh does step by step:**
1. Auto-detects the host NIC (or uses `--iface`), validates macvlan support
2. Derives host IP, subnet, gateway for macvlan
3. Creates macvlan Docker network + host shim interface
4. Copies config templates → `instances/btsN/config/`, replaces placeholders
5. Patches PLMN(s) into AMF config using PyYAML
6. Generates `.env` at `instances/btsN/.env`
7. Runs `docker compose up -d` with the static `docker-compose.yaml`
8. Waits for NRF to be reachable on port 7777
9. Sets up host routing for UE traffic (NAT + forwarding)
10. Saves metadata to `instances/btsN/metadata.env`

### stop.sh — Stop / remove instances

```bash
./scripts/stop.sh --id 1         # Stop instance (containers paused, data kept)
./scripts/stop.sh --id 1 --rm    # Stop + remove (containers, networks, shim, instance dir)
./scripts/stop.sh --all           # Stop all instances
./scripts/stop.sh --all --rm      # Stop + remove all instances
```

| Option | Description |
|---|---|
| `--id N` | Target a specific instance |
| `--all` | Target all instances found in `instances/` |
| `--rm` | Remove mode: down containers, delete macvlan network + shim, clean UE routes, delete `instances/btsN/` |

Without `--rm`, containers are stopped but networks/configs are preserved (can restart with `docker compose up`).

### status.sh — Show instance status

```bash
./scripts/status.sh              # Show all instances + MongoDB status
./scripts/status.sh --id 1       # Show specific instance only
```

Displays:
- Container states (running/stopped + health check)
- Network info (macvlan interface, AMF/UPF IPs, UE pool)
- NRF registration count (queries NRF REST API)
- Subscriber count (queries MongoDB)
- Host MongoDB status

### provision.sh — Provision subscribers

All instances share a single MongoDB database (`open5gs`). Provision once, all BTS instances see the same subscribers.

```bash
./scripts/provision.sh                                # Default test subscriber
./scripts/provision.sh --count 10                      # Bulk: 10 subscribers (IMSI auto-incremented)
./scripts/provision.sh --imsi 001010000050641 --k <key> --opc <opc>  # Custom subscriber
```

| Option | Default | Description |
|---|---|---|
| `--count N` | `1` | Number of subscribers to provision (IMSI auto-increments, key last byte rotates) |
| `--imsi X` | `001010000050641` | Base IMSI (last 10 digits increment for bulk) |
| `--k X` | `0c57e15a...` | Authentication key K |
| `--opc X` | `109ee527...` | Operator key OPC |
| `--sst N` | `3` | Slice SST |
| `--sd X` | `198153` | Slice SD |
| `--dnn X` | `internet` | Data Network Name |
| `--id N` | _(ignored)_ | Accepted but ignored (single shared DB) |

### logs.sh — Tail container logs

```bash
./scripts/logs.sh --id 1           # All container logs (docker compose logs)
./scripts/logs.sh --id 1 amf       # AMF log file (/var/log/open5gs/amf.log)
./scripts/logs.sh --id 1 smf       # SMF log file
./scripts/logs.sh --id 1 upf       # UPF log file
./scripts/logs.sh --id 1 nrf       # NRF log file
```

| Argument | Description |
|---|---|
| `--id N` | **Required** — instance number |
| `amf`, `smf`, `nrf`, `scp`, `ausf`, `udm`, `udr`, `pcf`, `nssf`, `bsf` | Tail specific NF log from CP container |
| `upf` | Tail UPF log from UPF container |
| _(none)_ | Tail all docker compose logs (`-f --tail=50`) |

### env.sh — Shared environment

Sourced by all other scripts. Provides:
- Default values (`DEFAULT_MCC`, `DEFAULT_MNC`, `DEFAULT_IMSI`, etc.)
- Image names and versions (`IMAGE_CP`, `IMAGE_UPF`, `OPEN5GS_VERSION`)
- Port constants (`NGAP_PORT=38412`, `GTPU_PORT=2152`)
- Helper functions: `detect_interface()`, `get_host_ip()`, `create_macvlan_network()`, `create_macvlan_shim()`, `remove_macvlan_shim()`, `wait_port()`
- Color output: `log()`, `ok()`, `warn()`, `err()`, `hdr()`

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
├── docker-compose.yaml       # Static compose file (uses ${VAR} from .env)
├── Dockerfile.build          # Multi-stage source builder (applies AMF cnode patch)
├── Dockerfile.cp             # CP runtime image
├── Dockerfile.upf            # UPF runtime image
├── scripts/
│   ├── env.sh                # Shared env vars, macvlan helpers
│   ├── build.sh              # Source compilation script
│   ├── docker.sh             # Docker image builder
│   ├── start.sh              # Start CN instance (generates .env, creates networks)
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
    └── btsN/
        ├── .env              # Per-instance env vars for docker-compose
        ├── config/           # Patched NF configs
        ├── logs/             # CP and UPF logs
        └── metadata.env      # Instance metadata (IPs, PLMN, etc.)
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

Set env vars in `docker-compose.yaml` (under `cp.environment`) or in the instance `.env` file:

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
curl -s --http2-prior-knowledge http://<AMF_IP>:7777/nnrf-nfm/v1/nf-instances
```

### Host cannot reach containers

```bash
# Verify macvlan shim interface exists
ip link show mac-bts1

# Check routes to container IPs
ip route get <AMF_IP>
ip route get <UPF_IP>

# If shim is missing, recreate it
ip link add mac-bts1 link eth0 type macvlan mode bridge
ip link set mac-bts1 up
ip route add <AMF_IP>/32 dev mac-bts1
ip route add <UPF_IP>/32 dev mac-bts1
```

### gNB cannot reach AMF

```bash
# Verify AMF is listening on NGAP
docker exec bts1-cp ss -lnp | grep 38412

# Check macvlan network
docker network inspect bts1-net

# Verify the AMF IP is reachable from the gNB's network
ping <AMF_IP>
```

### Cleaning up stale state

```bash
# Stop and remove all instances
./scripts/stop.sh --all --rm

# Manual cleanup if needed
ip link del mac-bts1 2>/dev/null
docker network rm bts1-net 2>/dev/null
```

