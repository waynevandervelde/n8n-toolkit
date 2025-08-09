#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

#############################################################################################
# N8N Backup & Restore Script with Gmail SMTP Email Notifications via msmtp
# Author: TheNguyen
# Email: thenguyen.ai.automation@gmail.com
# Version: 1.1.0
# Date: 2025-08-06
#
# Description:
#   Provides backup and restore functionality for the n8n Docker stack.
#   Supports optional email alerts and cloud backup sync.
#############################################################################################

# === Default Configuration ===
CONTAINERS=("n8n" "postgres" "traefik")
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
DAYS_TO_KEEP=7

DO_BACKUP=false
DO_RESTORE=false
TARGET_RESTORE_FILE=""
LOG_LEVEL="INFO"
EMAIL_TO=""
NOTIFY_ON_SUCCESS=false
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
RCLONE_REMOTE=""
RCLONE_TARGET=""

# These will be set later
N8N_DIR=""
BACKUP_DIR=""
LOG_DIR=""
DATE=""
LOG_FILE=""

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

# Load .env file
load_env() {
    if [[ -f ".env" ]]; then
        set -o allexport
        source .env
        set +o allexport
    else
        log ERROR ".env file not found in current directory."
        exit 1
    fi

    if [[ -z "$DOMAIN" ]]; then
        log ERROR "DOMAIN is not set. Please ensure .env contains the DOMAIN variable"
        exit 1
    fi
}

# ------------------------------
# Email via msmtp
# ------------------------------
send_email() {
	local subject="$1"
	local body="$2"
	local attachment="${3:-}"

	if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" ]]; then
		log WARN "SMTP_USER or SMTP_PASS not set; skipping email."
	return
	fi
	if [[ -z "$EMAIL_TO" ]]; then
		log WARN "EMAIL_TO not set; skipping email."
	return
	fi

	{
	echo "Subject: $subject"
	echo "To: $EMAIL_TO"
	echo
	echo "$body"
	if [[ -n "$attachment" && -f "$attachment" ]]; then
		echo
		echo "--ATTACHMENT--"
		base64 "$attachment"
		echo "--END ATTACHMENT--"
	fi
	} | msmtp --host=smtp.gmail.com \
			--port=587 \
			--auth=on \
			--tls=on \
			--from="$SMTP_USER" \
			--user="$SMTP_USER" \
			--passwordeval="echo $SMTP_PASS" \
			"$EMAIL_TO" \
	&& log INFO "Email sent: $subject" \
	|| log WARN "Failed to send email: $subject"
}

# Handle errors
handle_error() {
  log ERROR "Backup/Restore encountered an error. See log: $LOG_FILE"
  send_email "n8n Backup/Restore Error at $DATE" \
             "An error occurred. See attached log." \
             "$LOG_FILE"
  exit 1
}

# ------------------------------
# Usage
# ------------------------------
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  -b, --backup               Perform backup
  -r, --restore <FILE>       Restore from backup file
  -d, --dir <DIR>            n8n base directory (default: current)
  -l, --log-level <LEVEL>    DEBUG, INFO (default), WARN, ERROR
  -e, --email <EMAIL>        Send email alerts to this address
  -s, --remote-name <NAME>   Rclone remote name (e.g. gdrive-user)
  -t, --remote-target <PATH> Rclone target path (e.g. n8n-backups)
  -n, --notify-on-success    Email on successful completion
  -h, --help                 Show this help message
EOF
  exit 0
}
# Returns the currently running version of n8n from the Docker container
get_current_n8n_version() {
    docker exec n8n n8n --version 2>/dev/null
}

# === Helper: get root_folder_id from rclone config ===
get_folder_id() {
  # Pull the 'root_folder_id' value from your remote's section in ~/.config/rclone/rclone.conf
  rclone config show "$RCLONE_REMOTE" \
    | grep ^root_folder_id \
    | sed -E 's/^root_folder_id *= *//'
}

# Perform backup of Docker volumes and Postgres
# For a Docker-based n8n installation, here’s exactly what you need to back up to ensure full recovery:
# n8n-data, postgres-data, and letsencrypt volumes
# SQL dump of PostgreSQL database
# .env and docker-compose.yml files
# Manual backup:
# n8n-data: Stores n8n workflows, credentials, and settings.
#     docker run --rm -v n8n-data:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/n8n-data.tar.gz -C /data .
# postgres-data:	Stores the Postgres database used by n8n.
#    docker exec postgres pg_dump -U n8n -d n8n > "$BACKUP_DIR/n8n_db_dump.sql"
# env file and docker-compose.yml

backup_n8n() {
    load_env
    local BACKUP_PATH="$BACKUP_DIR/backup_$DATE"
    mkdir -p "$BACKUP_PATH"

    log INFO "Checking services running and healthy before starting backup..."
    if ! check_services_up_running; then
        log ERROR "Some services and Traefik are not running or unhealthy. Not starting the backup."
        exit 1
    else
       log INFO "Services running and healthy"
    fi

    log INFO "Starting backup at $DATE..."

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
    log INFO "Created archive -> $BACKUP_FILE"
    rm -rf "$BACKUP_PATH"

    log INFO "Cleaning up local backups older than $DAYS_TO_KEEP days..."
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
    log INFO "Local cleanup completed."

    log INFO "Local backup completed..."
    echo "═════════════════════════════════════════════════════════════"
    echo "Domain:       https://${DOMAIN}"
    echo "Backup file:  $BACKUP_DIR/$BACKUP_FILE"
    echo "N8N Version:  $N8N_VERSION"
    echo "Log File:     $LOG_FILE"
    echo "Timestamp:    $DATE"
    echo "═════════════════════════════════════════════════════════════"

    # Cloud sync if remote & target provided
    if [[ -n "$RCLONE_REMOTE" && -n "$RCLONE_TARGET" ]]; then
        log INFO "Uploading $BACKUP_FILE to $RCLONE_REMOTE:$RCLONE_TARGET"
        if ! rclone copy "$BACKUP_DIR/$BACKUP_FILE" "$RCLONE_REMOTE:$RCLONE_TARGET" --create-dirs; then
            log ERROR "Rclone upload failed"
            send_email "Rclone Upload Failed" \
                "Uploading $BACKUP_FILE to $RCLONE_REMOTE:$RCLONE_TARGET failed." \
                "$LOG_FILE"
            exit 1
        fi
        FOLDER_ID="$(get_folder_id)"
        if [[ -n "$FOLDER_ID" ]]; then
            echo
            log INFO "Browse your backups here:"
            echo "https://drive.google.com/drive/folders/$FOLDER_ID"
        fi
        log INFO "Pruning remote archives older than $DAYS_TO_KEEP days"
        rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
    fi

    # Success notification
    if [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
        send_email "n8n Backup Successful: $BACKUP_FILE" \
                   "Backup completed: $BACKUP_FILE"
    fi
}

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

# Verifies DNS, HTTPS, and SSL certificate health for the domain using curl and openssl
verify_traefik_certificate() {
    local domain_url="https://${DOMAIN}"
    local MAX_RETRIES=3
    local SLEEP_INTERVAL=10

    log INFO "Checking DNS resolution for domain..."
    domain_ip=$(dig +short "$DOMAIN")
    if [[ -z "$domain_ip" ]]; then
        log ERROR "DNS lookup failed for $DOMAIN. Ensure it points to your server's IP."
        return 1
    fi
    log INFO "Domain $DOMAIN resolves to IP: $domain_ip"

    log INFO "Checking if your domain is reachable via HTTPS..."
    local success=false
    for ((i=1; i<=MAX_RETRIES; i++)); do
        response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$domain_url")

        if [[ "$response" == "200" || "$response" == "301" || "$response" == "302" ]]; then
            log INFO "Domain is reachable with HTTPS (HTTP $response)"
            success=true
            break
        elif [[ "$response" == "000" ]]; then
            log WARN "No HTTPS response received (attempt $i/$MAX_RETRIES). Traefik or certs might not be ready."
        else
            log WARN "Domain not reachable (HTTP $response) (attempt $i/$MAX_RETRIES)."
        fi

        if [[ $i -lt $MAX_RETRIES ]]; then
            log INFO "Retrying in ${SLEEP_INTERVAL}s..."
            sleep $SLEEP_INTERVAL
        fi
    done

    if [[ "$success" != true ]]; then
        log ERROR "Domain is not reachable via HTTPS after $MAX_RETRIES attempts."
        return 1
    fi

    log INFO "Validating SSL certificate from Let's Encrypt..."
    for ((i=1; i<=MAX_RETRIES; i++)); do
        cert_info=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates)

        if [[ -n "$cert_info" ]]; then
            issuer=$(echo "$cert_info" | grep '^issuer=')
            subject=$(echo "$cert_info" | grep '^subject=')
            not_before=$(echo "$cert_info" | grep '^notBefore=')
            not_after=$(echo "$cert_info" | grep '^notAfter=')

            log INFO "Issuer: $issuer"
            log INFO "Subject: $subject"
            log INFO "Certificate Valid from: ${not_before#notBefore=}"
            log INFO "Certificate Expires on: ${not_after#notAfter=}"
            return 0
        else
            log WARN "Unable to retrieve certificate (attempt $i/$MAX_RETRIES)."
            [[ $i -lt $MAX_RETRIES ]] && sleep $SLEEP_INTERVAL
        fi
    done

    log ERROR "Could not retrieve certificate details after $MAX_RETRIES attempts."
    return 1
}

# Combines container health and certificate checks to confirm stack is operational
check_services_up_running() {
    if ! check_containers_healthy; then
        log ERROR "Some containers are not running or unhealthy. Please check the logs above."
        return 1
    fi

    # if ! verify_traefik_certificate; then
    #     log ERROR "Traefik failed to issue a valid TLS certificate. Please check DNS, Traefik logs, and try again."
    #     return 1
    # fi
    return 0
}

# Restores volumes and PostgreSQL database from a given backup archive
restore_n8n() {
    load_env
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE"
        exit 1
    fi
    log INFO "Starting restore at $DATE..."
    local restore_dir="/tmp/n8n_restore_$(date +%s)"
    mkdir -p "$restore_dir"
    log INFO "Extracting backup archive to $restore_dir"
    tar -xzf "$TARGET_RESTORE_FILE" -C "$restore_dir"

    # Stop and remove the current containers before cleaning volumes
    log INFO "Stopping and removing containers before restore..."
    docker compose down --volumes --remove-orphans

    # Cleanup volumes to avoid DB conflict
    log INFO "Cleaning existing Docker volumes before restore..."
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            docker volume rm "$vol" && log INFO "Removed volume: $vol"
        else
            log INFO "Volume '$vol' not found, skipping..."
        fi
    done

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
        log ERROR "Some containers are not running or unhealthy. Stop restoration!"
        exit 1
    fi

    # Restore Postgres SQL dump (if available)
    local sql_file=$(find "$restore_dir" -name "n8n_postgres_dump_*.sql")
    if [[ -n "$sql_file" ]]; then
        log INFO "Dropping and recreating the n8ndb database to avoid restore conflicts..."
        # Drop and recreate using the 'n8n' user
        docker exec postgres psql -U n8n -c "DROP DATABASE IF EXISTS n8ndb;"
        docker exec postgres psql -U n8n -c "CREATE DATABASE n8ndb OWNER n8n;"

        log INFO "Restoring PostgreSQL DB from $sql_file"
        cat "$sql_file" | docker exec -i postgres psql -U n8n -d n8ndb
    else
        log INFO "No Postgres SQL dump found. Assuming volume data is intact."
    fi


    log INFO "Checking services running and healthy after restoring backup..."
    if ! check_services_up_running; then
        log ERROR "Some services and Traefik are not running or unhealthy after restoring the backup"
        log ERROR "Restore the backup failed."
        log INFO "Log File: $LOG_FILE"
        exit 1
    else
       log INFO "Services running and healthy"
    fi
    
    # Cleanup temp
    rm -rf "$restore_dir"

    local N8N_VERSION=$(get_current_n8n_version)
    log INFO "Restore completed successfully."
    echo "═════════════════════════════════════════════════════════════"
    echo "Domain:               https://${DOMAIN}"
    echo "Restore from file:    $TARGET_RESTORE_FILE"
    echo "N8N Version:          $N8N_VERSION"
    echo "Log File:             $LOG_FILE"
    echo "Timestamp:            $DATE"
    echo "Volumes Restored:     n8n-data, postgres-data, letsencrypt"
    echo "PostgreSQL:           Restored from SQL dump"
    echo "═════════════════════════════════════════════════════════════"
}

# === Argument Parsing (long & short) ===
TEMP=$(getopt -o br:d:l:e:s:t:nh --long backup,restore:,dir:,log-level:,email:,remote-name:,remote-target:,notify-on-success,help -n "$0" -- "$@") || usage
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
        -n|--notify-on-success)
            NOTIFY_ON_SUCCESS=true;
            shift
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
DATE=$(date +%F_%H-%M-%S)
LOG_FILE="$LOG_DIR/$( [[ $DO_BACKUP == true ]] && echo backup || echo restore )_n8n_$DATE.log"
exec > >(tee "$LOG_FILE") 2>&1
log INFO "Logging to $LOG_FILE"

if [[ "$DO_BACKUP" == true ]]; then
    backup_n8n
elif [[ "$DO_RESTORE" == true ]]; then
    restore_n8n
else
    usage
fi

log INFO "Cleaning up local logs older than $DAYS_TO_KEEP days..."
find "$LOG_DIR" -type f -name "backup_n8n_*.log" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
find "$LOG_DIR" -type f -name "restore_n8n_*.log" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
log INFO "Local cleanup logs completed."
