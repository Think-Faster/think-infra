#!/bin/bash

set -e

PROJECT_DIR="/opt/tf"
BACKUP_SCRIPT="$PROJECT_DIR/backup.sh"
CRON_COMMENT="# TF PostgreSQL backup"

CRON_LINE="0 7 * * * $BACKUP_SCRIPT >> $PROJECT_DIR/backup.log 2>&1"

case "$1" in
    start)
        (crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" || true
         echo "$CRON_COMMENT"
         echo "$CRON_LINE") | crontab -

        echo "Backup cron started"
        ;;

    stop)
        crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" | crontab - || true

        echo "Backup cron stopped"
        ;;

    status)
        if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
            echo "Backup cron is RUNNING"
            crontab -l | grep "$CRON_COMMENT" -A1
        else
            echo "Backup cron is STOPPED"
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac