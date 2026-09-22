#!/bin/bash
# Healthcheck tf-kafka: брокер отвечает на клиентском listener
# и контроллер KRaft выбран (LeaderId не -1).

set -Eeuo pipefail

ADMIN_CONFIG="$(bash /opt/tf/client-config.sh admin)"

STATUS="$(
    /opt/kafka/bin/kafka-metadata-quorum.sh \
        --bootstrap-server tf-kafka:9092 \
        --command-config "$ADMIN_CONFIG" \
        describe --status
)"

echo "$STATUS" | grep -Eq '^LeaderId:[[:space:]]+[0-9]+[[:space:]]*$'
