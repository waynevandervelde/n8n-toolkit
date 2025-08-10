#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

#############################################################################################
# N8N Backup & Restore Script with Gmail SMTP Email Notifications via msmtp
# Author:      TheNguyen
# Email:       thenguyen.ai.automation@gmail.com
# Version:     1.2.0
# Date:        2025-08-10
#
# Description:
#   This script automates full backup and restore of an n8n Docker stack:
#     • Backs up Docker volumes (n8n-data, postgres-data, letsencrypt)
#     • Dumps the PostgreSQL database
#     • Archives .env and docker-compose.yml
#     • Detects changes to avoid redundant backups (unless --force)
#     • Optionally syncs backups to Google Drive via rclone
#     • Sends failure/success notifications over Gmail SMTP (msmtp)
#############################################################################################

# === Default Configuration ===
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
DAYS_TO_KEEP=7

DO_BACKUP=false
DO_RESTORE=false
DO_FORCE=false
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

################################################################################
# log(level, message...)
#   Print a log line if level >= LOG_LEVEL.
################################################################################
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

################################################################################
# load_env()
#   Source .env for DOMAIN and other variables, exiting if missing.
################################################################################
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

################################################################################
# send_email(subject, body[, attachment])
#   Send an email via Gmail SMTP using msmtp.
################################################################################
send_email() {
    local subject="$1" body="$2" attachment="${3:-}"
    if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$EMAIL_TO" ]]; then
        log WARN "SMTP_USER, SMTP_PASS or EMAIL_TO not set; cannot send email."
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

################################################################################
# handle_error()
#   Trap for any uncaught error: logs, sends failure email, and exits.
################################################################################
handle_error() {
  log ERROR "Backup/Restore encountered an error. See log: $LOG_FILE"
  send_email "n8n Backup/Restore Error at $DATE" \
             "An error occurred. See attached log." \
             "$LOG_FILE"
  exit 1
}

trap 'handle_error' ERR

################################################################################
# usage()
#   Print script usage/help and exit.
################################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  -b, --backup               Perform backup
  -f, --force                Force backup even if no changes detected
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

################################################################################
# initialize_snapshot()
#   On first run, mirror live volumes & config into snapshot/ for change checks.
################################################################################
initialize_snapshot() {
    if [[ ! -d "$BACKUP_DIR/snapshot" ]]; then
        log INFO "Bootstrapping snapshot (first run)…"
        for vol in "${VOLUMES[@]}"; do
            mkdir -p "$BACKUP_DIR/snapshot/volumes/$vol"
            rsync -a "/var/lib/docker/volumes/${vol}/_data/" \
                  "$BACKUP_DIR/snapshot/volumes/$vol/"
        done
        mkdir -p "$BACKUP_DIR/snapshot/config"
        rsync -a "$N8N_DIR/.env"              "$BACKUP_DIR/snapshot/config/"
        rsync -a "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
        log INFO "Snapshot bootstrapped."
    fi
}

################################################################################
# system_changed()
#   Returns 0 if any new/modified file exists compared to snapshot, or if forced.
################################################################################
# Returns 0 if any new or modified file is found (or forced), 1 otherwise
system_changed() {
    [[ "$DO_FORCE" == true ]] && return 0
    local changed=0

    for vol in "${VOLUMES[@]}"; do
        local src="/var/lib/docker/volumes/${vol}/_data/"
        local dest="$BACKUP_DIR/snapshot/volumes/${vol}/"
        mkdir -p "$dest"
        # dry-run: list items; filter out dirs (ending with '/')
        local diffs
        diffs=$(rsync -rtun --out-format="%n" "$src" "$dest" \
                | grep -v '/$') || true

        if [[ -n "$diffs" ]]; then
            log INFO "Change detected in volume: $vol"
            log DEBUG "Changed files:\n$diffs"
            changed=1
            break
        fi
    done

    if [[ $changed -eq 0 ]]; then
        local dest_cfg="$BACKUP_DIR/snapshot/config/"
        for file in .env docker-compose.yml; do
            local diffs
            diffs=$(rsync -rtun --out-format="%n" "$N8N_DIR/$file" "$dest_cfg" \
                    | grep -v '/$') || true
            if [[ -n "$diffs" ]]; then
                log INFO "Change detected in config: $file"
                log DEBUG "Changed config lines:\n$diffs"
                changed=1
                break
            fi
        done
    fi

    (( changed == 1 ))
}

################################################################################
# get_current_n8n_version()
#   Returns the version of n8n running in the Docker container.
################################################################################
get_current_n8n_version() {
    docker exec n8n n8n --version 2>/dev/null
}

################################################################################
# get_folder_id()
#   Extracts root_folder_id from rclone config for later Drive URL.
################################################################################
get_folder_id() {
  # Pull the 'root_folder_id' value from your remote's section in ~/.config/rclone/rclone.conf
  rclone config show "$RCLONE_REMOTE" \
    | grep ^root_folder_id \
    | sed -E 's/^root_folder_id *= *//'
}

################################################################################
# backup_n8n()
#   Main backup workflow: health check, dump volumes & DB, archive, sync, notify.
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
################################################################################
backup_n8n() {
    load_env
    # Detect changes
    if ! system_changed; then
        log INFO "No changes since last backup; skipping."
        return 0
    fi

	# Prepare backup	
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

	find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' -empty -exec rmdir {} \;
	log INFO "Removed any empty backup_<timestamp> folders"

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
		FOLDER_ID=$(get_folder_id)
  		if [[ -n "$FOLDER_ID" ]]; then
    		log INFO "Browse your backups here: https://drive.google.com/drive/folders/$FOLDER_ID"
  		else
    		log WARN "Could not determine Google Drive folder ID for remote '$RCLONE_REMOTE'."
  		fi
        log INFO "Pruning remote archives older than $DAYS_TO_KEEP days"
        rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
    fi

    # Success notification
    if [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
        send_email "n8n Backup Successful: $BACKUP_FILE" \
                   "Backup completed: $BACKUP_FILE"
    fi

	# Update snapshot
	log INFO "Updating snapshot to match this backup..."
    for vol in "${VOLUMES[@]}"; do
        rsync -a --delete "/var/lib/docker/volumes/${vol}/_data/" "$BACKUP_DIR/snapshot/volumes/${vol}/"
    done
    rsync -a --delete "$N8N_DIR/.env" "$BACKUP_DIR/snapshot/config/"
    rsync -a --delete "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
	log INFO "Snapshot updated."
}

################################################################################
# check_containers_healthy()
#   Polls defined containers until they’re all running & healthy (or times out).
################################################################################
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

################################################################################
# verify_traefik_certificate()
#   Verifies DNS, HTTPS, and SSL certificate health for the domain using curl and openssl
################################################################################
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

################################################################################
# check_services_up_running()
#   Combines container health and certificate checks to confirm stack is operational
################################################################################
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

################################################################################
# restore_n8n()
#   Restores Docker volumes, config, and database from a backup archive.
################################################################################
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

################################################################################
# require_cmd(cmd)
#   Exit with error if a required CLI is missing.
################################################################################
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing $1"; exit 1; }
}

# Ensure we have everything we need
require_cmd docker
require_cmd rsync
require_cmd tar
require_cmd msmtp
require_cmd rclone

# === Argument Parsing (long & short) ===
TEMP=$(getopt -o fbr:d:l:e:s:t:nh --long force,backup,restore:,dir:,log-level:,email:,remote-name:,remote-target:,notify-on-success,help -n "$0" -- "$@") || usage
eval set -- "$TEMP"

while true; do
    echo "Parsing argument: $1"
    case "$1" in
        -b|--backup)
            DO_BACKUP=true
            shift
            ;;
		-f|--force)
  			DO_FORCE=true
	 		shift
			;;
        -r|--restore)
            DO_RESTORE=true
            TARGET_RESTORE_FILE="$2"
            shift 2
            ;;
        -d|--dir)
            N8N_DIR="$2"
            shift 2
            ;;
        -l|--log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        -e|--email)
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

################################################################################
# Main Execution
################################################################################
# Initialize directories & logging
N8N_DIR="${N8N_DIR:-$PWD}"
BACKUP_DIR="$N8N_DIR/backups"
LOG_DIR="$N8N_DIR/logs"
log INFO "Working on directory: $N8N_DIR"
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$BACKUP_DIR/snapshot/volumes" "$BACKUP_DIR/snapshot/config"

# Load DOMAIN from .env (needed by initialize_snapshot)
load_env
initialize_snapshot

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
find "$BACKUP_DIR/snapshot/volumes" -type d -empty -delete
find "$BACKUP_DIR/snapshot/config" -type f -empty -delete
find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' -empty -delete
find "$LOG_DIR" -type f -mtime +$DAYS_TO_KEEP -delete
log INFO "Local cleanup logs completed."
