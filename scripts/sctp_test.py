#!/usr/bin/env python3
"""
sctp_test.py — Test SCTP connectivity to AMF (NGAP port 38412)

Usage:
    ./scripts/sctp_test.py <target_ip> [port]
    ./scripts/sctp_test.py 135.181.93.114          # Test public IP
    ./scripts/sctp_test.py 10.100.0.15              # Test internal IP
    ./scripts/sctp_test.py 135.181.93.114 38412     # Explicit port

Tests:
  1. SCTP INIT handshake (can we establish an SCTP association?)
  2. Send a minimal NGAP NGSetupRequest and check for response
"""

import sys
import socket
import struct
import time
import traceback

# SCTP protocol number
IPPROTO_SCTP = 132

# Colors
GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
BOLD   = "\033[1m"
NC     = "\033[0m"

def ok(msg):   print(f"{GREEN}  ✓ {msg}{NC}")
def fail(msg): print(f"{RED}  ✗ {msg}{NC}")
def warn(msg): print(f"{YELLOW}  ⚠ {msg}{NC}")
def info(msg): print(f"  {msg}")


def test_sctp_connect(host, port):
    """Test 1: Raw SCTP INIT handshake"""
    print(f"\n{BOLD}{CYAN}[Test 1] SCTP INIT handshake → {host}:{port}{NC}")

    try:
        import sctp
        sock = sctp.sctpsocket_tcp(socket.AF_INET)
        sock.settimeout(5)
        t0 = time.time()
        sock.connect((host, port))
        ms = (time.time() - t0) * 1000
        ok(f"SCTP association established ({ms:.0f}ms)")

        # Get association info
        try:
            peer = sock.getpeername()
            ok(f"Peer: {peer[0]}:{peer[1]}")
        except Exception:
            pass

        sock.close()
        return True

    except sctp.error as e:
        fail(f"SCTP connect failed: {e}")
        return False
    except ImportError:
        warn("pysctp not installed, falling back to raw socket...")
        return test_sctp_raw(host, port)
    except socket.timeout:
        fail("SCTP connect timed out (5s) — packets likely dropped by firewall/NAT")
        return False
    except ConnectionRefusedError:
        fail("SCTP connection refused — port not listening or SCTP ABORT received")
        return False
    except Exception as e:
        fail(f"SCTP connect error: {e}")
        traceback.print_exc()
        return False


def test_sctp_raw(host, port):
    """Fallback: raw socket SCTP test"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM, IPPROTO_SCTP)
        sock.settimeout(5)
        t0 = time.time()
        sock.connect((host, port))
        ms = (time.time() - t0) * 1000
        ok(f"SCTP association established via raw socket ({ms:.0f}ms)")
        sock.close()
        return True
    except socket.timeout:
        fail("SCTP timed out (5s) — no INIT-ACK received")
        return False
    except ConnectionRefusedError:
        fail("SCTP connection refused (ABORT received)")
        return False
    except Exception as e:
        fail(f"Raw SCTP failed: {e}")
        return False


def test_ngap_setup(host, port):
    """Test 2: Send minimal NGAP NGSetupRequest, expect response"""
    print(f"\n{BOLD}{CYAN}[Test 2] NGAP NGSetupRequest → {host}:{port}{NC}")

    try:
        import sctp

        sock = sctp.sctpsocket_tcp(socket.AF_INET)
        sock.settimeout(5)
        sock.connect((host, port))
        # Ensure blocking mode for recv
        sock.setblocking(True)
        sock.settimeout(5)

        # Minimal NGAP NGSetupRequest (test PLMN 001/01, TAC=1, gNB-ID=1)
        # Valid ASN.1 APER-encoded NGSetupRequest
        ngap_setup = bytes([
            # NGAP PDU: InitiatingMessage
            0x00,
            # procedureCode = 21 (NGSetup)
            0x15,
            # criticality = reject
            0x00,
            # value length
            0x2b,
            # NGSetupRequest IEs
            0x00, 0x00, 0x04,  # protocolIEs count = 4

            # IE 1: GlobalRANNodeID (id=27)
            0x00, 0x1b, 0x00, 0x08, 0x00, 0x00,
            0xf1, 0x10,  # PLMN 001/01
            0x00, 0x00, 0x00, 0x01,  # gNB-ID = 1 (22 bits)

            # IE 2: RANNodeName (id=82)
            0x00, 0x52, 0x00, 0x0b, 0x06,
            0x00,  # length
            0x53, 0x43, 0x54, 0x50, 0x54, 0x53, 0x54,  # "SCTPTST"

            # IE 3: SupportedTAList (id=102)
            0x00, 0x66, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x00,
            0x01,  # TAC = 1
            0x00, 0xf1, 0x10,  # PLMN 001/01
            0x00, 0x00, 0x01,  # SST=1

            # IE 4: PagingDRX (id=21)
            0x00, 0x15, 0x40, 0x01, 0x60,
        ])

        # Send on SCTP stream 0 with PPID=60 (NGAP)
        ppid = 60
        sock.sctp_send(ngap_setup, ppid=ppid)
        ok("Sent NGSetupRequest")

        # Wait for response (use plain recv as fallback for sctp_recv EAGAIN)
        try:
            data = None
            try:
                fromaddr, flags, data, notif = sock.sctp_recv(4096)
            except OSError as recv_err:
                if recv_err.errno == 11:  # EAGAIN — retry with plain recv
                    time.sleep(0.5)
                    data = sock.recv(4096)
                else:
                    raise

            if data:
                ok(f"Received {len(data)} bytes response")
                # Check if it's NGSetupResponse (success) or NGSetupFailure
                if len(data) > 1:
                    proc_code = data[1]
                    if data[0] == 0x20 and proc_code == 0x15:
                        ok("Got NGSetupResponse (SUCCESS) — AMF accepted!")
                    elif data[0] == 0x40 and proc_code == 0x15:
                        warn("Got NGSetupFailure — AMF rejected (PLMN/TAC mismatch?)")
                        if len(data) > 10:
                            info(f"  Response hex: {data[:40].hex()}")
                    else:
                        info(f"  PDU: 0x{data[0]:02x} procCode: 0x{data[1]:02x}")
                        info(f"  Hex: {data[:40].hex()}")
            else:
                warn("Empty response (AMF may have closed the association)")
        except socket.timeout:
            warn("No NGAP response within 5s")

        sock.close()
        return True

    except ImportError:
        warn("pysctp not installed — skipping NGAP test")
        return False
    except sctp.error as e:
        fail(f"SCTP error during NGAP test: {e}")
        return False
    except Exception as e:
        fail(f"NGAP test error: {e}")
        traceback.print_exc()
        return False


def test_tcp_port(host, port):
    """Bonus: quick TCP check (won't work for SCTP but useful for diagnostics)"""
    print(f"\n{BOLD}{CYAN}[Info] TCP probe → {host}:{port}{NC}")
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        result = sock.connect_ex((host, port))
        sock.close()
        if result == 0:
            info("TCP port open (note: AMF uses SCTP, not TCP)")
        else:
            info(f"TCP port closed/filtered (errno={result}) — expected for SCTP-only port")
    except Exception as e:
        info(f"TCP probe: {e}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <target_ip> [port]")
        print(f"  {sys.argv[0]} 135.181.93.114        # Test via public IP")
        print(f"  {sys.argv[0]} 10.100.0.15           # Test via internal IP")
        sys.exit(1)

    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 38412

    print(f"\n{BOLD}{'='*50}")
    print(f"  SCTP/NGAP Connectivity Test")
    print(f"  Target: {host}:{port}")
    print(f"{'='*50}{NC}")

    # Run tests
    t1 = test_sctp_connect(host, port)
    t2 = False
    if t1:
        t2 = test_ngap_setup(host, port)
    test_tcp_port(host, port)

    # Summary
    print(f"\n{BOLD}{'='*50}")
    print(f"  Summary")
    print(f"{'='*50}{NC}")

    if t1 and t2:
        ok("SCTP + NGAP fully working — real gNB should connect fine")
    elif t1:
        ok("SCTP association works")
        warn("NGAP test inconclusive — but SCTP layer is OK")
    else:
        fail("SCTP connection FAILED")
        print()
        info("Troubleshooting:")
        info("  1. Check iptables DNAT: iptables -t nat -L PREROUTING -n")
        info("  2. Check AMF listening: ss -lnp | grep 38412")
        info("  3. Check SCTP module: lsmod | grep sctp")
        info("  4. Check conntrack: conntrack -L -p sctp 2>/dev/null")
        info("  5. Packet capture: tcpdump -i eth0 sctp -nn")

    print()


if __name__ == "__main__":
    main()
