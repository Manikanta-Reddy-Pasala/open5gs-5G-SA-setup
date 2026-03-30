/*
 * amf_cnode.h — AMF outbound cnode registration + health-check client.
 *
 * Architecture:
 *   AMF dials OUT to the cnode server (no inbound server on AMF).
 *   Sends NodeType_Message { nodetype: AMF(13) } — identical to how
 *   the MME sends NodeType_Message { nodetype: MME(2) }.
 *   The cnode server then sends HealthCheckRequests back on the SAME
 *   persistent TCP connection; AMF replies with HealthCheckResponse{SERVING}.
 *   Reconnects with exponential backoff (1→2→4→…→30 s) on failure.
 *
 * Wire format (matches working MME sendData / recvData):
 *   [ uint32_t payload_length (4 bytes, native LE) ][ payload bytes ]
 *
 * Configuration (environment variables):
 *   AMF_CNODE_ENABLE      1|0  (default: 1; any value ≠ "1" disables)
 *   AMF_CNODE_SERVER_IP   cnode server IPv4 address (required; unset = disabled)
 *   AMF_CNODE_SERVER_PORT cnode server port (default: 9090)
 */

#ifndef AMF_CNODE_H
#define AMF_CNODE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * amf_cnode_start() — start the cnode client in a background thread.
 *
 * Call after ngap_open() in amf_initialize().
 * No-op (returns OGS_OK) if AMF_CNODE_SERVER_IP is unset or
 * AMF_CNODE_ENABLE is not "1".
 * Returns OGS_OK on success, OGS_ERROR on failure.
 */
int  amf_cnode_start(void);

/*
 * amf_cnode_stop() — signal the client to stop and join the thread.
 *
 * Call before ngap_close() in amf_terminate().
 * No-op if amf_cnode_start() was skipped.
 */
void amf_cnode_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* AMF_CNODE_H */
