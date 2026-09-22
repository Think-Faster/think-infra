#!/bin/bash
# Healthcheck tf-kafka: брокер отвечает на клиентском listener
# и контроллер KRaft выбран (LeaderId не -1).

set -Eeuo pipefail

# Проверка запускает отдельную JVM: маленькая куча и быстрый старт,
# чтобы не отнимать процессор и память у брокера.
export KAFKA_HEAP_OPTS="-Xms32m -Xmx64m"
export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xshare:auto"

ADMIN_CONFIG="$(bash /opt/tf/client-config.sh admin)"

STATUS="$(
    /opt/kafka/bin/kafka-metadata-quorum.sh \
        --bootstrap-server tf-kafka:9092 \
        --command-config "$ADMIN_CONFIG" \
        describe --status
)"

echo "$STATUS" | grep -Eq '^LeaderId:[[:space:]]+[0-9]+[[:space:]]*$'
