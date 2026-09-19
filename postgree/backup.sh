#!/bin/bash

set -e

DATE=$(date +"%Y-%m-%d_%H-%M-%S")

docker exec tf-postgres \
    sh -c "pg_dump -U tf -d tf -Fc > /backups/tf_${DATE}.dump"

docker exec tf-postgres \
    sh -c "find /backups -type f -name '*.dump' -mtime +7 -delete"

echo "Backup created: tf_${DATE}.dump"