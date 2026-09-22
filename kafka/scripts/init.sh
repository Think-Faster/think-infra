#!/bin/bash
# Создаёт топики из topics.conf и выдаёт права из acls.conf.
# Идемпотентен: существующие топики не пересоздаются, повторная выдача ACL ничего не меняет.

set -Eeuo pipefail

BOOTSTRAP="${KAFKA_BOOTSTRAP:-tf-kafka:9092}"
TOPICS_FILE="${TOPICS_FILE:-/etc/tf/topics.conf}"
ACLS_FILE="${ACLS_FILE:-/etc/tf/acls.conf}"
KAFKA_BIN="/opt/kafka/bin"

log() {
    echo "[KAFKA-INIT] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

error_handler() {
    local exit_code=$?
    log "ERROR: init.sh failed. Exit code: $exit_code. Line: ${BASH_LINENO[0]:-unknown}"
    exit "$exit_code"
}

trap error_handler ERR

# Читает конфиг: пропускает пустые строки и комментарии, убирает CR (файлы из Windows).
read_conf() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [ -n "$line" ] && echo "$line"
    done < "$1"
}

log "============================================================"
log "TF Kafka topics and ACL installer"
log "============================================================"
log "Bootstrap server: $BOOTSTRAP"
log "Topics file:      $TOPICS_FILE"
log "ACL file:         $ACLS_FILE"

[ -f "$TOPICS_FILE" ] || { log "ERROR: topics file not found: $TOPICS_FILE"; exit 1; }
[ -f "$ACLS_FILE" ]   || { log "ERROR: ACL file not found: $ACLS_FILE"; exit 1; }

ADMIN_CONFIG="$(bash /opt/tf/client-config.sh admin)"

# ============================================================
# Topics
# ============================================================

log "Reading existing topics..."

EXISTING_TOPICS="$(
    "$KAFKA_BIN/kafka-topics.sh" \
        --bootstrap-server "$BOOTSTRAP" \
        --command-config "$ADMIN_CONFIG" \
        --list
)"

topic_count=0

while read -r name partitions configs extra; do

    if [ -z "$name" ] || ! [[ "$partitions" =~ ^[1-9][0-9]*$ ]] || [ -n "${extra:-}" ]; then
        log "ERROR: invalid line in topics file: '$name $partitions $configs ${extra:-}'"
        exit 1
    fi

    topic_count=$((topic_count + 1))

    log "------------------------------------------------------------"
    log "Topic: $name (partitions: $partitions, config: ${configs:-<none>})"

    if echo "$EXISTING_TOPICS" | grep -qxF "$name"; then

        log "Topic already exists. It will NOT be recreated."

        actual_partitions="$(
            "$KAFKA_BIN/kafka-topics.sh" \
                --bootstrap-server "$BOOTSTRAP" \
                --command-config "$ADMIN_CONFIG" \
                --describe --topic "$name" \
            | grep -oE 'PartitionCount:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+'
        )"

        if [ "$actual_partitions" != "$partitions" ]; then
            log "WARNING: topic has $actual_partitions partitions, topics.conf says $partitions."
            log "WARNING: partitions are NOT changed automatically, see README."
        fi

        if [ -n "$configs" ]; then
            log "Applying config to existing topic..."
            "$KAFKA_BIN/kafka-configs.sh" \
                --bootstrap-server "$BOOTSTRAP" \
                --command-config "$ADMIN_CONFIG" \
                --alter --entity-type topics --entity-name "$name" \
                --add-config "$configs"
        fi

    else

        log "Creating topic..."

        config_args=()
        if [ -n "$configs" ]; then
            IFS=',' read -ra config_items <<< "$configs"
            for item in "${config_items[@]}"; do
                config_args+=(--config "$item")
            done
        fi

        "$KAFKA_BIN/kafka-topics.sh" \
            --bootstrap-server "$BOOTSTRAP" \
            --command-config "$ADMIN_CONFIG" \
            --create --if-not-exists \
            --topic "$name" \
            --partitions "$partitions" \
            --replication-factor 1 \
            "${config_args[@]}"

        log "Topic created."
    fi

done < <(read_conf "$TOPICS_FILE")

log "Topics processed: $topic_count"

# ============================================================
# ACL
# ============================================================

acl_count=0

while read -r principal resource_type pattern_type resource_name operations extra; do

    if [ -z "$operations" ] || [ -n "${extra:-}" ] \
        || ! [[ "$resource_type" =~ ^(topic|group)$ ]] \
        || ! [[ "$pattern_type" =~ ^(literal|prefixed)$ ]]; then
        log "ERROR: invalid line in ACL file: '$principal $resource_type $pattern_type $resource_name $operations ${extra:-}'"
        exit 1
    fi

    acl_count=$((acl_count + 1))

    log "ACL: User:$principal $operations on $resource_type $pattern_type '$resource_name'"

    operation_args=()
    IFS=',' read -ra operation_items <<< "$operations"
    for op in "${operation_items[@]}"; do
        operation_args+=(--operation "$op")
    done

    "$KAFKA_BIN/kafka-acls.sh" \
        --bootstrap-server "$BOOTSTRAP" \
        --command-config "$ADMIN_CONFIG" \
        --add \
        --allow-principal "User:$principal" \
        "${operation_args[@]}" \
        "--$resource_type" "$resource_name" \
        --resource-pattern-type "$pattern_type" \
        > /dev/null

done < <(read_conf "$ACLS_FILE")

log "ACL entries processed: $acl_count"

# ============================================================
# Result
# ============================================================

log "============================================================"
log "Current topics:"
"$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server "$BOOTSTRAP" \
    --command-config "$ADMIN_CONFIG" \
    --describe --exclude-internal \
| grep -E '^Topic:' \
| sed 's/^/[KAFKA-INIT]   /'

log "============================================================"
log "Kafka initialization completed successfully."
log "============================================================"
