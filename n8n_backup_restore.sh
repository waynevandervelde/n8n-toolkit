#!/bin/bash

set -euo pipefail
umask 027
set -o errtrace
IFS=$'\n\t'
#############################################################################################
# N8N Backup & Restore Script with Gmail SMTP Email Notifications via msmtp
# Author:      TheNguyen
# Email:       thenguyen.ai.automation@gmail.com
# Version:     1.1.0
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

# rclone robust flags
RCLONE_FLAGS=(--transfers=4 --checkers=8 --retries=5 --low-level-retries=10 --contimeout=30s --timeout=5m --retries-sleep=10s)

################################################################################
# box_line()
# Description:
#   Print a left-aligned label (fixed width 22) and a value on one line.
#
# Behaviors:
#   - Uses printf "%-22s%s\n" to align the status box output.
#
# Returns:
#   0 always.
################################################################################
box_line() { printf "%-22s%s\n" "$1" "$2"; }

################################################################################
# can_send_email()
# Description:
#   Check whether SMTP config is sufficient to send email.
#
# Behaviors:
#   - Verifies EMAIL_TO, SMTP_USER, SMTP_PASS are all non-empty.
#
# Returns:
#   0 if all present; 1 otherwise.
################################################################################
can_send_email() {
    [[ -n "$EMAIL_TO" && -n "$SMTP_USER" && -n "$SMTP_PASS" ]]
}

################################################################################
# send_email()
# Description:
#   Send a multipart email via Gmail SMTP (msmtp), optional attachment.
#
# Behaviors:
#   - No-op if EMAIL_EXPLICIT=false.
#   - Validates SMTP creds; logs error and returns non-zero if missing.
#   - Builds multipart MIME with text body and optional base64 attachment.
#   - Pipes message to msmtp with STARTTLS (smtp.gmail.com:587).
#   - Sets EMAIL_SENT=true on success.
#
# Returns:
#   0 on success; non-zero if send fails.
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
	local pass_tmp
	pass_tmp="$(mktemp)"
	printf '%s' "$SMTP_PASS" > "$pass_tmp"
 	chmod 600 "$pass_tmp"
    } | msmtp \
        --host=smtp.gmail.com \
        --port=587 \
        --auth=on \
        --tls=on \
        --from="$SMTP_USER" \
        --user="$SMTP_USER" \
		--passwordeval="cat $pass_tmp" \
        "$EMAIL_TO"

	local rc=$?
	rm -f "$pass_tmp"
	if [[ $rc -eq 0 ]]; then
	    log INFO "Email sent with subject: $subject"
	    EMAIL_SENT=true
	else
	    log WARN "Failed to send email with subject: $subject"
	fi
}

################################################################################
# handle_error()
# Description:
#   Global ERR trap: record failure, notify, and exit.
#
# Behaviors:
#   - Appends FAIL line to backup_summary.md (if context exists).
#   - Logs error and emails failure with LOG_FILE attached (if possible).
#   - Exits the script with status 1.
#
# Returns:
#   Never returns (exits 1).
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
  -n, --notify-on-success    Email on successful completion
  -h, --help                 Show this help message
EOF
  exit 1
}

################################################################################
# initialize_snapshot()
# Description:
#   Create the initial snapshot tree for change detection.
#
# Behaviors:
#   - Creates snapshot directories for each volume and for config.
#   - Rsyncs current data of volumes and config (.env, docker-compose.yml).
#   - Skips if snapshot already exists.
#
# Returns:
#   0 on success; non-zero on failure.
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
		[[ -f "$N8N_DIR/.env" ]] && rsync -a "$N8N_DIR/.env" "$BACKUP_DIR/snapshot/config/"
		[[ -f "$N8N_DIR/docker-compose.yml" ]] && rsync -a "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
        log INFO "Snapshot bootstrapped."
    fi
}

################################################################################
# refresh_snapshot()
# Description:
#   Update snapshot after a successful backup.
#
# Behaviors:
#   - Rsyncs (with --delete) live volumes into snapshot (excludes PG transient dirs).
#   - Rsyncs current .env and docker-compose.yml into snapshot/config.
#
# Returns:
#   0 on success; non-zero on failure.
################################################################################
refresh_snapshot() {
	log INFO "Updating snapshot to current state"
	for vol in "${VOLUMES[@]}"; do
		rsync -a --delete \
		  --exclude='pg_wal/**' \
		  --exclude='pg_stat_tmp/**' \
		  --exclude='pg_logical/**' \
		  "/var/lib/docker/volumes/${vol}/_data/" \
		  "$BACKUP_DIR/snapshot/volumes/$vol/"
	done

	[[ -f "$N8N_DIR/.env" ]] && rsync -a --delete "$N8N_DIR/.env" "$BACKUP_DIR/snapshot/config/"
	[[ -f "$N8N_DIR/docker-compose.yml" ]] && rsync -a --delete "$N8N_DIR/docker-compose.yml" "$BACKUP_DIR/snapshot/config/"
	log INFO "Snapshot refreshed."
}

################################################################################
# is_system_changed()
# Description:
#   Determine if live data differs from the snapshot (to decide backup).
#
# Behaviors:
#   - For each volume: rsync dry-run with excludes (pg_wal, pg_stat_tmp, pg_logical).
#   - For configs: rsync dry-run on .env and docker-compose.yml (only if they exist).
#   - Creates snapshot target dirs if missing.
#   - If any file changes detected → considered "changed".
#
# Returns:
#   0 if changed; 1 if no differences.
################################################################################
is_system_changed() {
    local src dest diffs file vol

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
    mkdir -p "$dest"
    for file in .env docker-compose.yml; do
        if [[ -f "$N8N_DIR/$file" ]]; then
            diffs=$(
                rsync -rtun --out-format="%n" "$N8N_DIR/$file" "$dest" \
                | grep -v '/$'
            ) || true
            if [[ -n "$diffs" ]]; then
                log INFO "Change detected in config: $file"
                log DEBUG "  $diffs"
                return 0
            fi
        else
            log DEBUG "Config not present (skip diff): $file"
        fi
    done

    # No differences found
    return 1
}

################################################################################
# get_google_drive_link()
# Description:
#   Produce Google Drive folder URL for the configured rclone remote.
#
# Behaviors:
#   - Reads root_folder_id from `rclone config show <remote>`.
#   - Prints folder URL if found; prints empty string otherwise.
#
# Returns:
#   0 always (outputs URL or empty on stdout).
################################################################################
get_google_drive_link() {
    # If no remote or no target, output nothing
    if [[ -z "$RCLONE_REMOTE" ]]; then
        echo ""
        return
    fi

    # Read the root_folder_id from rclone config
    local folder_id
	folder_id=$(rclone config show "$RCLONE_REMOTE" 2>/dev/null \
            | awk -F '=' '$1 ~ /root_folder_id/ { gsub(/[[:space:]]/, "", $2); print $2 }')

    if [[ -n "$folder_id" ]]; then
        echo "https://drive.google.com/drive/folders/$folder_id"
    else
        log WARN "Could not find root_folder_id for remote '$RCLONE_REMOTE'"
        echo ""
    fi
}

################################################################################
# write_summary()
# Description:
#   Append action/status to backup_summary.md and prune entries >30 days old.
#
# Behaviors:
#   - Creates header if file is missing.
#   - Appends a table row: DATE | ACTION | N8N_VERSION | STATUS.
#   - Keeps only rows with DATE >= cutoff (30 days ago), preserving header.
#
# Returns:
#   0 on success; non-zero on failure.
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
# Description:
#   Execute local backup: volumes, Postgres dump, config copy, compress, checksum.
#
# Behaviors:
#   - Verifies N8N_ENCRYPTION_KEY exists in .env.
#   - Archives each Docker volume to BACKUP_PATH as tar.gz chunks.
#   - Dumps Postgres DB from container "postgres" to SQL file.
#   - Copies .env and docker-compose.yml as *.bak.
#   - Compresses BACKUP_PATH into BACKUP_DIR/n8n_backup_<ver>_<ts>.tar.gz
#       * Uses `tar | pigz` if pigz exists; else `tar -czf`.
#   - Generates SHA-256 checksum for the archive.
#   - Prunes old archives/checksums older than DAYS_TO_KEEP.
#
# Returns:
#   0 on success; non-zero on any failure.
################################################################################
do_local_backup() {
    # Make sure encryption key exists BEFORE taking backup
	ensure_encryption_key_exists "$N8N_DIR/.env" || { BACKUP_STATUS="FAIL"; return 1; }

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
	log INFO "Backing up ./local-files directory..."
	if [[ -d "$N8N_DIR/local-files" ]]; then
	    tar -czf "$BACKUP_PATH/local-files_$DATE.tar.gz" -C "$N8N_DIR" local-files \
	        || { log ERROR "Failed to backup local-files directory"; return 1; }
	    log INFO "local-files directory backed up"
	else
	    log INFO "No local-files directory found, skipping..."
	fi

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

	if command -v pigz >/dev/null 2>&1; then
    tar -C "$BACKUP_PATH" -cf - . | pigz > "$BACKUP_DIR/$BACKUP_FILE" \
        || { log ERROR "Failed to compress backup with pigz"; return 1; }
	else
	    tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$BACKUP_PATH" . \
	        || { log ERROR "Failed to compress backup with gzip"; return 1; }
	fi
	log INFO "Created archive -> $BACKUP_DIR/$BACKUP_FILE"	

  	# sha256 checksum
	if [[ -f "$BACKUP_DIR/$BACKUP_FILE" ]]; then
    sha256sum "$BACKUP_DIR/$BACKUP_FILE" > "$BACKUP_DIR/$BACKUP_FILE.sha256" \
        || { log ERROR "Failed to write checksum"; return 1; }
	else
	    log ERROR "Archive not found after compression: $BACKUP_DIR/$BACKUP_FILE"
	    return 1
	fi
	log INFO "Created checksum -> $BACKUP_DIR/$BACKUP_FILE.sha256"

	log INFO "Cleaning up local backups older than $DAYS_TO_KEEP days..."
 	rm -rf "$BACKUP_PATH"
    find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
	find "$BACKUP_DIR" -type f -name "*.sha256" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
	find "$BACKUP_DIR" -maxdepth 1 -type d -name 'backup_*' -empty -exec rmdir {} \;
	log INFO "Removed any empty backup_<timestamp> folders"
    return 0
}

################################################################################
# upload_backup_rclone()
# Description:
#   Upload the archive, its checksum, and backup_summary.md to rclone remote,
#   then prune remote old files.
#
# Behaviors:
#   - If RCLONE_REMOTE is empty → sets UPLOAD_STATUS=SKIPPED and returns 0.
#   - Uploads files via `rclone copyto` to remote root.
#   - Sets UPLOAD_STATUS=SUCCESS on success; FAIL on any upload error.
#   - Prunes remote files older than DAYS_TO_KEEP by filter (keeps recent ones).
#
# Returns:
#   0 on full success; non-zero if upload failed (prune still attempted).
################################################################################
upload_backup_rclone() {
    require_cmd rclone || { log ERROR "rclone is required for uploads"; return 1; }
    local ret=0

    if [[ -z "${RCLONE_REMOTE:-}" ]]; then
        UPLOAD_STATUS="SKIPPED"
        log INFO "Rclone remote not set; skipping upload."
        return 0
    fi

    # Normalize remote (force one colon)
    local REMOTE="${RCLONE_REMOTE%:}:"
    log INFO "Uploading backup files directly to remote root ($REMOTE)"

	if  rclone copyto "$BACKUP_DIR/$BACKUP_FILE" "$REMOTE/$BACKUP_FILE" "${RCLONE_FLAGS[@]}" \
        && rclone copyto "$BACKUP_DIR/$BACKUP_FILE.sha256" "$REMOTE/$BACKUP_FILE.sha256" "${RCLONE_FLAGS[@]}" \
        && rclone copyto "$BACKUP_DIR/backup_summary.md" "$REMOTE/backup_summary.md" "${RCLONE_FLAGS[@]}"; then
        UPLOAD_STATUS="SUCCESS"
        log INFO "Uploaded '$BACKUP_FILE', checksum and 'backup_summary.md' successfully."
		ret=0
    else
        UPLOAD_STATUS="FAIL"
        log ERROR "One or more uploads failed"
		ret=1
    fi

    # Safer remote prune
    log INFO "Pruning remote archives older than ${DAYS_TO_KEEP:-7} days (pattern: n8n_backup_*.tar.gz)"
    local tmpfilter; tmpfilter="$(mktemp)"
	printf "%s\n" "+ n8n_backup_*.tar.gz" "+ n8n_backup_*.tar.gz.sha256" "- *" > "$tmpfilter"
    rclone delete "$REMOTE" --min-age "${DAYS_TO_KEEP:-7}d" --filter-from "$tmpfilter" --rmdirs \
        || log WARN "Remote prune returned non-zero (continuing)."
    rm -f "$tmpfilter"

    return $ret
}

################################################################################
# send_mail_on_action()
# Description:
#   Decide whether and what to email based on BACKUP_STATUS/UPLOAD_STATUS.
#
# Behaviors:
#   - Composes subject/body per cases:
#       * Local FAIL → always email (attach LOG_FILE).
#       * Upload FAIL → always email.
#       * SUCCESS/SKIPPED → email only if NOTIFY_ON_SUCCESS=true.
#   - Calls send_email accordingly.
#
# Returns:
#   0 if email not needed or sent successfully; non-zero if send fails.
################################################################################
send_mail_on_action() {
    local subject body

    #Determine subject/body based on statuses:
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

But the upload to $RCLONE_REMOTE failed.
See log for details:

Log File: $LOG_FILE"

    elif [[ "$BACKUP_STATUS" == "SUCCESS" && "$UPLOAD_STATUS" == "SUCCESS" ]]; then
        subject="$DATE: n8n Backup SUCCESS"
        body="Backup and upload completed successfully.

  File: $BACKUP_FILE
  Remote: $RCLONE_REMOTE
  Drive Link: ${DRIVE_LINK:-N/A}"

    elif [[ "$BACKUP_STATUS" == "SUCCESS" && "$UPLOAD_STATUS" == "SKIPPED" ]]; then
        subject="$DATE: n8n Backup SUCCESS (upload skipped)"
        body="Local backup completed successfully.

  File: $BACKUP_FILE
  Remote upload: SKIPPED (no rclone remote/target configured)
  
  Log File: $LOG_FILE"

	else
        subject="$DATE: n8n Backup status unknown"
        body="Backup reported an unexpected status:
  BACKUP_STATUS=$BACKUP_STATUS
  UPLOAD_STATUS=$UPLOAD_STATUS
  Log File: $LOG_FILE"
    fi

    # Decide whether to send email:
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
			send_email "$subject" "$body" "$LOG_FILE"
        fi
    fi
}

################################################################################
# print_backup_summary()
# Description:
#   Print a human-readable, aligned one-shot summary of the latest action
#   (backup/restore) to the console.
#
# Behaviors:
#   - Derives the email outcome line:
#       * EMAIL_EXPLICIT=false  → "SKIPPED (not requested)"
#       * EMAIL_SENT=true       → "SUCCESS"
#       * Missing SMTP config   → "ERROR (missing SMTP config)"
#       * Otherwise             → "FAILED (send failed)"
#   - Renders a status box via box_line() for:
#       Action, Status, Timestamp, Domain, Backup file (if any),
#       N8N Version, Log File, Daily tracking (backup_summary.md),
#       Google Drive upload (SUCCESS/SKIPPED/FAILED) and Folder link (if SUCCESS),
#       Email notification (derived as above).
#
# Returns:
#   0 always.
################################################################################
print_backup_summary() {
	local summary_file="$BACKUP_DIR/backup_summary.md"
    local email_status email_reason
	log INFO "Print a summary of what happened..."

    # Determine whether an email was sent
    if ! $EMAIL_EXPLICIT; then
        email_status="SKIPPED"
        email_reason="(not requested)"
    elif $EMAIL_SENT; then
        email_status="SUCCESS"
        email_reason=""
    else
        if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$EMAIL_TO" ]]; then
            email_status="ERROR"
            email_reason="(missing SMTP config)"
        else
            email_status="FAILED"
            email_reason="(send failed)"
        fi
    fi

    echo "═════════════════════════════════════════════════════════════"
    box_line "Action:"    "$ACTION"
    box_line "Status:"    "$BACKUP_STATUS"
	box_line "Timestamp:"    "$DATE"
    box_line "Domain:"    "https://$DOMAIN"
    [[ -n "$BACKUP_FILE" ]] && box_line "Backup file:"    "$BACKUP_DIR/$BACKUP_FILE"
    box_line "N8N Version:"    "$N8N_VERSION"
    box_line "Log File:"    "$LOG_FILE"
    box_line "Daily tracking:"    "$summary_file"
    case "$UPLOAD_STATUS" in
        "SUCCESS")
            box_line "Google Drive upload:"    "SUCCESS"
            box_line "Folder link:"    "$DRIVE_LINK"
            ;;
        "SKIPPED")
            box_line "Google Drive upload:"    "SKIPPED"
            ;;
        *)
            box_line "Google Drive upload:"    "FAILED"
            ;;
    esac
    if [[ -n "$email_reason" ]]; then
        box_line "Email notification:"    "$email_status $email_reason"
    else
        box_line "Email notification:"    "$email_status"
    fi
    echo "═════════════════════════════════════════════════════════════"
}

################################################################################
# backup_n8n()
# Description:
#   Orchestrate a full backup: change check → local backup → upload → notify/print.
#
# Behaviors:
#   - If no changes and not forced → marks SKIPPED, writes summary, optional email.
#   - Runs do_local_backup(); on success refreshes snapshot and writes summary.
#   - If remote configured, uploads and prunes; captures DRIVE_LINK.
#   - Sends final email per policy and prints the summary box.
#
# Returns:
#   0 on success (including SKIPPED); 1 if local backup failed.
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
# fetch_restore_archive_if_remote()
# Description:
#   If TARGET_RESTORE_FILE points to an rclone remote, download it locally
#   and verify checksum when available.
#
# Behaviors:
#   - No-op if TARGET_RESTORE_FILE already exists locally.
#   - For "remote:path/file": downloads to BACKUP_DIR/_restore_tmp/<sanitized_name>.
#   - Attempts to fetch .sha256 and verify via sha256sum -c.
#   - Rewrites TARGET_RESTORE_FILE to the local path on success.
#
# Returns:
#   0 on success; non-zero on download/verification failure.
################################################################################
fetch_restore_archive_if_remote() {
    # Already a real local file? nothing to do.
    if [[ -f "$TARGET_RESTORE_FILE" ]]; then
        return 0
    fi

    # Heuristic: looks like "remote:path/..." (and not an absolute local path)
    if [[ "$TARGET_RESTORE_FILE" == *:* && "$TARGET_RESTORE_FILE" != /* ]]; then
        require_cmd rclone || { log ERROR "rclone required to fetch remote backup."; return 1; }

        local tmp_dir="$BACKUP_DIR/_restore_tmp"
        mkdir -p "$tmp_dir"

        # Derive a local filename (keep the basename of the remote object)
		# Sanitize basename: replace ':' with '_'
        local base
		base="$(basename "$TARGET_RESTORE_FILE" | tr ':' '_')"
        local local_path="$tmp_dir/$base"

        log INFO "Fetching backup from remote: $TARGET_RESTORE_FILE"
		if rclone copyto "$TARGET_RESTORE_FILE" "$local_path" "${RCLONE_FLAGS[@]}"; then
            log INFO "Downloaded to: $local_path"
            # try to fetch checksum and verify if available
			log INFO "Verifying checksum..."
            if rclone copyto "${TARGET_RESTORE_FILE}.sha256" "${local_path}.sha256" "${RCLONE_FLAGS[@]}"; then
                (cd "$tmp_dir" && sha256sum -c "$(basename "${local_path}.sha256")") \
                    || { log ERROR "Checksum verification failed for $local_path"; return 1; }
                log INFO "Checksum verified."
            else
                log WARN "Checksum file not found remotely. Skipping verification."
            fi
            TARGET_RESTORE_FILE="$local_path"
            echo "$TARGET_RESTORE_FILE" > "$tmp_dir/.last_fetched"
        else
            log ERROR "Failed to fetch remote backup: $TARGET_RESTORE_FILE"
            return 1
        fi
    fi
}

################################################################################
# restore_n8n()
# Description:
#   Restore the n8n stack from a backup archive (configs, volumes, database).
#
# Behaviors:
#   - Fetches remote archive if needed; extracts to temp dir.
#   - Validates .env.bak (with N8N_ENCRYPTION_KEY) and docker-compose.yml.bak,
#     then restores them to N8N_DIR and reloads env.
#   - Stops stack (compose down --volumes --remove-orphans).
#   - If DB dump (*.dump or *.sql) present → skip postgres-data volume restore.
#   - Recreates and restores non-DB volumes from their tarballs.
#   - Starts postgres, waits healthy, then:
#       * For .dump → drop/create DB and pg_restore -c -v.
#       * For .sql  → drop/create DB and psql < file.
#       * If none   → assume DB came from restored volume.
#   - Starts remaining services (compose up -d), health-checks stack.
#   - Cleans temp files and prints aligned summary.
#
# Returns:
#   0 on success; non-zero on any failure.
################################################################################
restore_n8n() {
	local requested_spec="$TARGET_RESTORE_FILE"

    # If it's a remote like "gdrive-user:n8n-backups/xxx.tar.gz", fetch it locally
    fetch_restore_archive_if_remote || { log ERROR "Failed to fetch remote restore archive."; return 1; }

    # After fetch, TARGET_RESTORE_FILE should be a local path
    if [[ ! -f "$TARGET_RESTORE_FILE" ]]; then
        log ERROR "Restore file not found: $TARGET_RESTORE_FILE (requested: $requested_spec)"
        return 1
    fi

    log INFO "Starting restore at $DATE..."
    local restore_dir="$N8N_DIR/n8n_restore_$(date +%s)"
	mkdir -p "$restore_dir" || { log ERROR "Cannot create $restore_dir"; return 1; }
 
    log INFO "Extracting backup archive to $restore_dir"
	tar -xzf "$TARGET_RESTORE_FILE" -C "$restore_dir" \
        || { log ERROR "Failed to extract $TARGET_RESTORE_FILE"; return 1; }

	local backup_env_path="$restore_dir/.env.bak"
	local current_env_path="$N8N_DIR/.env"
 	local backup_compose_path="$restore_dir/docker-compose.yml.bak"
	local current_compose_path="$N8N_DIR/docker-compose.yml"
 
	if [[ ! -f "$backup_env_path" ]]; then
		log ERROR "Not found $backup_env_path. Aborting restore."
        return 1
    fi

	if [[ ! -f "$backup_compose_path" ]]; then
        log ERROR "Not found $backup_compose_path. Aborting restore."
        return 1
    fi

 	# Verify N8N_ENCRYPTION_KEY is present in backup .env
  	local n8n_encryption_key
    n8n_encryption_key="$(read_env_var "$backup_env_path" N8N_ENCRYPTION_KEY || true)"
    if [[ -z "$n8n_encryption_key" ]]; then
        log ERROR "$backup_env_path has no N8N_ENCRYPTION_KEY. Aborting restore."
        return 1
    fi

    if ! looks_like_b64 "$n8n_encryption_key"; then
        log WARN "N8N_ENCRYPTION_KEY in $backup_env_path doesn't look base64. Decryption may fail."
    fi
    log INFO "N8N_ENCRYPTION_KEY (masked): $(mask_secret "$n8n_encryption_key")"

	log INFO "Restoring local-files directory..."
	if [[ -f "$restore_dir/local-files_"*".tar.gz" ]]; then
	    tar -xzf "$restore_dir"/local-files_*.tar.gz -C "$N8N_DIR" \
	        || { log ERROR "Failed to restore local-files"; return 1; }
	    log INFO "local-files directory restored"
	else
	    log INFO "No local-files archive found, skipping..."
	fi

    # Restore .env and docker-compose.yml
 	cp -f "$backup_env_path" "$current_env_path"
  	log INFO "Restored $backup_env_path to $current_env_path"
  	cp -f "$backup_compose_path" "$current_compose_path"
   	log INFO "Restored $backup_compose_path to $current_compose_path"

	# Reload restored .env so later steps (DOMAIN, etc.) reflect the restored config
	load_env_file "$current_env_path"	

  	# Stop and remove the current containers before cleaning volumes
    log INFO "Stopping and removing containers before restore..."
	compose down --volumes --remove-orphans \
		|| { log ERROR "docker-compose down failed"; return 1; }

	# Check if we have a SQL database
    local dump_file=""
    local sql_file=""
    dump_file="$(find "$restore_dir" -name "n8n_postgres_dump_*.dump" -print -quit || true)"
    sql_file="$(find "$restore_dir" -name "n8n_postgres_dump_*.sql" -print -quit || true)"

	# List volumes will be restored
	# - If the sql_file exists: No need to restore volume postgres-data (to avoid conflict), the other volumes can be restored as normal.
	# - If the sql_file does not exist: restore all volumes ("n8n-data" "postgres-data" "letsencrypt")
 	local RESTORE_VOLUMES=("${VOLUMES[@]}")
  	if [[ -n "$dump_file" || -n "$sql_file" ]]; then
        log INFO "SQL dump present. Skipping postgres-data volume restore..."
        local filtered=()
        for v in "${RESTORE_VOLUMES[@]}"; do
            [[ "$v" == "postgres-data" ]] || filtered+=("$v")
        done
        RESTORE_VOLUMES=("${filtered[@]}")
    fi

 	# Cleanup volumes to avoid DB conflict
    log INFO "Cleaning existing Docker volumes before restore..."
    for vol in "${RESTORE_VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            docker volume rm "$vol" && log INFO "Removed volume: $vol"
        else
            log INFO "Volume '$vol' not found, skipping..."
        fi
    done

    # Restore Docker volumes
	log INFO "Restoring volumes from archive..."
	for vol in "${RESTORE_VOLUMES[@]}"; do
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

 	if [[ -n "$dump_file" ]]; then
        POSTGRES_RESTORE_MODE="dump"
        log INFO "Custom dump found: $(basename "$dump_file"). Restoring via pg_restore..."
        log INFO "Recreate database ${DB_NAME}..."
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" || true
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB_NAME};"
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
        docker exec -i "$PG_CONT" pg_restore -U "$DB_USER" -d "${DB_NAME}" -c -v < "$dump_file"

    elif [[ -n "$sql_file" ]]; then
        POSTGRES_RESTORE_MODE="dump"
        log INFO "SQL dump found: $(basename "$sql_file"). Restoring via psql..."
        log INFO "Recreate database ${DB_NAME}..."
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" || true
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB_NAME};"
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
        docker exec -i "$PG_CONT" psql -U "$DB_USER" -d "${DB_NAME}" -v ON_ERROR_STOP=1 < "$sql_file"

    else
        POSTGRES_RESTORE_MODE="volume"
        log INFO "No SQL dump found. Assuming the postgres-data volume already contains the DB. Skipping SQL import."
    fi
 
	# When the PostgreSQL DB is ready, start other containers
	log INFO "Starting the rest of the stack..."
	compose up -d || { log ERROR "docker-compose up failed"; return 1; }

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
    # Optional: clean up any fetched temp archive
    if [[ -d "$BACKUP_DIR/_restore_tmp" ]]; then
        # Only remove files we created; ignore user local archives
        find "$BACKUP_DIR/_restore_tmp" -type f -name '*n8n_backup_*.tar.gz' -delete || true
        rmdir "$BACKUP_DIR/_restore_tmp" 2>/dev/null || true
    fi

    N8N_VERSION="$(get_current_n8n_version)"
 	local restored_list=""
	if ((${#RESTORE_VOLUMES[@]})); then
		restored_list=$(printf '%s, ' "${RESTORE_VOLUMES[@]}")
		restored_list=${restored_list%, }
	else
		restored_list="(none)"
	fi
    echo "═════════════════════════════════════════════════════════════"
	echo "Restore completed successfully."
    box_line "Domain:"    "https://$DOMAIN"
	box_line "Restore from file:"    "$requested_spec"
 	box_line "Local archive used:"    "$TARGET_RESTORE_FILE"
  	box_line "N8N Version:"    "$N8N_VERSION"
    box_line "N8N Directory:"    "$N8N_DIR"
	box_line "Log File:"    "$LOG_FILE"
    box_line "Timestamp:"    "$DATE"
	box_line "Volumes restored:"    "${restored_list}"
	if [[ "$POSTGRES_RESTORE_MODE" == "dump" ]]; then
        box_line "PostgreSQL:"    "Restored from SQL dump"
	else
  		box_line "PostgreSQL:"    "Restored from volume"
	fi
    echo "═════════════════════════════════════════════════════════════"
}

# === Argument Parsing (long & short) ===
TEMP=$(getopt -o fbr:d:l:e:s:nh --long force,backup,restore:,dir:,log-level:,email:,remote-name:,notify-on-success,help -n "$0" -- "$@") || usage
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
DEFAULT_N8N_DIR="/home/n8n"
mkdir -p "$DEFAULT_N8N_DIR"
N8N_DIR="${N8N_DIR:-$DEFAULT_N8N_DIR}"

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
require_cmd awk    || exit 1
require_cmd sha256sum || exit 1

# Only require msmtp if we might send mail
$EMAIL_EXPLICIT && require_cmd msmtp

# Only require rclone if a remote is configured
[[ -n "$RCLONE_REMOTE" ]] && require_cmd rclone

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
