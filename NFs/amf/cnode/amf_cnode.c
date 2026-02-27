/*
 * amf_cnode.c — AMF outbound cnode registration + health-check client.
 *
 * See amf_cnode.h for full description and configuration.
 *
 * ── Wire format (matches working MME implementation) ─────────────────
 *
 *   Every message in BOTH directions is framed as:
 *
 *       [ uint32_t payload_length (4 bytes, native LE) ][ payload bytes ]
 *
 *   This is exactly what the MME sendData() / recvData() use:
 *
 *       std::memcpy(buf, &payload_length, sizeof payload_length);   // send
 *       async_read(sock, buffer(&payload_length_, sizeof ...));      // recv
 *
 * ── Session flow ──────────────────────────────────────────────────────
 *
 *   1. AMF dials TCP to cnode server
 *   2. AMF sends  NodeType_Message { nodetype: AMF(13) }
 *      (same proto field as MME sends NodeType_Message { nodetype: MME(2) })
 *   3. cnode server sends HealthCheckRequest messages back on same conn
 *   4. AMF replies with HealthCheckResponse { status: SERVING(1) }
 *   5. Loop — reconnect with exponential backoff on any error
 *
 * ── Proto wire encoding (hand-coded, no external library) ────────────
 *
 *   NodeType_Message { nodetype: AMF=13 }
 *     field 1 varint 13 → 0x08 0x0D   (2 bytes)
 *     framed: [02 00 00 00][08 0D]
 *
 *   HealthCheckResponse { status: SERVING=1 }
 *     field 1 varint 1  → 0x08 0x01   (2 bytes)
 *     framed: [02 00 00 00][08 01]
 */

#include "ogs-app.h"
#include "cnode/amf_cnode.h"

#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ====================================================================
 * Framed I/O helpers
 *
 * Wire format: [uint32_t length (4 bytes LE)][payload]
 * Matches MME's sendData() / recvData() exactly.
 * ==================================================================== */

/*
 * read_framed() — read one length-prefixed message from fd into buf.
 * Returns payload length on success, -1 on error/EOF.
 * fd must already be connected; no timeout is set (use poll before calling).
 */
static int read_framed(int fd, uint8_t *buf, int max_len)
{
    uint32_t payload_len = 0;
    int      total;
    int      n;

    /* Read 4-byte LE length header */
    total = 0;
    while (total < 4) {
        n = (int)recv(fd, (char *)&payload_len + total, 4 - total, 0);
        if (n <= 0) return -1;
        total += n;
    }

    if (payload_len == 0) return 0;
    if ((int)payload_len > max_len) return -1;

    /* Read exactly payload_len bytes */
    total = 0;
    while (total < (int)payload_len) {
        n = (int)recv(fd, buf + total, (int)payload_len - total, 0);
        if (n <= 0) return -1;
        total += n;
    }
    return (int)payload_len;
}

/*
 * write_framed() — write one length-prefixed message to fd.
 * Returns 0 on success, -1 on error.
 */
static int write_framed(int fd, const uint8_t *data, int data_len)
{
    uint32_t payload_len = (uint32_t)data_len;

    /* Write 4-byte LE length header */
    if ((int)send(fd, &payload_len, sizeof payload_len, MSG_NOSIGNAL)
            != (int)sizeof payload_len)
        return -1;

    /* Write payload */
    if (data_len > 0) {
        if ((int)send(fd, data, (size_t)data_len, MSG_NOSIGNAL) != data_len)
            return -1;
    }
    return 0;
}

/* ====================================================================
 * Proto message bytes (hand-encoded)
 * ==================================================================== */

/*
 * NodeType_Message { nodetype: AMF(13) }
 *   field 1, wire type 0 (varint), value 13
 *   → 0x08 0x0D
 */
static const uint8_t NODETYPE_AMF[]       = { 0x08, 0x0D };

/*
 * HealthCheckResponse { status: SERVING(1) }
 *   field 1, wire type 0 (varint), value 1
 *   → 0x08 0x01
 */
static const uint8_t HEALTH_RESP_SERVING[] = { 0x08, 0x01 };

/* ====================================================================
 * Client configuration (read once at amf_cnode_start)
 * ==================================================================== */

static volatile int g_running   = 0;
static pthread_t    g_thread;
static char         g_server_ip[64] = "";
static uint16_t     g_server_port   = 9090;

/* ====================================================================
 * One connection session: dial → register → serve health checks
 *
 * Returns:
 *    0  — clean stop (g_running was cleared)
 *   -1  — connection error (caller retries with backoff)
 * ==================================================================== */
static int serve_session(void)
{
    int              sfd;
    struct sockaddr_in srv;
    struct timeval   tv;
    uint8_t          req_buf[256];
    int              n;

    memset(&srv, 0, sizeof srv);
    srv.sin_family = AF_INET;
    srv.sin_port   = htons(g_server_port);
    if (inet_pton(AF_INET, g_server_ip, &srv.sin_addr) <= 0) {
        ogs_error("[AMF-cnode] invalid server IP '%s'", g_server_ip);
        return -1;
    }

    sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) {
        ogs_warn("[AMF-cnode] socket() failed: %s", strerror(errno));
        return -1;
    }

    /* 5-second connect + write timeout */
    tv.tv_sec = 5; tv.tv_usec = 0;
    setsockopt(sfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    if (connect(sfd, (struct sockaddr *)&srv, sizeof srv) < 0) {
        ogs_warn("[AMF-cnode] connect(%s:%u) failed: %s",
                 g_server_ip, (unsigned)g_server_port, strerror(errno));
        close(sfd);
        return -1;
    }

    ogs_info("[AMF-cnode] connected to %s:%u",
             g_server_ip, (unsigned)g_server_port);

    /* ── Step 1: Send NodeType_Message { nodetype: AMF(13) } ── */
    if (write_framed(sfd, NODETYPE_AMF, (int)sizeof NODETYPE_AMF) < 0) {
        ogs_warn("[AMF-cnode] send NodeType_Message failed: %s",
                 strerror(errno));
        close(sfd);
        return -1;
    }
    ogs_info("[AMF-cnode] sent NodeType_Message { nodetype: AMF }");

    /* ── Step 2: Serve HealthCheckRequests on the same connection ── */
    while (g_running) {
        struct pollfd pfd;
        int rc;

        /* Poll for incoming data with a 5-second timeout so we can
         * re-check g_running without blocking forever. */
        pfd.fd      = sfd;
        pfd.events  = POLLIN;
        pfd.revents = 0;
        rc = poll(&pfd, 1, 5000);

        if (rc < 0) {
            if (errno == EINTR) continue;
            ogs_warn("[AMF-cnode] poll() error: %s", strerror(errno));
            break;
        }
        if (rc == 0) continue;   /* timeout — loop back and check g_running */

        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            ogs_warn("[AMF-cnode] connection closed by server");
            break;
        }

        /* Data available — read the full HealthCheckRequest frame */
        n = read_framed(sfd, req_buf, (int)sizeof req_buf);
        if (n < 0) {
            ogs_warn("[AMF-cnode] read HealthCheckRequest failed: %s",
                     strerror(errno));
            break;
        }

        /* Reply with HealthCheckResponse { status: SERVING } */
        if (write_framed(sfd, HEALTH_RESP_SERVING,
                         (int)sizeof HEALTH_RESP_SERVING) < 0) {
            ogs_warn("[AMF-cnode] send HealthCheckResponse failed: %s",
                     strerror(errno));
            break;
        }

        ogs_debug("[AMF-cnode] health-check → SERVING");
    }

    close(sfd);
    return g_running ? -1 : 0;
}

/* ====================================================================
 * Background thread: connect, register, serve; retry with backoff
 * ==================================================================== */
static void *cnode_thread(void *arg)
{
    unsigned int backoff = 1;   /* seconds */
    (void)arg;

    while (g_running) {
        int rc = serve_session();
        if (rc == 0) break;   /* clean stop */

        /* Exponential backoff capped at 30 s */
        ogs_info("[AMF-cnode] session ended; reconnecting in %u s", backoff);

        unsigned int slept = 0;
        while (slept < backoff && g_running) {
            sleep(1);
            slept++;
        }

        backoff *= 2;
        if (backoff > 30) backoff = 30;
    }

    ogs_info("[AMF-cnode] client thread stopped");
    return NULL;
}

/* ====================================================================
 * Public API
 * ==================================================================== */

int amf_cnode_start(void)
{
    const char *env;

    /* AMF_CNODE_ENABLE (default: enabled) */
    env = getenv("AMF_CNODE_ENABLE");
    if (env && strcmp(env, "1") != 0) {
        ogs_info("[AMF-cnode] disabled via AMF_CNODE_ENABLE=%s", env);
        return OGS_OK;
    }

    /* AMF_CNODE_SERVER_IP is required; absence silently disables cnode */
    env = getenv("AMF_CNODE_SERVER_IP");
    if (!env || !env[0]) {
        ogs_info("[AMF-cnode] AMF_CNODE_SERVER_IP not set; cnode disabled");
        return OGS_OK;
    }
    snprintf(g_server_ip, sizeof g_server_ip, "%s", env);

    env = getenv("AMF_CNODE_SERVER_PORT");
    if (env && atoi(env) > 0)
        g_server_port = (uint16_t)atoi(env);

    g_running = 1;
    if (pthread_create(&g_thread, NULL, cnode_thread, NULL) != 0) {
        ogs_error("[AMF-cnode] pthread_create failed: %s", strerror(errno));
        g_running = 0;
        return OGS_ERROR;
    }

    ogs_info("[AMF-cnode] client started → %s:%u",
             g_server_ip, (unsigned)g_server_port);
    return OGS_OK;
}

void amf_cnode_stop(void)
{
    if (!g_running) return;
    g_running = 0;
    pthread_join(g_thread, NULL);
    ogs_info("[AMF-cnode] client stopped");
}
