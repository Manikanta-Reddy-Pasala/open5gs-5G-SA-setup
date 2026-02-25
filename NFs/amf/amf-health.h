/*
 * AMF TCP Health Check Server & Registration Client
 *
 * Wire-format compatible with the free5GC AMF custom gRPC health check.
 *
 * Wire protocol (both directions):
 *   [varint: N][N bytes: proto-encoded message]
 *
 *   HealthCheckResponse { status: SERVING  }  → 0x02 0x08 0x01
 *   HealthCheckResponse { status: NOT_SERVING} → 0x02 0x08 0x02
 *
 *   RegisterRequest { node_type=AMF(13), ip="<bind_addr>", port=<port> }
 *
 * Configuration (env vars read at amf_health_open() time):
 *   AMF_GRPC_ENABLE           1|0  (default: 1)
 *   AMF_GRPC_PORT             TCP port to bind (default: 50051)
 *   AMF_GRPC_BIND_ADDR        IPv4 address to bind (default: 0.0.0.0)
 *   AMF_GRPC_ADVERTISE_IP     IP sent in RegisterRequest (default: 0.0.0.0)
 *   AMF_GRPC_REGISTRATION_ENABLE   1|0 (default: 0)
 *   AMF_GRPC_REGISTRATION_SERVER_IP     registration server IP
 *   AMF_GRPC_REGISTRATION_SERVER_PORT   registration server TCP port
 */

#ifndef AMF_HEALTH_H
#define AMF_HEALTH_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * amf_health_open() — start the TCP health check server.
 * Call after ngap_open() in amf_initialize().
 * Returns OGS_OK on success, OGS_ERROR on failure.
 */
int  amf_health_open(void);

/*
 * amf_health_close() — stop the TCP health check server.
 * Call before ngap_close() in amf_terminate().
 */
void amf_health_close(void);

/*
 * amf_health_send_registration() — fire-and-forget registration with
 * the configured registration server.  Call from amf_state_operational
 * OGS_FSM_ENTRY_SIG.  No-op if registration is not enabled.
 */
void amf_health_send_registration(void);

#ifdef __cplusplus
}
#endif

#endif /* AMF_HEALTH_H */
