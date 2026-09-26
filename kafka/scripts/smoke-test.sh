#!/bin/bash
# Ручная проверка критериев приёмки. Запускается внутри tf-kafka:
#
#   docker exec -it tf-kafka bash /opt/tf/smoke-test.sh produce
#   docker restart tf-kafka
#   docker exec -it tf-kafka bash /opt/tf/smoke-test.sh consume <marker>
#   docker exec -it tf-kafka bash /opt/tf/smoke-test.sh deny
#
# Тестовые сообщения пишутся в tf.dlq с ключом smoke-test.

set -Euo pipefail

BOOTSTRAP="tf-kafka:9092"
KAFKA_BIN="/opt/kafka/bin"
TOPIC="tf.dlq"

config() {
    bash /opt/tf/client-config.sh "$1"
}

case "${1:-}" in

    produce)
        MARKER="smoke-$(date +%s)"
        echo "smoke-test:$MARKER" | "$KAFKA_BIN/kafka-console-producer.sh" \
            --bootstrap-server "$BOOTSTRAP" \
            --producer.config "$(config tf-funnel)" \
            --topic "$TOPIC" \
            --property parse.key=true \
            --property key.separator=:
        echo "Produced as tf-funnel to $TOPIC: $MARKER"
        echo "Now restart the container and run: smoke-test.sh consume $MARKER"
        ;;

    consume)
        MARKER="${2:?Usage: $0 consume <marker>}"
        if "$KAFKA_BIN/kafka-console-consumer.sh" \
            --bootstrap-server "$BOOTSTRAP" \
            --consumer.config "$(config admin)" \
            --topic "$TOPIC" \
            --from-beginning \
            --timeout-ms 15000 \
            2>/dev/null | grep -qxF "$MARKER"; then
            echo "OK: message $MARKER found in $TOPIC"
        else
            echo "FAIL: message $MARKER not found in $TOPIC"
            exit 1
        fi
        ;;

    deny)
        failed=0

        echo "Check: tf-bff must NOT write to tf.ingest.readings..."
        OUTPUT="$(echo "denied" | timeout 60 "$KAFKA_BIN/kafka-console-producer.sh" \
            --bootstrap-server "$BOOTSTRAP" \
            --producer.config "$(config tf-bff)" \
            --topic tf.ingest.readings 2>&1)"
        if echo "$OUTPUT" | grep -q "AuthorizationException"; then
            echo "  OK: access denied"
        else
            echo "  FAIL: no authorization error"; echo "$OUTPUT"; failed=1
        fi

        echo "Check: tf-funnel must NOT read tf.ingest.readings..."
        OUTPUT="$(timeout 60 "$KAFKA_BIN/kafka-console-consumer.sh" \
            --bootstrap-server "$BOOTSTRAP" \
            --consumer.config "$(config tf-funnel)" \
            --topic tf.ingest.readings \
            --group tf-funnel-smoke \
            --timeout-ms 15000 2>&1)"
        if echo "$OUTPUT" | grep -q "AuthorizationException"; then
            echo "  OK: access denied"
        else
            echo "  FAIL: no authorization error"; echo "$OUTPUT"; failed=1
        fi

        exit "$failed"
        ;;

    *)
        echo "Usage: $0 produce | consume <marker> | deny"
        exit 1
        ;;
esac
