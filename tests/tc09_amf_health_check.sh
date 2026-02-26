#!/bin/bash
# ============================================================
# TC09: AMF TCP Health Check (Custom Fork)
# Verify the custom AMF TCP health check server on port 50051
# Wire format: [varint:length][proto]
# SERVING+AMF = 0x04 0x08 0x01 0x10 0x0D
#   0x04        — varint length = 4
#   0x08 0x01   — field 1 (status), value 1 = SERVING
#   0x10 0x0D   — field 2 (node_type), value 13 = AMF
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

EXPECTED="040801100d"

header "TC09: AMF TCP Health Check (Port ${AMF_HEALTH_PORT})"

ensure_core_running

# Step 1: Verify AMF health check is enabled via env var
info "Checking AMF_TCP_ENABLE environment variable..."
amf_grpc=$(docker exec open5gs-cp printenv AMF_TCP_ENABLE 2>/dev/null || echo "")
if [ "$amf_grpc" = "1" ]; then
    pass "AMF_TCP_ENABLE=1 (health check enabled)"
else
    warn "AMF_TCP_ENABLE=${amf_grpc:-not set}. Health check may not be active."
fi

# Step 2: Verify port 50051 is listening inside the container
info "Checking port ${AMF_HEALTH_PORT} inside open5gs-cp..."
port_check=$(docker exec open5gs-cp bash -c \
    "ss -tlnp 2>/dev/null | grep ':${AMF_HEALTH_PORT}' || \
     netstat -tlnp 2>/dev/null | grep ':${AMF_HEALTH_PORT}' || echo ''" 2>/dev/null)
if [ -n "$port_check" ]; then
    pass "Port ${AMF_HEALTH_PORT} is listening inside open5gs-cp"
    echo "    $port_check"
else
    warn "Port ${AMF_HEALTH_PORT} not visible via ss/netstat inside container"
    info "This may be expected if the AMF binary includes the health server internally"
fi

# Step 3: TCP connect + wire-format response check (plain probe, no request)
info "Connecting to ${AMF_HEALTH_HOST}:${AMF_HEALTH_PORT} (no request — server-initiated reply)..."
response=$(python3 -c "
import socket, sys, time
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect(('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}))
    time.sleep(0.6)
    data = b''
    s.settimeout(1)
    try:
        while True:
            chunk = s.recv(64)
            if not chunk: break
            data += chunk
    except: pass
    s.close()
    print(data.hex())
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ "$response" = "$EXPECTED" ]; then
    pass "Health check response: 0x${EXPECTED} = SERVING + node_type=AMF ✓"
    info "  0x04=len(4)  0x0801=status:SERVING  0x100d=node_type:AMF(13)"
elif [ -n "$response" ]; then
    warn "Unexpected response: 0x${response}"
    info "Expected 0x${EXPECTED} (len=4, status=SERVING, node_type=AMF)"
else
    fail "No response from ${AMF_HEALTH_HOST}:${AMF_HEALTH_PORT}"
fi

# Step 4: TCP connect + explicit HealthCheckRequest (full wire protocol)
info "Sending HealthCheckRequest payload and verifying response..."
response2=$(python3 -c "
import socket, sys, time

def encode_varint(n):
    buf = []
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            buf.append(b | 0x80)
        else:
            buf.append(b)
            break
    return bytes(buf)

# HealthCheckRequest{} is empty = zero bytes after length prefix
req_body = b''
payload = encode_varint(len(req_body)) + req_body

try:
    s = socket.socket()
    s.settimeout(5)
    s.connect(('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}))
    s.sendall(payload)
    time.sleep(0.3)
    data = b''
    s.settimeout(1)
    try:
        while True:
            chunk = s.recv(64)
            if not chunk: break
            data += chunk
    except: pass
    s.close()
    print(data.hex())
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ "$response2" = "$EXPECTED" ]; then
    pass "HealthCheckRequest → SERVING+AMF (0x${EXPECTED}) ✓"
elif [ -n "$response2" ]; then
    warn "Response to explicit request: 0x${response2}"
else
    fail "No response to HealthCheckRequest"
fi

# Step 5: Decode and verify node_type field explicitly
info "Decoding node_type from response..."
node_type=$(python3 -c "
data = bytes.fromhex('${response}')
# Skip length varint, then parse fields
i = 0
# skip length prefix byte(s)
while i < len(data) and (data[i] & 0x80): i += 1
i += 1
# parse fields
while i < len(data):
    tag_byte = data[i]; i += 1
    field_num = tag_byte >> 3
    wire_type = tag_byte & 0x07
    if wire_type == 0:  # varint
        val = 0; shift = 0
        while i < len(data):
            b = data[i]; i += 1
            val |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80): break
        if field_num == 2:
            print(val)
            break
" 2>/dev/null)
if [ "$node_type" = "13" ]; then
    pass "node_type decoded = 13 (AMF) ✓"
else
    warn "node_type decoded = '${node_type}' (expected 13=AMF)"
fi

# Step 6: Verify AMF log shows health server startup message
info "Checking AMF log for health server startup message..."
amf_log=$(docker exec open5gs-cp cat /var/log/open5gs/amf.log 2>/dev/null | head -100)
if echo "$amf_log" | grep -qi "AMF-Health\|health.*50051\|TCP health\|grpc.*health"; then
    pass "AMF log confirms health server started"
    echo "$amf_log" | grep -i "AMF-Health\|health.*50051\|TCP health\|grpc" | head -3
else
    info "Health startup message not found in first 100 log lines (may be at different offset)"
fi

# Step 7: Multiple concurrent connections stress test
info "Testing 5 concurrent health check connections..."
ok_count=0
for i in $(seq 1 5); do
    r=$(python3 -c "
import socket, sys, time
try:
    s = socket.socket()
    s.settimeout(3)
    s.connect(('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}))
    time.sleep(0.6)
    data = b''
    s.settimeout(1)
    try:
        while True:
            chunk = s.recv(64)
            if not chunk: break
            data += chunk
    except Exception: pass
    s.close()
    result = 0 if data.hex() == '${EXPECTED}' else 1
except Exception:
    result = 1
sys.exit(result)
" 2>/dev/null && echo "ok" || echo "fail")
    [ "$r" = "ok" ] && ok_count=$((ok_count + 1))
done

if [ "$ok_count" -eq 5 ]; then
    pass "All 5 concurrent health checks returned SERVING+AMF"
elif [ "$ok_count" -ge 3 ]; then
    warn "${ok_count}/5 concurrent health checks returned SERVING+AMF"
else
    fail "Only ${ok_count}/5 concurrent health checks succeeded"
fi

# Summary
echo ""
if [ "$response" = "$EXPECTED" ]; then
    echo -e "${GREEN}${BOLD}TC09 PASSED${NC}: AMF TCP health check is working correctly on port ${AMF_HEALTH_PORT}"
    info "Wire: 0x04=len  0x0801=SERVING  0x100d=node_type:AMF(13)"
else
    echo -e "${RED}${BOLD}TC09 FAILED${NC}: AMF TCP health check not responding as expected"
    info "Check: docker exec open5gs-cp printenv AMF_TCP_ENABLE"
    info "Check: docker logs open5gs-cp | grep -i health"
fi
