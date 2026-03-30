#!/usr/bin/env python3
"""
cnode_mock_server.py — Mock cnode registration + health-check server.

Supports BOTH AMF implementations:
  - open5GS (C fork):  4-byte LE uint32 length header  (--framing le4,    default)
  - free5GC (Go fork): protobuf varint length prefix    (--framing varint)
  - auto-detection:                                     (--framing auto)

Protocol (same for both):
  1. Accept TCP connection from AMF
  2. Read  RegisterRequest / NodeType_Message  (registration)
  3. Send  HealthCheckRequest { service: "" }
  4. Read  HealthCheckResponse { status: SERVING(1) }
  5. Keep looping until --count is reached or AMF disconnects

Usage:
  # open5GS AMF (default: 4-byte LE framing)
  python3 tests/cnode_mock_server.py --port 9090

  # free5GC AMF (varint framing)
  python3 tests/cnode_mock_server.py --port 9090 --framing varint

  # Auto-detect framing from first byte
  python3 tests/cnode_mock_server.py --port 9090 --framing auto

  # Keep accepting reconnects (for backoff/reconnect testing)
  python3 tests/cnode_mock_server.py --port 9090 --loop --framing varint

open5GS env vars:
  AMF_CNODE_ENABLE=1  AMF_CNODE_SERVER_IP=<host-ip>  AMF_CNODE_SERVER_PORT=<PORT>

free5GC config (amfcfg.yaml):
  registration:
    enable: true
    serverIp: <host-ip>
    serverPort: <PORT>
"""

import argparse
import socket
import struct
import sys
import time

# ── NodeType mapping ──────────────────────────────────────────────────────────
NODE_TYPES = {
    0: "INVALID", 1: "HWA", 2: "MME", 3: "SGW", 4: "PGW",
    5: "MSC", 6: "SGSN", 7: "GGSN_C", 8: "GGSN_U", 9: "HNBGW",
    10: "HLR", 11: "NMUSER", 12: "GSM_CNE", 13: "AMF",
}

STATUS_NAMES = {0: "UNKNOWN", 1: "SERVING", 2: "NOT_SERVING"}


# ── Proto helpers (hand-coded, no external library) ───────────────────────────

def parse_register_request(data: bytes):
    """
    Parse fields from RegisterRequest (or NodeType_Message).
    Returns (node_type, ip, port).  ip/port are empty/0 if not present
    (open5GS only sends node_type; free5GC sends all three).
    """
    node_type = -1
    ip = ""
    port = 0
    i = 0
    while i < len(data):
        if i >= len(data):
            break
        tag = data[i]; i += 1
        field_num = tag >> 3
        wire_type = tag & 0x07
        if wire_type == 0:  # varint
            val = 0; shift = 0
            while i < len(data):
                b = data[i]; i += 1
                val |= (b & 0x7F) << shift
                shift += 7
                if not (b & 0x80):
                    break
            if field_num == 1:
                node_type = val
            elif field_num == 3:
                port = val
        elif wire_type == 2:  # length-delimited (string / bytes)
            l = 0; shift = 0
            while i < len(data):
                b = data[i]; i += 1
                l |= (b & 0x7F) << shift
                shift += 7
                if not (b & 0x80):
                    break
            value = data[i:i+l]; i += l
            if field_num == 2:
                ip = value.decode("utf-8", errors="replace")
        else:
            break  # unknown wire type — stop parsing
    return node_type, ip, port


def parse_field1_varint(data: bytes) -> int:
    """Parse field 1 (wire type 0, varint) — convenience wrapper."""
    node_type, _, _ = parse_register_request(data)
    return node_type


# ── Wire-format I/O: 4-byte LE (open5GS C format) ────────────────────────────

def read_le4(conn: socket.socket) -> bytes:
    hdr = b""
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            raise EOFError("connection closed while reading LE4 length header")
        hdr += chunk
    length = struct.unpack("<I", hdr)[0]
    if length == 0:
        return b""
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise EOFError("connection closed while reading LE4 payload")
        data += chunk
    return data


def write_le4(conn: socket.socket, payload: bytes) -> None:
    conn.sendall(struct.pack("<I", len(payload)) + payload)


def frame_hex_le4(payload: bytes) -> str:
    return struct.pack("<I", len(payload)).hex(" ") + "  " + payload.hex(" ")


# ── Wire-format I/O: varint prefix (free5GC Go format) ───────────────────────

def _read_varint_from_conn(conn: socket.socket) -> int:
    length = 0; shift = 0
    while True:
        b = conn.recv(1)
        if not b:
            raise EOFError("connection closed while reading varint length")
        byte = b[0]
        length |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            return length


def _encode_varint(n: int) -> bytes:
    buf = bytearray()
    while True:
        towrite = n & 0x7F
        n >>= 7
        if n:
            buf.append(towrite | 0x80)
        else:
            buf.append(towrite)
            break
    return bytes(buf)


def read_varint(conn: socket.socket) -> bytes:
    length = _read_varint_from_conn(conn)
    if length == 0:
        return b""
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise EOFError("connection closed while reading varint payload")
        data += chunk
    return data


def write_varint(conn: socket.socket, payload: bytes) -> None:
    conn.sendall(_encode_varint(len(payload)) + payload)


def frame_hex_varint(payload: bytes) -> str:
    return _encode_varint(len(payload)).hex(" ") + "  " + payload.hex(" ")


# ── Auto-detect framing from first 4 bytes ────────────────────────────────────

def _peek4(conn: socket.socket) -> bytes:
    """Read exactly 4 bytes without blocking (used for auto-detect)."""
    buf = b""
    while len(buf) < 4:
        chunk = conn.recv(4 - len(buf))
        if not chunk:
            raise EOFError("connection closed during framing auto-detect")
        buf += chunk
    return buf


def detect_and_read(conn: socket.socket):
    """
    Read one message, auto-detecting LE4 vs varint framing.
    Returns (payload, detected_framing) where framing is 'le4' or 'varint'.
    """
    hdr = _peek4(conn)
    # Heuristic: if bytes [1..3] are all 0x00, almost certainly LE4
    # (payload fits in 1 byte → length < 256 → upper 3 bytes of uint32 = 0)
    if hdr[1] == 0 and hdr[2] == 0 and hdr[3] == 0:
        length = struct.unpack("<I", hdr)[0]
        data = b""
        while len(data) < length:
            chunk = conn.recv(length - len(data))
            if not chunk:
                raise EOFError("connection closed during LE4 payload read")
            data += chunk
        return data, "le4"
    else:
        # Treat all 4 bytes as start of payload (varint length was 1 byte in hdr[0],
        # rest of hdr is beginning of payload)
        varint_byte = hdr[0]
        if varint_byte & 0x80:
            raise ValueError(f"Unexpected framing byte 0x{varint_byte:02x} — cannot auto-detect")
        length = varint_byte  # single-byte varint (length < 128)
        # We already have hdr[1..3] as first 3 bytes of payload
        data = hdr[1:]
        while len(data) < length:
            chunk = conn.recv(length - len(data))
            if not chunk:
                raise EOFError("connection closed during varint payload read")
            data += chunk
        return data[:length], "varint"


# ── Session handler ───────────────────────────────────────────────────────────

def handle_session(conn: socket.socket, addr, interval: float, count: int,
                   framing: str) -> bool:
    """
    Handle one AMF connection.
    Returns True if the full handshake succeeded, False on error.
    """
    conn.settimeout(10)
    active_framing = framing

    # ── Step 1: Receive RegisterRequest / NodeType_Message ───────────────────
    try:
        if framing == "auto":
            payload, active_framing = detect_and_read(conn)
            print(f"  [server] auto-detected framing: {active_framing}", flush=True)
        elif framing == "le4":
            payload = read_le4(conn)
        else:
            payload = read_varint(conn)
    except (EOFError, OSError, ValueError) as e:
        print(f"  [server] ERROR reading registration message: {e}", flush=True)
        return False

    node_type, reg_ip, reg_port = parse_register_request(payload)
    name = NODE_TYPES.get(node_type, f"UNKNOWN({node_type})")

    if active_framing == "le4":
        fhex = frame_hex_le4(payload)
    else:
        fhex = frame_hex_varint(payload)

    if node_type == 13:
        extra = f"  ip={reg_ip}  port={reg_port}" if reg_ip else ""
        print(f"  [server] ✓ RegisterRequest  nodetype={node_type} ({name}){extra}", flush=True)
        print(f"           frame: [{fhex}]", flush=True)
    else:
        print(f"  [server] ✗ WRONG nodetype={node_type} ({name}), expected 13 (AMF)", flush=True)
        return False

    # Choose I/O functions based on active framing
    if active_framing == "le4":
        write_fn = write_le4
        frame_fn = frame_hex_le4
        read_fn  = read_le4
    else:
        write_fn = write_varint
        frame_fn = frame_hex_varint
        read_fn  = read_varint

    # ── Step 2+: Health check loop ────────────────────────────────────────────
    # HealthCheckRequest: field 1 (string, wire type 2): tag=0x0A, len=0x00 → service=""
    HC_REQUEST = bytes([0x0A, 0x00])

    done = 0
    limit = count if count > 0 else 1

    while done < limit:
        if done > 0:
            print(f"  [server] sleeping {interval}s before next health check ...", flush=True)
            time.sleep(interval)

        # Send HealthCheckRequest
        try:
            write_fn(conn, HC_REQUEST)
            req_hex = frame_fn(HC_REQUEST)
            print(f"  [server] → HealthCheckRequest  frame: [{req_hex}]", flush=True)
        except OSError as e:
            print(f"  [server] ERROR sending HealthCheckRequest: {e}", flush=True)
            return False

        # Receive HealthCheckResponse
        try:
            resp = read_fn(conn)
        except (EOFError, OSError) as e:
            print(f"  [server] ERROR reading HealthCheckResponse: {e}", flush=True)
            return False

        status = parse_field1_varint(resp)
        status_name = STATUS_NAMES.get(status, f"UNKNOWN({status})")
        resp_hex = frame_fn(resp)

        if status == 1:
            print(f"  [server] ← HealthCheckResponse  status={status} ({status_name}) ✓", flush=True)
            print(f"           frame: [{resp_hex}]", flush=True)
        else:
            print(f"  [server] ✗ WRONG status={status} ({status_name}), expected 1 (SERVING)", flush=True)
            return False

        done += 1

    return True


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Mock cnode server for AMF registration + health check (open5GS & free5GC)")
    parser.add_argument("--port",     type=int,   default=9090,
                        help="TCP port to listen on (default: 9090)")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Seconds between health checks (default: 2.0)")
    parser.add_argument("--count",    type=int,   default=3,
                        help="Health checks per session (default: 3, 0=infinite)")
    parser.add_argument("--loop",     action="store_true",
                        help="Keep accepting new connections (for backoff/reconnect testing)")
    parser.add_argument("--framing",  choices=["le4", "varint", "auto"], default="le4",
                        help="Wire framing: le4=4-byte LE uint32 (open5GS C, default), "
                             "varint=protobuf varint prefix (free5GC Go), "
                             "auto=detect from first message")
    args = parser.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(5)

    framing_desc = {
        "le4":    "4-byte LE uint32  (open5GS C)",
        "varint": "protobuf varint   (free5GC Go)",
        "auto":   "auto-detect from first message",
    }
    print(f"[mock cnode server] listening on 0.0.0.0:{args.port}", flush=True)
    print(f"[mock cnode server] framing:  {args.framing} — {framing_desc[args.framing]}", flush=True)
    print(f"[mock cnode server] health-checks: {'infinite' if args.count == 0 else args.count}  "
          f"interval: {args.interval}s  loop: {args.loop}", flush=True)
    print(flush=True)
    if args.framing in ("le4", "auto"):
        print(f"  open5GS: set in docker-compose under open5gs-cp environment:", flush=True)
        print(f"    AMF_CNODE_ENABLE=1  AMF_CNODE_SERVER_IP=<host-ip>  AMF_CNODE_SERVER_PORT={args.port}", flush=True)
    if args.framing in ("varint", "auto"):
        print(f"  free5GC: set in config/amfcfg.yaml:", flush=True)
        print(f"    registration: {{ enable: true, serverIp: <host-ip>, serverPort: {args.port} }}", flush=True)
    print(flush=True)

    session_num = 0
    overall_pass = True

    while True:
        try:
            srv.settimeout(None)
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            print("\n[mock cnode server] interrupted", flush=True)
            break

        session_num += 1
        print(f"[mock cnode server] session {session_num}: connection from {addr[0]}:{addr[1]}", flush=True)

        ok = handle_session(conn, addr, args.interval, args.count, args.framing)
        conn.close()

        if ok:
            print(f"[mock cnode server] session {session_num}: ✅ PASS", flush=True)
        else:
            print(f"[mock cnode server] session {session_num}: ❌ FAIL", flush=True)
            overall_pass = False

        print(flush=True)

        if not args.loop:
            break

    srv.close()
    print(f"[mock cnode server] done — {'✅ ALL PASSED' if overall_pass else '❌ SOME FAILED'}", flush=True)
    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
