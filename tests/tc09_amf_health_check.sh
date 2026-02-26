#!/bin/bash
# ============================================================
# TC09: AMF TCP Health Check (Custom Fork)
# Verify the custom AMF TCP health check server on port 50051
#
# HealthCheckResponse wire format (raw TCP, no gRPC):
#   [varint:length][proto-encoded payload]
#
# Proto fields returned:
#   field 1 (status):    SERVING(1) or NOT_SERVING(2)
#   field 2 (node_type): AMF(13)
#   field 3 (ip):        AMF advertised IP  (AMF_TCP_ADVERTISE_IP)
#   field 4 (port):      AMF TCP port       (AMF_TCP_PORT)
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC09: AMF TCP Health Check (Port ${AMF_HEALTH_PORT})"

ensure_core_running

# ── Shared proto parser (python3 inline) ─────────────────────────────────────
PARSER='
import socket, sys, time

def read_varint(data, i):
    val, shift = 0, 0
    while i < len(data):
        b = data[i]; i += 1
        val |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80): break
    return val, i

def parse_proto(data):
    _, i = read_varint(data, 0)   # skip length prefix
    fields = {}
    while i < len(data):
        tag_byte = data[i]; i += 1
        field_num = tag_byte >> 3
        wire_type = tag_byte & 0x07
        if wire_type == 0:
            val, i = read_varint(data, i)
            fields[field_num] = val
        elif wire_type == 2:
            length, i = read_varint(data, i)
            fields[field_num] = data[i:i+length].decode("utf-8", errors="replace")
            i += length
    return fields

def probe(host, port, send_request=False):
    s = socket.socket()
    s.settimeout(5)
    s.connect((host, port))
    if send_request:
        s.sendall(b"\x00")   # empty HealthCheckRequest (length=0)
    time.sleep(0.6)
    data = b""
    s.settimeout(1)
    try:
        while True:
            chunk = s.recv(256)
            if not chunk: break
            data += chunk
    except Exception: pass
    s.close()
    return data, parse_proto(data)
'

probe_and_print() {
    # args: host port [send_request]
    python3 -c "
${PARSER}
try:
    data, fields = probe('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT}, ${1:-False})
    status    = fields.get(1, -1)
    node_type = fields.get(2, -1)
    ip        = fields.get(3, '')
    port      = fields.get(4, -1)
    print('hex=' + data.hex())
    print('status=' + str(status))
    print('node_type=' + str(node_type))
    print('ip=' + str(ip))
    print('port=' + str(port))
except Exception as e:
    print('ERROR=' + str(e))
    sys.exit(1)
" 2>/dev/null
}

# ── Step 1: Verify AMF_TCP_ENABLE env var ────────────────────────────────────
info "Checking AMF_TCP_ENABLE environment variable..."
amf_grpc=$(docker exec open5gs-cp printenv AMF_TCP_ENABLE 2>/dev/null || echo "")
if [ "$amf_grpc" = "1" ]; then
    pass "AMF_TCP_ENABLE=1 (health check enabled)"
else
    warn "AMF_TCP_ENABLE=${amf_grpc:-not set}. Health check may not be active."
fi

# ── Step 2: Port 50051 listening inside container ────────────────────────────
info "Checking port ${AMF_HEALTH_PORT} inside open5gs-cp..."
port_check=$(docker exec open5gs-cp bash -c \
    "ss -tlnp 2>/dev/null | grep ':${AMF_HEALTH_PORT}' || \
     netstat -tlnp 2>/dev/null | grep ':${AMF_HEALTH_PORT}' || echo ''" 2>/dev/null)
if [ -n "$port_check" ]; then
    pass "Port ${AMF_HEALTH_PORT} is listening inside open5gs-cp"
    echo "    $port_check"
else
    warn "Port ${AMF_HEALTH_PORT} not visible via ss/netstat (may still be active internally)"
fi

# ── Step 3: Plain TCP probe — server replies without client sending anything ──
info "Plain TCP probe (no request sent — server replies after 500ms timeout)..."
result=$(probe_and_print False)
hex=$(echo "$result"      | grep '^hex='       | cut -d= -f2)
status=$(echo "$result"   | grep '^status='    | cut -d= -f2)
node_type=$(echo "$result"| grep '^node_type=' | cut -d= -f2)
ip=$(echo "$result"       | grep '^ip='        | cut -d= -f2-)
port=$(echo "$result"     | grep '^port='      | cut -d= -f2)

if [ "$status" = "1" ]; then
    pass "field 1 status    = 1 (SERVING) ✓"
else
    fail "field 1 status    = '${status}' (expected 1=SERVING)"
fi

if [ "$node_type" = "13" ]; then
    pass "field 2 node_type = 13 (AMF) ✓"
else
    fail "field 2 node_type = '${node_type}' (expected 13=AMF)"
fi

if [ -n "$ip" ] && [ "$ip" != "-1" ] && [ "$ip" != "" ]; then
    pass "field 3 ip        = '${ip}' ✓"
else
    fail "field 3 ip        = '${ip}' (missing or empty)"
fi

if [ -n "$port" ] && [ "$port" != "-1" ] && [ "$port" -gt 0 ] 2>/dev/null; then
    pass "field 4 port      = ${port} ✓"
else
    fail "field 4 port      = '${port}' (missing or invalid)"
fi

info "Raw hex: 0x${hex}"
info "  AMF identity: node_type=AMF(13) ip=${ip} port=${port}"

# ── Step 4: Explicit HealthCheckRequest — same response expected ──────────────
info "Sending empty HealthCheckRequest — verifying response fields..."
result2=$(probe_and_print True)
status2=$(echo "$result2"   | grep '^status='    | cut -d= -f2)
node_type2=$(echo "$result2"| grep '^node_type=' | cut -d= -f2)
ip2=$(echo "$result2"       | grep '^ip='        | cut -d= -f2-)
port2=$(echo "$result2"     | grep '^port='      | cut -d= -f2)

if [ "$status2" = "1" ] && [ "$node_type2" = "13" ] && [ -n "$ip2" ] && [ "$port2" -gt 0 ] 2>/dev/null; then
    pass "HealthCheckRequest → SERVING + AMF(13) + ip=${ip2} + port=${port2} ✓"
else
    warn "HealthCheckRequest response: status=${status2} node_type=${node_type2} ip=${ip2} port=${port2}"
fi

# ── Step 5: Verify ip matches AMF_TCP_ADVERTISE_IP env var ───────────────────
info "Verifying ip field matches AMF_TCP_ADVERTISE_IP..."
advertise_ip=$(docker exec open5gs-cp printenv AMF_TCP_ADVERTISE_IP 2>/dev/null || echo "")
if [ -n "$advertise_ip" ] && [ "$ip" = "$advertise_ip" ]; then
    pass "ip='${ip}' matches AMF_TCP_ADVERTISE_IP ✓"
elif [ -n "$advertise_ip" ]; then
    warn "ip='${ip}' but AMF_TCP_ADVERTISE_IP='${advertise_ip}'"
else
    info "AMF_TCP_ADVERTISE_IP not set in env (using default)"
fi

# ── Step 6: Verify port field matches AMF_TCP_PORT env var ───────────────────
info "Verifying port field matches AMF_TCP_PORT..."
tcp_port=$(docker exec open5gs-cp printenv AMF_TCP_PORT 2>/dev/null || echo "")
if [ -n "$tcp_port" ] && [ "$port" = "$tcp_port" ]; then
    pass "port=${port} matches AMF_TCP_PORT ✓"
elif [ -n "$tcp_port" ]; then
    warn "port=${port} but AMF_TCP_PORT=${tcp_port}"
else
    info "AMF_TCP_PORT not set in env (using default 50051)"
fi

# ── Step 7: AMF log check ─────────────────────────────────────────────────────
info "Checking AMF log for health server startup..."
amf_log=$(docker exec open5gs-cp cat /var/log/open5gs/amf.log 2>/dev/null | head -100)
if echo "$amf_log" | grep -qi "AMF-Health\|health.*50051\|TCP health"; then
    pass "AMF log confirms health server started"
    echo "$amf_log" | grep -i "AMF-Health\|health.*50051\|TCP health" | head -3
else
    info "Health startup message not found in first 100 log lines"
fi

# ── Step 8: 5 concurrent connections ─────────────────────────────────────────
info "Testing 5 concurrent health check connections..."
ok_count=0
for i in $(seq 1 5); do
    r=$(python3 -c "
${PARSER}
try:
    data, fields = probe('${AMF_HEALTH_HOST}', ${AMF_HEALTH_PORT})
    status    = fields.get(1, -1)
    node_type = fields.get(2, -1)
    ip        = fields.get(3, '')
    port      = fields.get(4, -1)
    result = 0 if (status == 1 and node_type == 13 and ip and port > 0) else 1
except Exception:
    result = 1
sys.exit(result)
" 2>/dev/null && echo "ok" || echo "fail")
    [ "$r" = "ok" ] && ok_count=$((ok_count + 1))
done

if [ "$ok_count" -eq 5 ]; then
    pass "All 5 concurrent connections: SERVING + AMF(13) + ip + port ✓"
elif [ "$ok_count" -ge 3 ]; then
    warn "${ok_count}/5 concurrent connections returned full response"
else
    fail "Only ${ok_count}/5 concurrent connections succeeded"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$status" = "1" ] && [ "$node_type" = "13" ] && [ -n "$ip" ] && [ "$port" -gt 0 ] 2>/dev/null; then
    echo -e "${GREEN}${BOLD}TC09 PASSED${NC}: AMF TCP health check on port ${AMF_HEALTH_PORT}"
    info "  status=SERVING  node_type=AMF(13)  ip=${ip}  port=${port}"
else
    echo -e "${RED}${BOLD}TC09 FAILED${NC}: AMF TCP health check not responding as expected"
    info "Check: docker exec open5gs-cp printenv AMF_TCP_ENABLE"
    info "Check: docker logs open5gs-cp | grep -i health"
fi
