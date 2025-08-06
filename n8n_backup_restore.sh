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

# === Default Configuration ===
CONTAINERS=("n8n" "postgres" "traefik")
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
DATE=$(date +%F_%H-%M-%S)
DAYS_TO_KEEP=7
DO_BACKUP=false
DO_RESTORE=false
TARGET_RESTORE_FILE=""
LOG_LEVEL="INFO"
SEND_EMAIL="false"
EMAIL_TO=""
RCLONE_REMOTE=""
RCLONE_TARGET=""

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

# Returns the currently running version of n8n from the Docker container
get_current_n8n_version() {
    docker exec n8n n8n --version 2>/dev/null
}

# Perform backup of Docker volumes and Postgres
# For a Docker-based n8n installation, here’s exactly what you need to back up to ensure full recovery:
# n8n-data, postgres-data, and letsencrypt volumes
# SQL dump of PostgreSQL database
# .env and docker-compose.yml files
# Manual backup:
# n8n-data: Stores n8n workflows, credentials, settings.
#     docker run --rm -v n8n-data:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/n8n-data.tar.gz -C /data .
# postgres-data:	Stores the Postgres database used by n8n.
#    docker exec postgres pg_dump -U n8n -d n8n > "$BACKUP_DIR/n8n_db_dump.sql"
# env file and docker-compose.yml

backup_n8n() {
    local DATE=$(date +%F_%H-%M-%S)
    local BACKUP_PATH="$BACKUP_DIR/backup_$DATE"
    mkdir -p "$BACKUP_PATH"
    log INFO "Starting backup at $DATE..."
    log INFO "Looking for containers..."
    for CONTAINER in "${CONTAINERS[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            log ERROR "Expected container '$CONTAINER' is not running."
            exit 1
        fi
        log INFO "Found container '$CONTAINER' is running."
    done

    local N8N_VERSION=$(get_current_n8n_version)

    log INFO "Backing up Docker volumes..."

    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            local vol_backup="$BACKUP_PATH/volume_${vol}_$DATE.tar.gz"
            docker run --rm -v "${vol}:/data" -v "$BACKUP_PATH:/backup" alpine \
                sh -c "tar czf /backup/$(basename "$vol_backup") -C /data ."
            log INFO "Volume '$vol' backed up: $vol_backup"
        else
            log ERROR "Volume $vol not found. Exiting..."
            exit 1
        fi
    done

    log INFO "Dumping PostgreSQL database..."

    if docker exec postgres sh -c "pg_isready" >/dev/null 2>&1; then
        docker exec postgres pg_dump -U n8n -d n8n > "$BACKUP_PATH/n8n_postgres_dump_$DATE.sql"
        log INFO "Database dump saved to $BACKUP_PATH/n8n_postgres_dump_$DATE.sql"
    else
        log ERROR "PostgreSQL is not responding. Exiting..."
        exit 1
    fi

    log INFO "Backing up .env and docker-compose.yml..."
    cp "$N8N_DIR/.env" "$BACKUP_PATH/.env.bak"
    cp "$N8N_DIR/docker-compose.yml" "$BACKUP_PATH/docker-compose.yml.bak"

    log INFO "Compressing backup folder..."
    local BACKUP_FILE="n8n_backup_${N8N_VERSION}_${DATE}.tar.gz"
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$BACKUP_PATH" .
    rm -rf "$BACKUP_PATH"

    log INFO "Cleaning up local backups older than $DAYS_TO_KEEP days..."
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
    log INFO "Local cleanup completed."

    log INFO "Local backup completed..."
    echo "═════════════════════════════════════════════════════════════"
    echo "Backup file:  $BACKUP_DIR/$BACKUP_FILE"
    echo "N8N Version:  $N8N_VERSION"
    echo "Log File:     $LOG_FILE"
    echo "Timestamp:    $DATE"
    echo "═════════════════════════════════════════════════════════════"

    if command -v rclone &> /dev/null && [ -n "$RCLONE_REMOTE" ] && [ -n "$RCLONE_TARGET" ]; then
        log INFO "Syncing backup to cloud: $RCLONE_REMOTE/$RCLONE_TARGET"
        rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE:$RCLONE_TARGET" --create-dirs
        rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
        log INFO "Old cloud backups cleaned up."
    fi
}

# backup_n8n() {
#     log INFO "Starting backup at $DATE..."
#     log INFO "Looking for containers..."
#     for CONTAINER in "${CONTAINERS[@]}"; do
#         if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
#             log ERROR "Expected container '$CONTAINER' is not running."
#             exit 1
#         fi
#         log INFO "Found container '$CONTAINER' is running."
#     done
    
#     log INFO "Starting backup Volumes..."
#     for VOL in "${VOLUMES[@]}"; do
#         if docker volume inspect "$VOL" >/dev/null 2>&1; then
#             BACKUP_FILE="$BACKUP_DIR/${VOL}_$DATE.tar.gz"
#             docker run --rm -v "${VOL}:/data" -v "$BACKUP_DIR:/backup" alpine \
#                 sh -c "tar czf /backup/$(basename "$BACKUP_FILE") -C /data ."
#             log INFO "Volume backed up: $BACKUP_FILE"
#         else
#             log ERROR "Volume $VOL not found. Exiting..."
#             exit 1
#         fi
#     done


#     for CONTAINER in "${CONTAINERS[@]}"; do
#         log INFO "Inspecting container: $CONTAINER"
#         MOUNTS=$(docker inspect "$CONTAINER" | jq -r '.[0].Mounts[] | "\(.Source)::\(.Destination)"')

#         i=0
#         while IFS= read -r line; do
#             IFS='::' read -r SRC DST <<< "$line"
#             SAFE_DST=$(echo "$DST" | tr '/:' '_')
#             BACKUP_FILE="$BACKUP_DIR/${CONTAINER}_${i}_${SAFE_DST}_$DATE.tar.gz"

#             if [[ "$SRC" == /var/lib/docker/volumes/* ]]; then
#                 docker run --rm --volumes-from "$CONTAINER" -v "$BACKUP_DIR:/backup" alpine \
#                     tar czf "/backup/$(basename "$BACKUP_FILE")" "$DST"
#             else
#                 tar czf "$BACKUP_FILE" -C "$SRC" .
#             fi

#             log INFO "Backed up: $BACKUP_FILE"
#             ((i++))
#         done <<< "$MOUNTS"

#         if docker exec "$CONTAINER" sh -c "psql --version" &>/dev/null; then
#             DB_BACKUP="$BACKUP_DIR/${CONTAINER}_db_$DATE.sql"
#             docker exec "$CONTAINER" pg_dump -U n8n -d n8ndb > "$DB_BACKUP"
#             log INFO "Postgres DB backup: $DB_BACKUP"
#         fi
#     done

#     for VOL in "${VOLUMES[@]}"; do
#         if docker volume inspect "$VOL" &>/dev/null; then
#             VOL_BACKUP="$BACKUP_DIR/${VOL}_$DATE.tar.gz"
#             docker run --rm -v "${VOL}:/data" -v "$BACKUP_DIR:/backup" alpine sh -c "tar czf /backup/$(basename "$VOL_BACKUP") -C /data ."
#             log INFO "Volume backed up: $VOL_BACKUP"
#         else
#             log WARN "Volume $VOL not found. Skipping."
#         fi
#     done

#     if command -v rclone &> /dev/null && [ -n "$RCLONE_REMOTE" ] && [ -n "$RCLONE_TARGET" ]; then
#         log INFO "Syncing backup to cloud: $RCLONE_REMOTE/$RCLONE_TARGET"
#         rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE:$RCLONE_TARGET" --create-dirs
#         rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
#         log INFO "Old cloud backups cleaned up."
#     fi

#     log INFO "Cleaning up local backups older than $DAYS_TO_KEEP days..."
#     find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
#     log INFO "Local cleanup complete."

#     if [[ "$SEND_EMAIL" == "true" && -n "$EMAIL_TO" && -n "$MAILGUN_API_KEY" ]]; then
#         curl -s --user "api:$MAILGUN_API_KEY" \
#             https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages \
#             -F from="$MAILGUN_FROM" \
#             -F to="$EMAIL_TO" \
#             -F subject="n8n Backup Successful" \
#             -F text="Backup completed successfully at $(date)"
#     fi

#     log INFO "Backup completed successfully."
#     echo "===== BACKUP SUMMARY ====="
#     echo "Backup Directory: $BACKUP_DIR"
#     echo "Log File:         $LOG_FILE"
#     echo "Timestamp:        $DATE"
#     echo "==========================="
# }

# Waits for all containers to reach a healthy state within a timeout window
check_containers_healthy() {
    timeout=180
    interval=10
    elapsed=0

    log INFO "Checking container status..."

    while [ $elapsed -lt $timeout ]; do
        log INFO "Status check at $(date +"%H:%M:%S")..."
        all_ok=true
        docker compose ps
        containers=$(docker ps -q)

        for container_id in $containers; do
            name=$(docker inspect --format='{{.Name}}' "$container_id" | sed 's/^\/\(.*\)/\1/')
            status=$(docker inspect --format='{{.State.Status}}' "$container_id")
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")

            if [[ "$status" != "running" ]]; then
                log WARN "$name is not running (status: $status)"
                all_ok=false
            elif [[ "$health" != "none" && "$health" != "healthy" ]]; then
                log WARN "$name is running but not healthy (health: $health)"
                all_ok=false
            else
                log INFO "$name is running and ${health:-no-health-check}"
            fi
        done

        if $all_ok; then
            log INFO "All containers are running and healthy."
            return 0
        fi

        log INFO "Waiting ${interval}s for next check"
        for ((i = 0; i < interval; i++)); do
            echo -n "."
            sleep 1
        done
        echo ""
        elapsed=$((elapsed + interval))
    done

    log ERROR "Timeout after $timeout seconds. Some containers are not healthy."
    return 1
}

restore_n8n() {
    local DATE=$(date +%F_%H-%M-%S)
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE"
        exit 1
    fi

    local restore_dir="/tmp/n8n_restore_$(date +%s)"
    mkdir -p "$restore_dir"
    log INFO "Extracting backup archive to $restore_dir"
    tar -xzf "$TARGET_RESTORE_FILE" -C "$restore_dir"

    # Restore Docker volumes
    for vol in n8n-data postgres-data letsencrypt; do
        local vol_file=$(find "$restore_dir" -name "*${vol}_*.tar.gz")
        if [[ -n "$vol_file" ]]; then
            log INFO "Restoring volume: $vol from $vol_file"
            docker volume create "$vol" >/dev/null 2>&1 || true
            docker run --rm -v "${vol}:/data" -v "${restore_dir}:/backup" alpine \
                sh -c "rm -rf /data/* && tar xzf /backup/$(basename "$vol_file") -C /data"
        else
            log ERROR "Volume backup for $vol not found. Exiting..."
            exit 1
        fi
    done

    # Restore .env and docker-compose.yml if present
    if [[ -f "$restore_dir/.env.bak" ]]; then
        cp "$restore_dir/.env.bak" "$N8N_DIR/.env"
        log INFO "Restored .env file to $N8N_DIR/.env"
    fi

    if [[ -f "$restore_dir/docker-compose.yml.bak" ]]; then
        cp "$restore_dir/docker-compose.yml.bak" "$N8N_DIR/docker-compose.yml"
        log INFO "Restored docker-compose.yml to $N8N_DIR/docker-compose.yml"
    fi

    # Restart services
    log INFO "Starting Docker Compose..."
    cd "$N8N_DIR" || { log ERROR "Failed to change directory to $N8N_DIR"; exit 1; }
    docker compose up -d

    if ! check_containers_healthy; then
        log ERROR "Some containers are not running or unhealthy. Restore failed!"
        exit 1
    fi

    # Restore Postgres SQL dump (if available)
    local sql_file=$(find "$restore_dir" -name "n8n_postgres_dump_*.sql")
    if [[ -n "$sql_file" ]]; then
        log INFO "Restoring PostgreSQL DB from $sql_file"
        cat "$sql_file" | docker exec -i postgres psql -U n8n -d n8n
    else
        log INFO "No Postgres SQL dump found. Assuming volume data is intact."
    fi

    # Cleanup temp
    rm -rf "$restore_dir"

    local N8N_VERSION=$(get_current_n8n_version)
    log INFO "Restore completed successfully."
    echo "═════════════════════════════════════════════════════════════"
    echo "Restore from file:    $TARGET_RESTORE_FILE"
    echo "N8N Version:          $N8N_VERSION"
    echo "Log File:             $LOG_FILE"
    echo "Timestamp:            $DATE"
    echo "═════════════════════════════════════════════════════════════"
}

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
            TARGET_DIR="$2"
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
N8N_DIR="${TARGET_DIR:-$PWD}"
BACKUP_DIR="$N8N_DIR/backups"
LOG_DIR="$N8N_DIR/logs"

log INFO "Working on directory: $N8N_DIR"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
if [[ "$DO_BACKUP" == true ]]; then
    LOG_FILE="$LOG_DIR/backup_n8n.log"
elif [[ "$DO_RESTORE" == true ]]; then
    LOG_FILE="$LOG_DIR/restore_n8n.log"
fi

exec > >(tee "$LOG_FILE") 2>&1
log INFO "Logging to $LOG_FILE"

if [[ "$DO_BACKUP" == true ]]; then
    backup_n8n
elif [[ "$DO_RESTORE" == true ]]; then
    restore_n8n
else
    usage
fi
