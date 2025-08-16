#!/bin/bash

set -euo pipefail
umask 027
set -o errtrace
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
# Load shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/n8n_common.sh"

trap 'on_interrupt' INT TERM HUP
trap 'log INFO "Exiting (code $?)"' EXIT
# Use local handler so we can email on unexpected failures
trap 'handle_error' ERR

# === Default Configuration ===
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
DAYS_TO_KEEP=7

DO_BACKUP=false
DO_RESTORE=false
DO_FORCE=false
TARGET_RESTORE_FILE=""
LOG_LEVEL="INFO"
NOTIFY_ON_SUCCESS=false
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
RCLONE_REMOTE=""
RCLONE_TARGET=""
EMAIL_TO=""
EMAIL_EXPLICIT=false # set true only if -e/--email is passed
EMAIL_SENT=false # becomes true only after a successful send

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
# can_send_email
################################################################################
can_send_email() {
    [[ -n "$EMAIL_TO" && -n "$SMTP_USER" && -n "$SMTP_PASS" ]]
}

################################################################################
# send_email(subject, body[, attachment])
#   Send an email via Gmail SMTP using msmtp.
################################################################################
send_email() {
    local subject="$1"
    local body="$2"
    local attachment="${3:-}"

    if ! $EMAIL_EXPLICIT; then
        # user never asked → silently skip
        return 0
    fi

    if ! can_send_email; then
        log ERROR "Email requested (-e) but SMTP_USER/SMTP_PASS not set → cannot send email."
        return 1
    fi

    log INFO "Sending email to: $EMAIL_TO"
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
        log INFO "Email sent with subject: $subject"
        EMAIL_SENT=true
    else
        log WARN "Failed to send email with subject: $subject"
    fi
}

################################################################################
# handle_error()
#   Trap for any uncaught error: logs, sends failure email, and exits.
################################################################################
handle_error() {
  # Try to append to the summary only if we have enough context
  if [[ -n "${BACKUP_DIR:-}" && -n "${DATE:-}" ]]; then
    write_summary "Error" "FAIL" || true
  fi

  log ERROR "Unhandled error. See ${LOG_FILE:-"(no log created yet)"}"

  # Attach the log only if it exists
  local attach=""
  [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] && attach="$LOG_FILE"

  send_email "${DATE:-$(date +%F_%H-%M-%S)}: n8n Backup FAILED locally" \
             "An error occurred. See attached log." \
             "$attach" || true
  exit 1
}

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
 	local DB_USER="${DB_POSTGRESDB_USER:-${POSTGRES_USER:-n8n}}"
	local DB_NAME="${DB_POSTGRESDB_DATABASE:-${POSTGRES_DB:-n8n}}"
    if docker exec postgres sh -c "pg_isready" &>/dev/null; then
        docker exec postgres \
            pg_dump -U "$DB_USER" -d "$DB_NAME" \
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
    return 0
}

################################################################################
# upload_backup_rclone()
#   Upload $BACKUP_FILE (and summary) to the rclone remote.
#   Sets UPLOAD_STATUS="SUCCESS", "FAIL" or "SKIPPED".
#   Returns 0 if SKIPPED or SUCCESS, 1 if FAIL.
################################################################################
upload_backup_rclone() {
	local ret=0
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

    # Safer remote prune: only delete our *.tar.gz files older than retention
    log INFO "Pruning remote archives older than $DAYS_TO_KEEP days (limited to our backup patterns)"
    rclone delete --min-age "${DAYS_TO_KEEP}d" \
        --include "n8n_backup_*.tar.gz" \
        --exclude "backup_summary.md" \
        "$RCLONE_REMOTE:$RCLONE_TARGET" || log WARN "Remote prune returned non-zero (continuing)"
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
# print_backup_summary()
#   Print a human-readable summary of what just happened.
################################################################################
print_backup_summary() {
	local summary_file="$BACKUP_DIR/backup_summary.md"
    local email_status email_reason
    local W=24  # label column width
	log INFO "Print a summary of what happened..."

    # Determine whether an email was sent
    if ! $EMAIL_EXPLICIT; then
        email_status="SKIPPED"
        email_reason="(not requested)"
    elif $EMAIL_SENT; then
        email_status="PASS"
        email_reason=""
    else
        if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$EMAIL_TO" ]]; then
            email_status="ERROR"
            email_reason="(missing SMTP config)"
        else
            email_status="FAIL"
            email_reason="(send failed)"
        fi
    fi

    echo "═════════════════════════════════════════════════════════════"
    printf "%-${W}s%s\n" "Action:"                 "$ACTION"
    printf "%-${W}s%s\n" "Status:"                 "$BACKUP_STATUS"
    printf "%-${W}s%s\n" "Timestamp:"              "$DATE"
    printf "%-${W}shttps://%s\n" "Domain:"          "$DOMAIN"
    [[ -n "$BACKUP_FILE" ]] && printf "%-${W}s%s/%s\n" "Backup file:" "$BACKUP_DIR" "$BACKUP_FILE"
    printf "%-${W}s%s\n" "N8N Version:"            "$N8N_VERSION"
    printf "%-${W}s%s\n" "Log File:"               "$LOG_FILE"
    printf "%-${W}s%s\n" "Daily tracking:"         "$summary_file"

    case "$UPLOAD_STATUS" in
        "SUCCESS")
            printf "%-${W}s%s\n" "Google Drive upload:" "SUCCESS"
            printf "%-${W}s%s\n" "Folder link:"         "$DRIVE_LINK"
            ;;
        "SKIPPED")
            printf "%-${W}s%s\n" "Google Drive upload:" "SKIPPED"
            ;;
        *)
            printf "%-${W}s%s\n" "Google Drive upload:" "FAILED"
            ;;
    esac
    printf "%-${W}s%s\n" "Email notification:" "$( [[ -n "$email_reason" ]] && echo "$email_status $email_reason" || echo "$email_status" )"
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
    N8N_VERSION="$(get_current_n8n_version)"
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
        print_backup_summary
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
        print_backup_summary
        return 1
    fi

    # Record in rolling summary
    write_summary "$ACTION" "$BACKUP_STATUS"

	# Remote upload
    upload_backup_rclone

	# cache the Google Drive link exactly once
	DRIVE_LINK="$(get_google_drive_link)"

    # Final email notification
    send_mail_on_action

    # Console summary
    print_backup_summary
}

################################################################################
# restore_n8n()
#   Restores Docker volumes, config, and DB from a backup archive.
#   Returns 0 on success, non-zero on failure.
################################################################################
restore_n8n() {
    load_env_file
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE"
        return 1
    fi
    log INFO "Starting restore at $DATE..."
    local restore_dir="$N8N_DIR/n8n_restore_$(date +%s)"
	mkdir -p "$restore_dir" || { log ERROR "Cannot create $restore_dir"; return 1; }
 
    log INFO "Extracting backup archive to $restore_dir"
	tar -xzf "$TARGET_RESTORE_FILE" -C "$restore_dir" \
      || { log ERROR "Failed to extract $TARGET_RESTORE_FILE"; return 1; }

    # Restore .env and docker-compose.yml if present
    if [[ -f "$restore_dir/.env.bak" ]]; then
        cp -f "$restore_dir/.env.bak" "$N8N_DIR/.env"
        log INFO "Restored .env file to $N8N_DIR/.env"
    fi

    if [[ -f "$restore_dir/docker-compose.yml.bak" ]]; then
        cp -f "$restore_dir/docker-compose.yml.bak" "$N8N_DIR/docker-compose.yml"
        log INFO "Restored docker-compose.yml to $N8N_DIR/docker-compose.yml"
    fi

	# Stop and remove the current containers before cleaning volumes
    log INFO "Stopping and removing containers before restore..."
	compose down --volumes --remove-orphans \
      || { log ERROR "docker-compose down failed"; return 1; }

   	# Check if we have a SQL database	
  	local sql_file
  	sql_file="$(find "$restore_dir" -name "n8n_postgres_dump_*.sql" -print -quit || true)"

	# List volumes will be restored
	# - If the sql_file exists: No need to restore volume postgres-data (to avoid conflict), the other volumes can be restored as normal.
	# - If the sql_file does not exist: restore all volumes ("n8n-data" "postgres-data" "letsencrypt")
	if [[ -n "${sql_file:-}" ]]; then
    	log INFO "SQL dump found. Skipping postgres-data volume restore..."
		local filtered=()
		for v in "${VOLUMES[@]}"; do
			[[ "$v" == "postgres-data" ]] || filtered+=("$v")
		done
		VOLUMES=("${filtered[@]}")
	fi

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
	for vol in "${VOLUMES[@]}"; do
		local vol_file
		vol_file="$(find "$restore_dir" -name "*${vol}_*.tar.gz" -print -quit || true)"
		if [[ -z "${vol_file:-}" ]]; then
	  		log ERROR "No backup found for volume $vol"
	  		return 1
		fi
		docker volume create "$vol" >/dev/null
		docker run --rm -v "${vol}:/data" -v "$restore_dir:/backup" alpine \
	  		sh -c "rm -rf /data/* && tar xzf /backup/$(basename "$vol_file") -C /data" \
	  		|| { log ERROR "Failed to restore $vol"; return 1; }
			log INFO "Volume $vol restored"
	done

    log INFO "Start working on $N8N_DIR ..."
    cd "$N8N_DIR" || { log ERROR "Failed to change directory to $N8N_DIR"; return 1; }

	log INFO "Starting PostgreSQL first..."
	compose up -d postgres \
 		|| { log ERROR "Failed to start postgres"; return 1; }
	log INFO "Waiting for postgres to be healthy..."
 	check_container_healthy "postgres" || return 1

 	# Database
	local PG_CONT="postgres"
	local DB_USER="${DB_POSTGRESDB_USER:-${POSTGRES_USER:-n8n}}"
	local DB_NAME="${DB_POSTGRESDB_DATABASE:-${POSTGRES_DB:-n8n}}"
	
 	local POSTGRES_RESTORE_MODE=""
	if [[ -n "${sql_file:-}" ]]; then
 		POSTGRES_RESTORE_MODE="dump"
		log INFO "SQL dump found: $(basename "$sql_file"). Will restore via psql."
		log INFO "Terminating active connections to ${DB_NAME}..."
		docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c \
			"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" || true

		log INFO "Dropping & recreating database ${DB_NAME}..."
		docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB_NAME};"
		docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

		log INFO "Restoring PostgreSQL DB from dump (single import)..."
		docker exec -i "$PG_CONT" psql -U "$DB_USER" -d "${DB_NAME}" -v ON_ERROR_STOP=1 < "$sql_file"
	else
		POSTGRES_RESTORE_MODE="volume"
  		log INFO "No SQL dump found. Assuming the postgres-data volume already contains the DB. Skipping SQL import."
	fi
 
	# When the PostgreSQL DB is ready, start other containers
	log INFO "Starting the rest of the stack..."
	compose up -d || { log ERROR "docker compose up failed"; return 1; }

    log INFO "Checking services running and healthy after restoring backup..."
    if ! check_services_up_running; then
        log ERROR "Some services and Traefik are not running or unhealthy after restoring the backup"
        log ERROR "Restore the backup failed."
        log INFO "Log File: $LOG_FILE"
        return 1
    else
       log INFO "Services running and healthy"
    fi

    log INFO "Cleaning up..."
    rm -rf "$restore_dir"

    N8N_VERSION="$(get_current_n8n_version)"
 	local restored_list=""
	if ((${#VOLUMES[@]})); then
		restored_list=$(printf '%s, ' "${VOLUMES[@]}")
		restored_list=${restored_list%, }
	else
		restored_list="(none)"
	fi
    echo "═════════════════════════════════════════════════════════════"
	echo "Restore completed successfully."
    echo "Domain:               https://${DOMAIN}"
    echo "Restore from file:    $TARGET_RESTORE_FILE"
    echo "N8N Version:          $N8N_VERSION"
	echo "N8N Directory:		$N8N_DIR"
    echo "Log File:             $LOG_FILE"
    echo "Timestamp:            $DATE"
	echo "Volumes restored:     ${restored_list}"
	if [[ "$POSTGRES_RESTORE_MODE" == "dump" ]]; then
		echo "PostgreSQL:           Restored from SQL dump"
	else
		echo "PostgreSQL:           Restored from volume"
	fi
    echo "═════════════════════════════════════════════════════════════"
}

# === Argument Parsing (long & short) ===
TEMP=$(getopt -o fbr:d:l:e:s:t:nh --long force,backup,restore:,dir:,log-level:,email:,remote-name:,remote-target:,notify-on-success,help -n "$0" -- "$@") || usage
eval set -- "$TEMP"

while true; do
    log DEBUG "Parsing argument: $1"
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
            LOG_LEVEL="${2^^}"
            shift 2
            ;;
        -e|--email)
            EMAIL_TO="$2"
            EMAIL_EXPLICIT=true
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
check_root || { log ERROR "Please run as root (needed to read Docker volumes)."; exit 1; }
# Initialize directories & logging
N8N_DIR="${N8N_DIR:-$PWD}"
ENV_FILE="$N8N_DIR/.env"
COMPOSE_FILE="$N8N_DIR/docker-compose.yml"

BACKUP_DIR="$N8N_DIR/backups"
LOG_DIR="$N8N_DIR/logs"
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$BACKUP_DIR/snapshot/volumes" "$BACKUP_DIR/snapshot/config"

DATE=$(date +%F_%H-%M-%S)
mode="restore"; [[ "$DO_BACKUP" == "true" ]] && mode="backup"
LOG_FILE="$LOG_DIR/${mode}_n8n_$DATE.log"
exec > >(tee "$LOG_FILE") 2>&1
log INFO "Working on directory: $N8N_DIR"
log INFO "Logging to $LOG_FILE"

# Ensure we have everything we need
require_cmd docker || exit 1
require_cmd rsync  || exit 1
require_cmd tar    || exit 1
require_cmd curl   || exit 1
require_cmd openssl|| exit 1
require_cmd base64 || exit 1

# Only require msmtp if we might send mail
$EMAIL_EXPLICIT && require_cmd msmtp

# Only require rclone if a remote is configured
[[ -n "$RCLONE_REMOTE" && -n "$RCLONE_TARGET" ]] && require_cmd rclone

# Email config sanity checks
if $EMAIL_EXPLICIT; then
    missing=()
    [[ -z "${SMTP_USER:-}" ]] && missing+=("SMTP_USER")
    [[ -z "${SMTP_PASS:-}" ]] && missing+=("SMTP_PASS")
    [[ -z "${EMAIL_TO:-}"  ]] && missing+=("EMAIL_TO/-e")

    if ((${#missing[@]})); then
        log WARN "Email notifications requested (-e), but missing: ${missing[*]}. Emails will NOT be sent."
    else
        if [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
            log INFO "Emails enabled → will notify on success and failure: $EMAIL_TO"
        else
            log INFO "Emails enabled → will notify on failure: $EMAIL_TO"
        fi
    fi
elif [[ "$NOTIFY_ON_SUCCESS" == true ]]; then
    log WARN "--notify-on-success was set, but no -e/--email provided. No email will be sent."
fi

# Load DOMAIN from .env (needed by initialize_snapshot)
load_env_file
initialize_snapshot

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
