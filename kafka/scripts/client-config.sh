#!/bin/bash
# Создаёт файл настроек клиента Kafka для пользователя и печатает путь к нему.
# Использование: client-config.sh <admin|tf-funnel|tf-model|tf-bff>

set -Eeuo pipefail

USER_NAME="${1:?Usage: $0 <admin|tf-funnel|tf-model|tf-bff>}"

case "$USER_NAME" in
    admin)      PASSWORD="${TF_KAFKA_ADMIN_PASSWORD:?TF_KAFKA_ADMIN_PASSWORD is not set}" ;;
    tf-funnel)  PASSWORD="${TF_KAFKA_FUNNEL_PASSWORD:?TF_KAFKA_FUNNEL_PASSWORD is not set}" ;;
    tf-model)   PASSWORD="${TF_KAFKA_MODEL_PASSWORD:?TF_KAFKA_MODEL_PASSWORD is not set}" ;;
    tf-bff)     PASSWORD="${TF_KAFKA_BFF_PASSWORD:?TF_KAFKA_BFF_PASSWORD is not set}" ;;
    *)
        echo "Unknown user: $USER_NAME" >&2
        exit 1
        ;;
esac

CONFIG_FILE="/tmp/tf-kafka-${USER_NAME}.properties"

umask 077
cat > "$CONFIG_FILE" <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${USER_NAME}" password="${PASSWORD}";
EOF

echo "$CONFIG_FILE"
