#!/bin/bash
# ============================================================
# provision.sh — Provision subscribers (shared database)
# ============================================================
# Usage:
#   ./scripts/provision.sh                            # Provision default subscriber
#   ./scripts/provision.sh --count 10                 # Bulk provision 10 subscribers
#   ./scripts/provision.sh --imsi 001010000050641 --k <key> --opc <opc>
# ============================================================

set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_DIR"

COUNT=1
IMSI="$DEFAULT_IMSI"
K="$DEFAULT_K"
OPC="$DEFAULT_OPC"
AMF_FIELD="$DEFAULT_AMF_FIELD"
SST="$DEFAULT_SST"
SD="$DEFAULT_SD"
DNN="$DEFAULT_DNN"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT="$2"; shift ;;
        --imsi)  IMSI="$2"; shift ;;
        --k)     K="$2"; shift ;;
        --opc)   OPC="$2"; shift ;;
        --sst)   SST="$2"; shift ;;
        --sd)    SD="$2"; shift ;;
        --dnn)   DNN="$2"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

DB_NAME="open5gs"

hdr ""
hdr "  Provisioning ${COUNT} subscriber(s) into shared DB (${DB_NAME})"
hdr ""

imsi_num="${IMSI: -10}"
imsi_prefix="${IMSI:0:${#IMSI}-10}"

for i in $(seq 0 $((COUNT - 1))); do
    cur_imsi="${imsi_prefix}$(printf '%010d' $((10#$imsi_num + i)))"

    # Increment last byte of key for uniqueness
    cur_k="$K"
    if [ "$COUNT" -gt 1 ]; then
        key_end="${K: -2}"
        key_start="${K:0:${#K}-2}"
        cur_k="${key_start}$(printf '%02x' $(( (16#${key_end} + i) % 256 )))"
    fi

    mongosh "mongodb://localhost:27017/${DB_NAME}" --quiet --eval "
        db.subscribers.deleteOne({ imsi: '${cur_imsi}' });
        db.subscribers.insertOne({
            imsi: '${cur_imsi}',
            subscribed_rau_tau_timer: 12,
            network_access_mode: 0,
            subscriber_status: 0,
            access_restriction_data: 32,
            slice: [{
                sst: ${SST},
                sd: '${SD}',
                default_indicator: true,
                session: [{
                    name: '${DNN}',
                    type: 3,
                    pcc_rule: [],
                    ambr: {
                        uplink:   { value: 1, unit: 3 },
                        downlink: { value: 1, unit: 3 }
                    },
                    qos: {
                        index: 9,
                        arp: {
                            priority_level: 8,
                            pre_emption_capability: 1,
                            pre_emption_vulnerability: 1
                        }
                    }
                }]
            }],
            ambr: {
                uplink:   { value: 1, unit: 3 },
                downlink: { value: 1, unit: 3 }
            },
            security: {
                k:   '${cur_k^^}',
                opc: '${OPC^^}',
                amf: '${AMF_FIELD}',
                sqn: NumberLong(32)
            },
            schema_version: 1,
            __v: 0
        });
        print('Provisioned: ${cur_imsi}');
    " 2>/dev/null && ok "  [${cur_imsi}]" || warn "  [${cur_imsi}] FAILED"
done

total=$(mongosh "mongodb://localhost:27017/${DB_NAME}" --quiet \
    --eval "db.subscribers.countDocuments()" 2>/dev/null | tail -1)

hdr ""
ok "Provisioning complete. Total subscribers in ${DB_NAME}: ${total} (shared across all TRX instances)"
hdr ""
