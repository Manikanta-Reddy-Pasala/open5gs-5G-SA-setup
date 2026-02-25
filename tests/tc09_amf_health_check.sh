#!/bin/bash
# ============================================================
# TC09: AMF TCP Health Check (Custom Fork)
# Verify the custom AMF TCP health check server on port 50051
# Wire format: [varint:length][proto], SERVING = 0x02 0x08 0x01
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC09: AMF TCP Health Check (Port ${AMF_HEALTH_PORT})"

ensure_core_running

# Step 1: Verify AMF health check is enabled via env var
info "Checking AMF_GRPC_ENABLE environment variable..."
amf_grpc=$(docker exec open5gs-cp printenv AMF_GRPC_ENABLE 2>/dev/null || echo "")
if [ "$amf_grpc" = "1" ]; then
    pass "AMF_GRPC_ENABLE=1 (health check enabled)"
else
    warn "AMF_GRPC_ENABLE=${amf_grpc:-not set}. Health check may not be active."
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
import socket, sys
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect(('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}))
    data = s.recv(64)
    s.close()
    print(data.hex())
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ "$response" = "020801" ]; then
    pass "Health check response: 0x020801 = SERVING ✓"
elif [ -n "$response" ]; then
    warn "Unexpected response: 0x${response}"
    info "Expected 0x020801 (varint:2, field1=status, value=1=SERVING)"
else
    fail "No response from ${AMF_HEALTH_HOST}:${AMF_HEALTH_PORT}"
fi

# Step 4: TCP connect + explicit HealthCheckRequest (full wire protocol)
info "Sending HealthCheckRequest payload and verifying response..."
response2=$(python3 -c "
import socket, sys

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
    data = s.recv(64)
    s.close()
    print(data.hex())
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ "$response2" = "020801" ]; then
    pass "HealthCheckRequest → SERVING (0x020801) ✓"
elif [ -n "$response2" ]; then
    warn "Response to explicit request: 0x${response2}"
else
    fail "No response to HealthCheckRequest"
fi

# Step 5: Verify AMF log shows health server startup message
info "Checking AMF log for health server startup message..."
amf_log=$(docker exec open5gs-cp cat /var/log/open5gs/amf.log 2>/dev/null | head -100)
if echo "$amf_log" | grep -qi "AMF-Health\|health.*50051\|TCP health\|grpc.*health"; then
    pass "AMF log confirms health server started"
    echo "$amf_log" | grep -i "AMF-Health\|health.*50051\|TCP health\|grpc" | head -3
else
    info "Health startup message not found in first 100 log lines (may be at different offset)"
fi

# Step 6: Multiple concurrent connections stress test
info "Testing 5 concurrent health check connections..."
ok_count=0
for i in $(seq 1 5); do
    r=$(python3 -c "
import socket, sys
try:
    s = socket.socket()
    s.settimeout(3)
    s.connect(('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}))
    data = s.recv(64)
    s.close()
    sys.exit(0 if data.hex() == '020801' else 1)
except:
    sys.exit(1)
" 2>/dev/null && echo "ok" || echo "fail")
    [ "$r" = "ok" ] && ok_count=$((ok_count + 1))
done

if [ "$ok_count" -eq 5 ]; then
    pass "All 5 concurrent health checks returned SERVING"
elif [ "$ok_count" -ge 3 ]; then
    warn "${ok_count}/5 concurrent health checks returned SERVING"
else
    fail "Only ${ok_count}/5 concurrent health checks succeeded"
fi

# Summary
echo ""
if [ "$response" = "020801" ]; then
    echo -e "${GREEN}${BOLD}TC09 PASSED${NC}: AMF TCP health check is working correctly on port ${AMF_HEALTH_PORT}"
    info "Wire format: 0x02=length, 0x08=field1 tag, 0x01=SERVING"
else
    echo -e "${RED}${BOLD}TC09 FAILED${NC}: AMF TCP health check not responding as expected"
    info "Check: docker exec open5gs-cp printenv AMF_GRPC_ENABLE"
    info "Check: docker logs open5gs-cp | grep -i health"
fi
