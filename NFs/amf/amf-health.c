/*
 * AMF TCP Health Check Server & Registration Client
 *
 * Wire-format compatible with the free5GC AMF gRPC health check.
 *
 * See amf-health.h for the full description and configuration env vars.
 */

#include "ogs-app.h"
#include "amf-health.h"

#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* =========================================================
 * Protobuf varint + delimited-message helpers
 * (no external library — hand-coded for 3 simple message types)
 * ========================================================= */

/* Encode a 64-bit varint into buf.  Returns bytes written, -1 on overflow. */
static int varint_encode(uint64_t v, uint8_t *buf, int bufsz)
{
    int n = 0;
    do {
        if (n >= bufsz) return -1;
        uint8_t b = (uint8_t)(v & 0x7F);
        v >>= 7;
        if (v) b |= 0x80;
        buf[n++] = b;
    } while (v);
    return n;
}

/*
 * Read one varint-length-prefixed message from fd into buf (up to max_len).
 * Returns payload length on success, -1 on error or timeout.
 * The socket's SO_RCVTIMEO controls timeout behaviour.
 */
static int read_delimited(int fd, uint8_t *buf, int max_len)
{
    /* Read the length varint byte by byte */
    uint64_t msg_len = 0;
    int shift = 0;
    int i;
    for (i = 0; i < 10; i++) {
        uint8_t b;
        int n = (int)recv(fd, &b, 1, 0);
        if (n <= 0) return -1;  /* timeout or EOF */
        msg_len |= (uint64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    if (msg_len == 0) return 0;
    if ((int)msg_len > max_len) return -1;

    /* Read exactly msg_len bytes */
    int total = 0;
    while (total < (int)msg_len) {
        int n = (int)recv(fd, buf + total, (int)msg_len - total, 0);
        if (n <= 0) return -1;
        total += n;
    }
    return total;
}

/*
 * Write one varint-length-prefixed raw buffer to fd.
 * Returns 0 on success, -1 on error.
 */
static int write_delimited(int fd, const uint8_t *data, int data_len)
{
    uint8_t lenbuf[10];
    int lbytes = varint_encode((uint64_t)data_len, lenbuf, sizeof(lenbuf));
    if (lbytes < 0) return -1;

    if ((int)send(fd, lenbuf, (size_t)lbytes, MSG_NOSIGNAL) != lbytes) return -1;
    if ((int)send(fd, data, (size_t)data_len, MSG_NOSIGNAL) != data_len) return -1;
    return 0;
}

/* =========================================================
 * HealthCheckResponse wire encoding
 *
 * Proto:   message HealthCheckResponse { ServingStatus status = 1; }
 * SERVING     field 1 varint 1 → bytes { 0x08, 0x01 }
 * NOT_SERVING field 1 varint 2 → bytes { 0x08, 0x02 }
 *
 * On the wire (varint-length-prefixed):
 *   SERVING     → { 0x02, 0x08, 0x01 }
 *   NOT_SERVING → { 0x02, 0x08, 0x02 }
 * ========================================================= */
static const uint8_t HEALTH_RESP_SERVING[2]     = { 0x08, 0x01 };
static const uint8_t HEALTH_RESP_NOT_SERVING[2] = { 0x08, 0x02 };
#define HEALTH_RESP_LEN 2

/* =========================================================
 * Server state
 * ========================================================= */
static int              server_fd      = -1;
static pthread_t        server_thread;
static volatile int     server_running = 0;

/* Advertised IP / port stored at open time (for registration) */
static char     g_bind_addr[64]     = "0.0.0.0";
static char     g_advertise_ip[64]  = "0.0.0.0";
static uint16_t g_port              = 50051;

/* Registration config */
static int      g_reg_enable        = 0;
static char     g_reg_server_ip[64] = "";
static uint16_t g_reg_server_port   = 0;

/* =========================================================
 * Per-connection handler (called from accept loop)
 * ========================================================= */
static void handle_connection(int cfd)
{
    /* Give the client 500 ms to send a HealthCheckRequest.
     * A plain TCP probe (k8s liveness, load-balancers) that sends nothing
     * will still receive a SERVING response once the deadline fires. */
    struct timeval tv = { .tv_sec = 0, .tv_usec = 500000 };
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t req_buf[64];
    /* Ignore the HealthCheckRequest payload; we always reply SERVING */
    read_delimited(cfd, req_buf, (int)sizeof(req_buf));

    /* Clear the read deadline before writing */
    struct timeval tv_zero = { 0, 0 };
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv_zero, sizeof(tv_zero));

    write_delimited(cfd, HEALTH_RESP_SERVING, HEALTH_RESP_LEN);
    close(cfd);
}

/* =========================================================
 * TCP accept loop (runs in server_thread)
 * ========================================================= */
static void *health_server_loop(void *arg)
{
    (void)arg;
    ogs_info("[AMF-Health] TCP health server listening on %s:%u",
             g_bind_addr, (unsigned)g_port);

    while (server_running) {
        struct sockaddr_in cli_addr;
        socklen_t cli_len = sizeof(cli_addr);
        int cfd = accept(server_fd, (struct sockaddr *)&cli_addr, &cli_len);
        if (cfd < 0) {
            if (!server_running) break;
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            if (errno == EBADF) break;  /* socket was closed */
            ogs_error("[AMF-Health] accept() error: %s", strerror(errno));
            continue;
        }
        handle_connection(cfd);
    }

    ogs_info("[AMF-Health] TCP health server stopped");
    return NULL;
}

/* =========================================================
 * Public API — amf_health_open / amf_health_close
 * ========================================================= */
int amf_health_open(void)
{
    const char *env;

    /* Read config from environment */
    env = getenv("AMF_GRPC_ENABLE");
    if (env && strcmp(env, "1") != 0) {
        ogs_info("[AMF-Health] Disabled via AMF_GRPC_ENABLE=%s", env);
        return OGS_OK;
    }

    env = getenv("AMF_GRPC_PORT");
    if (env && atoi(env) > 0)
        g_port = (uint16_t)atoi(env);

    env = getenv("AMF_GRPC_BIND_ADDR");
    if (env && strlen(env) > 0)
        strncpy(g_bind_addr, env, sizeof(g_bind_addr) - 1);

    env = getenv("AMF_GRPC_ADVERTISE_IP");
    if (env && strlen(env) > 0)
        strncpy(g_advertise_ip, env, sizeof(g_advertise_ip) - 1);
    else
        strncpy(g_advertise_ip, g_bind_addr, sizeof(g_advertise_ip) - 1);

    env = getenv("AMF_GRPC_REGISTRATION_ENABLE");
    g_reg_enable = (env && strcmp(env, "1") == 0) ? 1 : 0;

    if (g_reg_enable) {
        env = getenv("AMF_GRPC_REGISTRATION_SERVER_IP");
        if (env) strncpy(g_reg_server_ip, env, sizeof(g_reg_server_ip) - 1);

        env = getenv("AMF_GRPC_REGISTRATION_SERVER_PORT");
        if (env && atoi(env) > 0)
            g_reg_server_port = (uint16_t)atoi(env);
    }

    /* Create listening socket */
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        ogs_error("[AMF-Health] socket() failed: %s", strerror(errno));
        return OGS_ERROR;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(g_port);
    inet_pton(AF_INET, g_bind_addr, &addr.sin_addr);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ogs_error("[AMF-Health] bind(%s:%u) failed: %s",
                  g_bind_addr, (unsigned)g_port, strerror(errno));
        close(server_fd);
        server_fd = -1;
        return OGS_ERROR;
    }

    if (listen(server_fd, 16) < 0) {
        ogs_error("[AMF-Health] listen() failed: %s", strerror(errno));
        close(server_fd);
        server_fd = -1;
        return OGS_ERROR;
    }

    server_running = 1;
    if (pthread_create(&server_thread, NULL, health_server_loop, NULL) != 0) {
        ogs_error("[AMF-Health] pthread_create() failed: %s", strerror(errno));
        server_running = 0;
        close(server_fd);
        server_fd = -1;
        return OGS_ERROR;
    }

    return OGS_OK;
}

void amf_health_close(void)
{
    if (server_fd < 0) return;

    server_running = 0;
    close(server_fd);
    server_fd = -1;

    pthread_join(server_thread, NULL);
    ogs_info("[AMF-Health] TCP health server closed");
}

/* =========================================================
 * Registration client
 *
 * Encodes RegisterRequest { node_type=AMF(13), ip, port } and sends
 * it to the configured registration server.
 *
 * Protobuf encoding:
 *   field 1 (node_type, varint): tag=0x08, value=13   → 0x08 0x0D
 *   field 2 (ip, length-delimited): tag=0x12, len, <bytes>
 *   field 3 (port, varint): tag=0x18, <varint>
 *
 * RegisterResponse (optional):
 *   field 1 (success, bool/varint): tag=0x08, value=1 (true) or 0
 *   field 2 (message, string): tag=0x12, len, <bytes>
 * ========================================================= */

static void *do_registration(void *arg)
{
    (void)arg;

    /* Build RegisterRequest proto */
    uint8_t proto[256];
    int offset = 0;
    int vn;

    /* field 1: node_type = AMF = 13 */
    proto[offset++] = 0x08;
    proto[offset++] = 13;

    /* field 2: ip (string, length-delimited) */
    int ip_len = (int)strlen(g_advertise_ip);
    proto[offset++] = 0x12;
    vn = varint_encode((uint64_t)ip_len, proto + offset,
                       (int)sizeof(proto) - offset);
    if (vn < 0) goto done;
    offset += vn;
    memcpy(proto + offset, g_advertise_ip, (size_t)ip_len);
    offset += ip_len;

    /* field 3: port (varint) */
    proto[offset++] = 0x18;
    vn = varint_encode((uint64_t)g_port, proto + offset,
                       (int)sizeof(proto) - offset);
    if (vn < 0) goto done;
    offset += vn;

    {
        /* Dial the registration server */
        struct sockaddr_in srv;
        memset(&srv, 0, sizeof(srv));
        srv.sin_family = AF_INET;
        srv.sin_port   = htons(g_reg_server_port);
        if (inet_pton(AF_INET, g_reg_server_ip, &srv.sin_addr) <= 0) {
            ogs_warn("[AMF-Health] Registration: invalid server IP '%s'",
                     g_reg_server_ip);
            goto done;
        }

        int sfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sfd < 0) {
            ogs_warn("[AMF-Health] Registration: socket() failed: %s",
                     strerror(errno));
            goto done;
        }

        /* 5-second connect + I/O timeout */
        struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(sfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        setsockopt(sfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        if (connect(sfd, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
            ogs_warn("[AMF-Health] Registration: connect(%s:%u) failed: %s",
                     g_reg_server_ip, (unsigned)g_reg_server_port,
                     strerror(errno));
            close(sfd);
            goto done;
        }

        /* Send RegisterRequest */
        if (write_delimited(sfd, proto, offset) < 0) {
            ogs_warn("[AMF-Health] Registration: send failed: %s",
                     strerror(errno));
            close(sfd);
            goto done;
        }

        ogs_info("[AMF-Health] Registration sent → %s:%u "
                 "(node_type=AMF, ip=%s, port=%u)",
                 g_reg_server_ip, (unsigned)g_reg_server_port,
                 g_advertise_ip, (unsigned)g_port);

        /* Read optional RegisterResponse (server may not reply) */
        uint8_t resp_buf[128];
        int resp_len = read_delimited(sfd, resp_buf, (int)sizeof(resp_buf));
        if (resp_len >= 2 && resp_buf[0] == 0x08) {
            /* field 1: success (bool) */
            int success = (resp_buf[1] == 0x01);
            if (success)
                ogs_info("[AMF-Health] Registration: server accepted");
            else
                ogs_warn("[AMF-Health] Registration: server rejected");
        }

        close(sfd);
    }

done:
    return NULL;
}

void amf_health_send_registration(void)
{
    if (!g_reg_enable) return;
    if (!g_reg_server_ip[0] || !g_reg_server_port) {
        ogs_warn("[AMF-Health] Registration enabled but "
                 "AMF_GRPC_REGISTRATION_SERVER_IP / _PORT not set");
        return;
    }

    /* Fire and forget — detached thread so we never need to join it */
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, do_registration, NULL) != 0)
        ogs_warn("[AMF-Health] Registration: pthread_create failed: %s",
                 strerror(errno));
    pthread_attr_destroy(&attr);
}
