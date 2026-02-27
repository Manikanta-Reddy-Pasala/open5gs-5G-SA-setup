#!/usr/bin/env python3
"""
cnode_mock_server.py — Mock cnode registration + health-check server.

Implements the server side of the AMF cnode protocol:
  1. Accept TCP connection from AMF
  2. Read  NodeType_Message { nodetype: AMF(13) }   (registration)
  3. Send  HealthCheckRequest { service: "" }
  4. Read  HealthCheckResponse { status: SERVING(1) }
  5. Keep looping health-checks until AMF disconnects or --count is reached

Wire format (same as working MME sendData / recvData):
  [ uint32_t payload_length (4 bytes, native little-endian) ][ proto payload ]

Usage:
  # Basic — wait for one AMF connection, do one health check, exit
  python3 tests/cnode_mock_server.py

  # Custom port
  python3 tests/cnode_mock_server.py --port 9090

  # Keep sending health checks (interval in seconds)
  python3 tests/cnode_mock_server.py --port 9090 --interval 5 --count 10

  # Stay running and accept reconnects (e.g. while testing AMF backoff)
  python3 tests/cnode_mock_server.py --port 9090 --loop

Expected AMF environment variables:
  AMF_CNODE_ENABLE=1
  AMF_CNODE_SERVER_IP=<this host's IP>
  AMF_CNODE_SERVER_PORT=<PORT>
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

def parse_field1_varint(data: bytes) -> int:
    """Parse field 1 (wire type 0, varint) from a proto3 payload.
    Returns the integer value, or -1 if field 1 is not present."""
    if len(data) < 2 or data[0] != 0x08:
        return -1
    val, shift, i = 0, 0, 1
    while i < len(data):
        b = data[i]; i += 1
        val |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            break
    return val


# ── Wire-format I/O ───────────────────────────────────────────────────────────

def read_framed(conn: socket.socket) -> bytes:
    """Read one [uint32_t LE length][payload] message from conn."""
    hdr = b""
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            raise EOFError("connection closed while reading length header")
        hdr += chunk
    length = struct.unpack("<I", hdr)[0]
    if length == 0:
        return b""
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise EOFError("connection closed while reading payload")
        data += chunk
    return data


def write_framed(conn: socket.socket, payload: bytes) -> None:
    """Write one [uint32_t LE length][payload] message to conn."""
    conn.sendall(struct.pack("<I", len(payload)) + payload)


# ── Session handler ───────────────────────────────────────────────────────────

def handle_session(conn: socket.socket, addr, interval: float, count: int) -> bool:
    """
    Handle one AMF connection.
    Returns True if the full handshake succeeded, False on error.
    """
    conn.settimeout(10)

    # ── Step 1: Receive NodeType_Message ─────────────────────────────────────
    try:
        payload = read_framed(conn)
    except (EOFError, OSError) as e:
        print(f"  [server] ERROR reading NodeType_Message: {e}", flush=True)
        return False

    node_type = parse_field1_varint(payload)
    name = NODE_TYPES.get(node_type, f"UNKNOWN({node_type})")
    frame_hex = struct.pack("<I", len(payload)).hex() + " " + payload.hex()

    if node_type == 13:
        print(f"  [server] ✓ NodeType_Message  nodetype={node_type} ({name})", flush=True)
        print(f"           frame: [{frame_hex}]", flush=True)
    else:
        print(f"  [server] ✗ WRONG nodetype={node_type} ({name}), expected 13 (AMF)", flush=True)
        return False

    # ── Step 2+: Health check loop ────────────────────────────────────────────
    # field 1 (string, wire type 2): tag=0x0A, length=0x00 → service=""
    HC_REQUEST = bytes([0x0A, 0x00])

    done = 0
    limit = count if count > 0 else 1

    while done < limit:
        if done > 0:
            print(f"  [server] sleeping {interval}s before next health check ...", flush=True)
            time.sleep(interval)

        # Send HealthCheckRequest
        try:
            write_framed(conn, HC_REQUEST)
            req_hex = struct.pack("<I", len(HC_REQUEST)).hex() + " " + HC_REQUEST.hex()
            print(f"  [server] → HealthCheckRequest  frame: [{req_hex}]", flush=True)
        except OSError as e:
            print(f"  [server] ERROR sending HealthCheckRequest: {e}", flush=True)
            return False

        # Receive HealthCheckResponse
        try:
            resp = read_framed(conn)
        except (EOFError, OSError) as e:
            print(f"  [server] ERROR reading HealthCheckResponse: {e}", flush=True)
            return False

        status = parse_field1_varint(resp)
        status_name = STATUS_NAMES.get(status, f"UNKNOWN({status})")
        resp_hex = struct.pack("<I", len(resp)).hex() + " " + resp.hex()

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
        description="Mock cnode server for testing AMF registration + health check")
    parser.add_argument("--port",     type=int,   default=9090,
                        help="TCP port to listen on (default: 9090)")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Seconds between health checks (default: 2.0)")
    parser.add_argument("--count",    type=int,   default=3,
                        help="Health checks to send per session (default: 3, 0=infinite)")
    parser.add_argument("--loop",     action="store_true",
                        help="Keep accepting new connections (for backoff/reconnect testing)")
    args = parser.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(5)

    print(f"[mock cnode server] listening on 0.0.0.0:{args.port}", flush=True)
    print(f"[mock cnode server] health-checks per session: "
          f"{'infinite' if args.count == 0 else args.count}  "
          f"interval: {args.interval}s  loop: {args.loop}", flush=True)
    print(f"[mock cnode server] Set in AMF container:", flush=True)
    print(f"  AMF_CNODE_ENABLE=1", flush=True)
    print(f"  AMF_CNODE_SERVER_IP=<host-ip>", flush=True)
    print(f"  AMF_CNODE_SERVER_PORT={args.port}", flush=True)
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

        ok = handle_session(conn, addr, args.interval, args.count)
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
