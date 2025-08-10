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
#     • Rolling 30-day Markdown summary (`backup_summary.md`)
#     • Optionally syncs backups to Google Drive via rclone
#     • Prints a console summary
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
N8N_VERSION=""
BACKUP_DIR=""
LOG_DIR=""
DATE=""
LOG_FILE=""
ACTION=""
BACKUP_STATUS=""
UPLOAD_STATUS=""
BACKUP_FILE=""
DRIVE_LINK=""

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
    [[ -f .env ]] || { log ERROR ".env not found."; exit 1; }
    set -o allexport; source .env; set +o allexport
    [[ -n "${DOMAIN:-}" ]] || { log ERROR "DOMAIN not set in .env"; exit 1; }
}

################################################################################
# send_email(subject, body[, attachment])
#   Send an email via Gmail SMTP using msmtp.
################################################################################
send_email() {
  local subject="$1"
  local body="$2"
  local attachment="${3:-}"

  # Bail if any required creds/recipients are missing
  if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$EMAIL_TO" ]]; then
    log WARN "SMTP_USER, SMTP_PASS, or EMAIL_TO not set; cannot send email."
    return 1
  fi

  # Generate a random boundary
  local boundary="=====n8n_backup_$(date +%s)_$$====="
  {
    # Standard headers
    echo "From: $SMTP_USER"
    echo "To: $EMAIL_TO"
    echo "Subject: $subject"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 7bit"
    echo
    echo "$body"
    echo

    # If we have an attachment, embed it properly
    if [[ -n "$attachment" && -f "$attachment" ]]; then
      local filename
      filename=$(basename "$attachment")
      echo "--$boundary"
      echo "Content-Type: application/octet-stream; name=\"$filename\""
      echo "Content-Transfer-Encoding: base64"
      echo "Content-Disposition: attachment; filename=\"$filename\""
      echo
      base64 "$attachment"
      echo
    fi

    # End of multipart
    echo "--$boundary--"
  } | msmtp \
      --host=smtp.gmail.com \
      --port=587 \
      --auth=on \
      --tls=on \
      --from="$SMTP_USER" \
      --user="$SMTP_USER" \
      --passwordeval="echo $SMTP_PASS" \
      "$EMAIL_TO"

  if [[ $? -eq 0 ]]; then
    log INFO "Email sent: $subject"
  else
    log WARN "Failed to send email: $subject"
  fi
}

################################################################################
# handle_error()
#   Trap for any uncaught error: logs, sends failure email, and exits.
################################################################################
handle_error() {
    write_summary "Error" "FAIL"
    log ERROR "Unhandled error. See $LOG_FILE"
    send_email "$DATE: n8n Backup FAILED locally" \
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
  exit 1
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
        rsync -a "$N8N_DIR/.env" "$BACKUP_DIR/snapshot/config/"
        rsync -a "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
        log INFO "Snapshot bootstrapped."
    fi
}

################################################################################
# refresh_snapshot()
#   After a successful backup, mirror live volumes & config into snapshot/
################################################################################
refresh_snapshot() {
  log INFO "Updating snapshot to current state…"
  for vol in "${VOLUMES[@]}"; do
    rsync -a --delete \
      --exclude='pg_wal/**' \
      --exclude='pg_stat_tmp/**' \
      --exclude='pg_logical/**' \
      "/var/lib/docker/volumes/${vol}/_data/" \
      "$BACKUP_DIR/snapshot/volumes/$vol/"
  done
  rsync -a --delete "$N8N_DIR/.env" "$BACKUP_DIR/snapshot/config/"
  rsync -a --delete "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
  log INFO "Snapshot refreshed."
}

################################################################################
# is_system_changed()
#   Compares live volumes & config against the snapshot.
#   Excludes pg_wal, pg_stat_tmp, pg_logical dirs (to avoid false positives).
#   Returns 0 if any file has been added/modified (i.e. system changed),
#   Returns 1 otherwise.
################################################################################
is_system_changed() {
    local src dest diffs file

    # Check each named volume
    for vol in "${VOLUMES[@]}"; do
        src="/var/lib/docker/volumes/${vol}/_data/"
        dest="$BACKUP_DIR/snapshot/volumes/${vol}/"
        mkdir -p "$dest"

        # rsync dry-run listing (omit directory entries)
		diffs=$(
		  rsync -rtun \
		    --exclude='pg_wal/**' \
		    --exclude='pg_stat_tmp/**' \
		    --exclude='pg_logical/**' \
		    --out-format="%n" \
		    "$src" "$dest" \
		  | grep -v '/$'
		) || true

        if [[ -n "$diffs" ]]; then
            log INFO "Change detected in volume: $vol"
            log DEBUG "  $diffs"
            return 0
        fi
    done

    # Check config files
    dest="$BACKUP_DIR/snapshot/config/"
    for file in .env docker-compose.yml; do
        diffs=$(rsync -rtun --out-format="%n" "$N8N_DIR/$file" "$dest" | grep -v '/$') || true
        if [[ -n "$diffs" ]]; then
            log INFO "Change detected in config: $file"
            log DEBUG "  $diffs"
            return 0
        fi
    done

    # No differences found
    return 1
}

################################################################################
# get_current_n8n_version()
#   Returns the version of n8n running in the Docker container.
################################################################################
get_current_n8n_version() {
    docker exec n8n n8n --version 2>/dev/null
}

################################################################################
# get_google_drive_link()
#   If RCLONE_REMOTE and RCLONE_TARGET are set, reads root_folder_id
#   from rclone.conf and echoes the Drive folder URL.
#   Otherwise echoes an empty string.
################################################################################
get_google_drive_link() {
    # If no remote or no target, output nothing
    if [[ -z "$RCLONE_REMOTE" || -z "$RCLONE_TARGET" ]]; then
        echo ""
        return
    fi

    # Read the root_folder_id from rclone config
    local folder_id
    folder_id=$(rclone config show "$RCLONE_REMOTE" 2>/dev/null \
                | awk -F '=' '/^root_folder_id/ { gsub(/ /,"",$2); print $2 }')

    if [[ -n "$folder_id" ]]; then
        echo "https://drive.google.com/drive/folders/$folder_id"
    else
        log WARN "Could not find root_folder_id for remote '$RCLONE_REMOTE'"
        echo ""
    fi
}

################################################################################
# write_summary(action, status)
#   Appends a row to backup_summary.md and prunes entries older than 30 days.
################################################################################
write_summary() {
    local action="$1" status="$2"
	local version="$N8N_VERSION"
    local file="$BACKUP_DIR/backup_summary.md"
    local now; now="$DATE"
    local cutoff; cutoff=$(date -d '30 days ago' '+%F')

    # If the file doesn't exist, write the markdown table header
    if [[ ! -f "$file" ]]; then
        cat >> "$file" <<'EOF'
| DATE               | ACTION         | N8N_VERSION | STATUS   |
|--------------------|----------------|-------------|----------|
EOF
    fi

    # Append a new row
    printf "| %s | %s | %s | %s |\n" "$now" "$action" "$version" "$status" >> "$file"

    # Prune rows older than 30 days (match YYYY-MM-DD at start of each row)
    # We'll keep the header plus any rows whose DATE ≥ cutoff
    {
      # print header
      head -n2 "$file"
      # filter data rows
      tail -n +3 "$file" \
        | awk -v cut="$cutoff" -F'[| ]+' '$2 >= cut'
    } > "${file}.tmp" && mv "${file}.tmp" "$file"
}

################################################################################
# do_local_backup()
#   Performs the “local backup” step: volumes → tar.gz,
#   DB dump, config files, final archive.  On success sets
#   $BACKUP_FILE and returns 0; on any error returns 1.
################################################################################
do_local_backup() {
    # Temporarily disable errexit so we can catch errors
    set +e

    local BACKUP_PATH="$BACKUP_DIR/backup_$DATE"
    mkdir -p "$BACKUP_PATH" || { log ERROR "Failed to create $BACKUP_PATH"; return 1; }

 	log INFO "Checking services running and healthy before starting backup..."
    if ! check_services_up_running; then
		log ERROR "Services unhealthy; aborting backup."
   		return 1
   	else
       log INFO "Services running and healthy"
    fi

    log INFO "Starting backup at $DATE..."
	log INFO "Backing up Docker volumes..."
    for vol in "${VOLUMES[@]}"; do
        if ! docker volume inspect "$vol" &>/dev/null; then
            log ERROR "Volume $vol not found"
            return 1
        fi
        local vol_backup="volume_${vol}_$DATE.tar.gz"
        docker run --rm \
            -v "${vol}:/data" \
            -v "$BACKUP_PATH:/backup" \
            alpine \
            sh -c "tar czf /backup/$vol_backup -C /data ." \
        || { log ERROR "Failed to archive volume $vol"; return 1; }
        log INFO "Volume '$vol' backed up: $vol_backup"
    done

	log INFO "Dumping PostgreSQL database..."
    if docker exec postgres sh -c "pg_isready" &>/dev/null; then
        docker exec postgres \
            pg_dump -U n8n -d n8n \
        > "$BACKUP_PATH/n8n_postgres_dump_$DATE.sql" \
        || { log ERROR "Postgres dump failed"; return 1; }
        log INFO "Database dump saved to $BACKUP_PATH/n8n_postgres_dump_$DATE.sql"
    else
        log ERROR "Postgres not ready"; return 1
    fi

	log INFO "Backing up .env and docker-compose.yml..."
    cp "$N8N_DIR/.env" "$BACKUP_PATH/.env.bak"
    cp "$N8N_DIR/docker-compose.yml" "$BACKUP_PATH/docker-compose.yml.bak"

    log INFO "Compressing backup folder..."
    BACKUP_FILE="n8n_backup_${N8N_VERSION}_${DATE}.tar.gz"
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$BACKUP_PATH" .
    log INFO "Created archive -> $BACKUP_FILE"

	log INFO "Cleaning up local backups older than $DAYS_TO_KEEP days..."
 	rm -rf "$BACKUP_PATH"
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
	find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' -empty -exec rmdir {} \;
	log INFO "Removed any empty backup_<timestamp> folders"
    set -e
    return 0
}

################################################################################
# upload_backup_rclone()
#   Upload $BACKUP_FILE (and summary) to the rclone remote.
#   Sets UPLOAD_STATUS="SUCCESS", "FAIL" or "SKIPPED".
#   Returns 0 if SKIPPED or SUCCESS, 1 if FAIL.
################################################################################
upload_backup_rclone() {
    # nothing to do if no remote configured
    if [[ -z "$RCLONE_REMOTE" || -z "$RCLONE_TARGET" ]]; then
        UPLOAD_STATUS="SKIPPED"
        log INFO "Rclone remote or target not set; skipping upload."
        return 0
    fi

    log INFO "Uploading $BACKUP_FILE to $RCLONE_REMOTE:$RCLONE_TARGET"
    if \
         rclone copy "$BACKUP_DIR/$BACKUP_FILE" "$RCLONE_REMOTE:$RCLONE_TARGET" && \
         rclone copy "$BACKUP_DIR/backup_summary.md" "$RCLONE_REMOTE:$RCLONE_TARGET"
    then
        UPLOAD_STATUS="SUCCESS"
        log INFO "Uploaded both $BACKUP_FILE and backup_summary.md successfully!"
        ret=0
    else
        UPLOAD_STATUS="FAIL"
        log ERROR "One or more uploads failed"
        ret=1
    fi

    log INFO "Pruning remote archives older than $DAYS_TO_KEEP days"
    rclone delete --min-age "${DAYS_TO_KEEP}d" "$RCLONE_REMOTE:$RCLONE_TARGET" || \
        log WARN "Failed to prune remote archives"

    return $ret
}

################################################################################
# send_mail_on_action()
#   Sends a final notification email based on backup & upload results.
#   Requires globals:
#     BACKUP_STATUS     ("SUCCESS" / "FAIL" / "SKIPPED")
#     UPLOAD_STATUS     ("SUCCESS" / "FAIL" / "SKIPPED")
#     NOTIFY_ON_SUCCESS (boolean)
################################################################################
send_mail_on_action() {
    local subject body

    # 1) Determine subject/body based on statuses:
    if [[ "$BACKUP_STATUS" == "FAIL" ]]; then
        subject="$DATE: n8n Backup FAILED locally"
        body="An error occurred during the local backup step. See attached log.

Log File: $LOG_FILE"

    elif [[ "$BACKUP_STATUS" == "SKIPPED" ]]; then
        subject="$DATE: n8n Backup SKIPPED: no changes"
        body="No changes detected since the last backup; nothing to do."

    elif [[ "$BACKUP_STATUS" == "SUCCESS" && "$UPLOAD_STATUS" == "FAIL" ]]; then
        subject="$DATE: n8n Backup Succeeded; upload FAILED"
        body="Local backup succeeded as:

  File: $BACKUP_FILE

But the upload to $RCLONE_REMOTE:$RCLONE_TARGET failed.
See log for details:

Log File: $LOG_FILE"

    elif [[ "$BACKUP_STATUS" == "SUCCESS" && "$UPLOAD_STATUS" == "SUCCESS" ]]; then
        subject="$DATE: n8n Backup SUCCESS"
        body="Backup and upload completed successfully.

  File: $BACKUP_FILE
  Remote: $RCLONE_REMOTE:$RCLONE_TARGET
  Drive Link: ${DRIVE_LINK:-N/A}"

    else
        subject="$DATE: n8n Backup status unknown"
        body="Backup reported an unexpected status:
  BACKUP_STATUS=$BACKUP_STATUS
  UPLOAD_STATUS=$UPLOAD_STATUS
See log at $LOG_FILE"
    fi

    # 2) Decide whether to send email:
    #
    # - On any failure (backup or upload), always send (with log attachment).
    # - On success, only send if the user passed --notify-on-success.
    #
    if [[ "$BACKUP_STATUS" == "FAIL" ]] || [[ "$UPLOAD_STATUS" == "FAIL" ]]; then
        # failures: attach the log
        send_email "$subject" "$body" "$LOG_FILE"

    elif [[ "$BACKUP_STATUS" == "SKIPPED" ]]; then
        # skipped: only notify if explicitly requested
        if [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
            send_email "$subject" "$body"
        fi

    else
        # success & upload success: only if notify-on-success
        if [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
            # send_email "$subject" "$body"
			send_email "$subject" "$body" "$LOG_FILE"
        fi
    fi
}

################################################################################
# print_summary()
#   Print a human-readable summary of what just happened.
################################################################################
print_summary() {
	local summary_file="$BACKUP_DIR/backup_summary.md"
    local email_note
	log INFO "Print a summary of what happened..."

    # Determine whether an email was sent
    if [[ "$BACKUP_STATUS" == "FAIL" ]] || [[ "$UPLOAD_STATUS" == "FAIL" ]] || [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
        email_note="Yes"
    else
        email_note="No"
    fi

    echo "═════════════════════════════════════════════════════════════"
    printf "Action:               %s\n"   "$ACTION"
    printf "Timestamp:            %s\n"   "$DATE"
    printf "Domain:               https://%s\n" "$DOMAIN"
    [[ -n "$BACKUP_FILE" ]] && printf "Backup file:          %s/%s\n" "$BACKUP_DIR" "$BACKUP_FILE"
    printf "N8N Version:          %s\n"   "$N8N_VERSION"
    printf "Log File:             %s\n"   "$LOG_FILE"
    printf "Daily tracking:       %s\n"   "$summary_file"

    case "$UPLOAD_STATUS" in
        "SUCCESS")
            printf "Uploaded to Google:   SUCCESS\n"
            printf "Folder link:          %s\n" "$DRIVE_LINK"
            ;;
        "SKIPPED")
            printf "Uploaded to Google:   SKIPPED\n"
            ;;
        *)
            printf "Uploaded to Google:   FAILED\n"
            ;;
    esac

    printf "Email notify sent:    %s\n" "$email_note"
    echo "═════════════════════════════════════════════════════════════"
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
    N8N_VERSION=$(get_current_n8n_version)
	BACKUP_STATUS=""
	UPLOAD_STATUS=""
	BACKUP_FILE=""
	DRIVE_LINK=""

	# Decide action type
	if is_system_changed; then
 		ACTION="Backup (normal)"
	elif [[ "$DO_FORCE" == true ]]; then
        ACTION="Backup (forced)"
    else
        ACTION="Skipped"
        BACKUP_STATUS="SKIPPED"
        UPLOAD_STATUS="SKIPPED"
        log INFO "No changes detected; skipping backup."
        write_summary "$ACTION" "$BACKUP_STATUS"
        send_mail_on_action
        print_summary
        return 0
    fi

    # Local backup
    if do_local_backup; then
        BACKUP_STATUS="SUCCESS"
        log INFO "Local backup succeeded: $BACKUP_FILE"
		# Refresh our snapshot so next run sees “no changes”
    	refresh_snapshot
    else
        BACKUP_STATUS="FAIL"
        log ERROR "Local backup failed."
        UPLOAD_STATUS="SKIPPED"
        write_summary "$ACTION" "$BACKUP_STATUS"
        send_mail_on_action
        print_summary
        return 1
    fi

    # Record in rolling summary
    write_summary "$ACTION" "$BACKUP_STATUS"

	# Remote upload
    upload_backup_rclone

	# cache the Google Drive link exactly once
	DRIVE_LINK=$(get_google_drive_link)

    # Final email notification
    send_mail_on_action

    # Console summary
    print_summary
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
        log INFO "Status check at $(date +%T)..."
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
#   Restores Docker volumes, config, and DB from a backup archive.
#   Returns 0 on success, non-zero on failure.
################################################################################
restore_n8n() {
    load_env
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE"
        return 1
    fi
    log INFO "Starting restore at $DATE..."
    local restore_dir="/tmp/n8n_restore_$(date +%s)"
	mkdir -p "$restore_dir" || { log ERROR "Cannot create $restore_dir"; return 1; }
 
    log INFO "Extracting backup archive to $restore_dir"
	tar -xzf "$TARGET_RESTORE_FILE" -C "$restore_dir" \
      || { log ERROR "Failed to extract $TARGET_RESTORE_FILE"; return 1; }

    # Stop and remove the current containers before cleaning volumes
    log INFO "Stopping and removing containers before restore..."
	docker compose down --volumes --remove-orphans \
      || { log ERROR "docker-compose down failed"; return 1; }

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
	log INFO "Restoring volumes from archive..."
    for vol in n8n-data postgres-data letsencrypt; do
        local vol_file=$(find "$restore_dir" -name "*${vol}_*.tar.gz")
        if [[ -z "$vol_file" ]]; then
            log ERROR "No backup found for volume $vol"
            return 1
        fi

  		docker volume create "$vol" &>/dev/null
        docker run --rm -v "${vol}:/data" -v "$restore_dir:/backup" alpine \
            sh -c "rm -rf /data/* && tar xzf /backup/$(basename "$vol_file") -C /data" \
          || { log ERROR "Failed to restore $vol"; return 1; }
        log INFO "Volume $vol restored"
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
	docker compose up -d || { log ERROR "docker-compose up failed"; return 1; }

    if ! check_containers_healthy; then
        log ERROR "Some containers are not running or unhealthy. Stop restoration!"
        return 1
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

    N8N_VERSION=$(get_current_n8n_version)
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
#   Bail out early with an error if the given command is not installed.
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
mode="restore"
[[ "$DO_BACKUP" == "true" ]] && mode="backup"
LOG_FILE="$LOG_DIR/${mode}_n8n_$DATE.log"

exec > >(tee "$LOG_FILE") 2>&1
log INFO "Logging to $LOG_FILE"

if [[ "$DO_BACKUP" == "true" ]]; then
    backup_n8n || exit 1
elif [[ "$DO_RESTORE" == "true" ]]; then
    restore_n8n || exit 1
else
    usage
fi

log INFO "Cleaning up local logs older than $DAYS_TO_KEEP days..."
find "$BACKUP_DIR/snapshot/volumes" -type d -empty -delete
find "$BACKUP_DIR/snapshot/config" -type f -empty -delete
find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' -empty -delete
find "$LOG_DIR" -type f -mtime +$DAYS_TO_KEEP -delete
log INFO "Local cleanup logs completed."
