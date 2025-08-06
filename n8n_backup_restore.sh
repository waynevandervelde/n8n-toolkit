#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

#############################################################################################
# N8N Backup & Restore Script (Enhanced)
# Author: TheNguyen
# Email: thenguyen.ai.automation@gmail.com
# Version: 1.0.0
# Date: 2025-08-06
#
# Description:
#   Provides backup and restore functionality for the n8n Docker stack.
#   Supports optional email alerts and cloud backup sync.
#############################################################################################

# === Default config ===
N8N_CONTAINERS=("n8n" "postgres" "traefik")
N8N_VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
N8N_DIR="/home/n8n"
DATE=$(date +%F_%H-%M-%S)
BACKUP_DIR="$N8N_DIR/backups"
LOG_DIR="$N8N_DIR/logs"
DAYS_TO_KEEP=7
DO_BACKUP=false
DO_RESTORE=false
TARGET_RESTORE_FILE=""
LOG_LEVEL="INFO"
SEND_EMAIL="false"
EMAIL_TO=""
RCLONE_REMOTE=""
RCLONE_TARGET=""

mkdir -p "$BACKUP_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$DATE.log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'handle_error' ERR

# Log function with log level filtering
log() {
    local level="$1"; shift
    local levels=("DEBUG" "INFO" "WARN" "ERROR")
    local show=1

    case "$LOG_LEVEL" in
        DEBUG) show=0 ;;
        INFO) [[ "$level" != "DEBUG" ]] && show=0 ;;
        WARN) [[ "$level" == "WARN" || "$level" == "ERROR" ]] && show=0 ;;
        ERROR) [[ "$level" == "ERROR" ]] && show=0 ;;
    esac

    if [[ $show -eq 0 ]]; then
        echo "[$level] $*"
    fi
}

# Handle errors and optionally send email alert
handle_error() {
    log ERROR "Backup/Restore failed."
    if [[ "$SEND_EMAIL" == "true" && -n "$EMAIL_TO" && -n "$MAILGUN_API_KEY" ]]; then
        curl -s --user "api:$MAILGUN_API_KEY" \
            https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages \
            -F from="$MAILGUN_FROM" \
            -F to="$EMAIL_TO" \
            -F subject="n8n Backup/Restore Failed" \
            -F text="Operation failed at $(date)"
    fi
    exit 1
}

# Print script usage/help message
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -b, --backup               Perform backup"
    echo "  -r, --restore <FILE>       Restore from specified backup file"
    echo "  -d, --dir <DIR>            Set custom n8n directory (default: /home/n8n)"
    echo "  -l, --log-level <LEVEL>    Set log level: DEBUG, INFO (default), WARN, ERROR"
    echo "  -e, --email <EMAIL>        Send notification email (requires API key)"
    echo "  -s, --remote-name <NAME>   Set rclone remote name (e.g. gdrive)"
    echo "  -t, --remote-target <PATH> Set rclone remote target path"
    echo "  -h, --help                 Show this help message"
    exit 0
}

# Restore from a given backup file
restore_n8n() {
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE"
        exit 1
    fi

    log INFO "Restoring from: $TARGET_RESTORE_FILE"
    TEMP_DIR="$N8N_DIR/tmp_restore_$DATE"
    mkdir -p "$TEMP_DIR"
    tar -xzf "$TARGET_RESTORE_FILE" -C "$TEMP_DIR"

    for archive in "$TEMP_DIR"/*.tar.gz; do
        NAME=$(basename "$archive" .tar.gz)
        DEST_PATH="/restore"
        docker run --rm -v "$TEMP_DIR:/restore" --volumes-from n8n alpine sh -c "tar xzf \"$DEST_PATH/$(basename "$archive")\" -C /"
        log INFO "Restored archive: $archive"
    done

    rm -rf "$TEMP_DIR"
    echo "===== RESTORE SUMMARY ====="
    echo "Restore File:     $TARGET_RESTORE_FILE"
    echo "Log File:         $LOG_FILE"
    echo "Timestamp:        $DATE"
    echo "============================"
}

# Perform backup of Docker volumes and Postgres
backup_n8n() {
    log INFO "Starting backup at $DATE..."
    for CONTAINER in "${N8N_CONTAINERS[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            log ERROR "Expected container '$CONTAINER' is not running."
            exit 1
        fi
    done

    for CONTAINER in "${N8N_CONTAINERS[@]}"; do
        log INFO "Inspecting container: $CONTAINER"
        MOUNTS=$(docker inspect "$CONTAINER" | jq -r '.[0].Mounts[] | "\(.Source)::\(.Destination)"')

        i=0
        while IFS= read -r line; do
            SRC=$(echo "$line" | cut -d'::' -f1)
            DST=$(echo "$line" | cut -d'::' -f2)
            SAFE_DST=$(echo "$DST" | tr '/:' '_')
            BACKUP_FILE="$BACKUP_DIR/${CONTAINER}_${i}_${SAFE_DST}_$DATE.tar.gz"

            if [[ "$SRC" == /var/lib/docker/volumes/* ]]; then
                docker run --rm --volumes-from "$CONTAINER" -v "$BACKUP_DIR:/backup" alpine \
                    tar czf "/backup/$(basename "$BACKUP_FILE")" "$DST"
            else
                tar czf "$BACKUP_FILE" -C "$SRC" .
            fi

            log INFO "Backed up: $BACKUP_FILE"
            ((i++))
        done <<< "$MOUNTS"

        if docker exec "$CONTAINER" sh -c "psql --version" &>/dev/null; then
            DB_BACKUP="$BACKUP_DIR/${CONTAINER}_db_$DATE.sql"
            docker exec "$CONTAINER" pg_dump -U n8n -d n8ndb > "$DB_BACKUP"
            log INFO "Postgres DB backup: $DB_BACKUP"
        fi
    done

    for VOL in "${N8N_VOLUMES[@]}"; do
        if docker volume inspect "$VOL" &>/dev/null; then
            VOL_BACKUP="$BACKUP_DIR/${VOL}_$DATE.tar.gz"
            docker run --rm -v "${VOL}:/data" -v "$BACKUP_DIR:/backup" alpine sh -c "tar czf /backup/$(basename "$VOL_BACKUP") -C /data ."
            log INFO "Volume backed up: $VOL_BACKUP"
        else
            log WARN "Volume $VOL not found. Skipping."
        fi
    done

    if command -v rclone &> /dev/null && [ -n "$RCLONE_REMOTE" ] && [ -n "$RCLONE_TARGET" ]; then
        log INFO "Syncing backup to cloud: $RCLONE_REMOTE/$RCLONE_TARGET"
        rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE:$RCLONE_TARGET" --create-dirs
        rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
        log INFO "Old cloud backups cleaned up."
    fi

    if [[ "$SEND_EMAIL" == "true" && -n "$EMAIL_TO" && -n "$MAILGUN_API_KEY" ]]; then
        curl -s --user "api:$MAILGUN_API_KEY" \
            https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages \
            -F from="$MAILGUN_FROM" \
            -F to="$EMAIL_TO" \
            -F subject="n8n Backup Successful" \
            -F text="Backup completed successfully at $(date)"
    fi

    log INFO "Backup completed successfully."
    echo "===== BACKUP SUMMARY ====="
    echo "Backup Directory: $BACKUP_DIR"
    echo "Log File:         $LOG_FILE"
    echo "Timestamp:        $DATE"
    echo "==========================="
}

# === Scheduled Backup Support ===
if [[ "$1" == "--cron" ]]; then
    log INFO "Running scheduled backup from cron..."
    DO_BACKUP=true
fi

# === Argument Parsing (long & short) ===
TEMP=$(getopt -o br:d:l:e:s:t:h --long backup,restore:,dir:,log-level:,email:,remote-name:,remote-target:,help -n "$0" -- "$@") || usage

eval set -- "$TEMP"

while true; do
    echo "Parsing argument: $1"
    case "$1" in
        -b|--backup)
            DO_BACKUP=true
            shift
            ;;
        -r|--restore)
            DO_RESTORE=true
            TARGET_RESTORE_FILE="$2"
            shift 2
            ;;
        -d|--dir)
            N8N_DIR="$2"
            BACKUP_DIR="$N8N_DIR/backups"
            LOG_DIR="$N8N_DIR/logs"
            mkdir -p "$BACKUP_DIR" "$LOG_DIR"
            LOG_FILE="$LOG_DIR/backup_$DATE.log"
            exec > >(tee -a "$LOG_FILE") 2>&1
            shift 2
            ;;
        -l|--log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        -e|--email)
            SEND_EMAIL=true
            EMAIL_TO="$2"
            shift 2
            ;;
        -s|--remote-name)
            RCLONE_REMOTE="$2"
            shift 2
            ;;
        -t|--remote-target)
            RCLONE_TARGET="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

# === Execution Logic ===
if [[ "$DO_BACKUP" == true ]]; then
    backup_n8n
elif [[ "$DO_RESTORE" == true ]]; then
    restore_n8n
else
    usage
fi
