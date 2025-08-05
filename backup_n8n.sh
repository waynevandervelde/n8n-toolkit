#!/bin/bash

#🔍 Auto-detect all Docker Compose containers
#
#📦 Backs up all bind-mounts and volumes
#
#🐘 PostgreSQL DB dump (if running)
#
#☁️ Syncs backups to cloud via rclone
#
#♻️ Cloud retention: deletes remote backups older than 7 days
#
#📬 Optional Mailgun email alerts (just pass email as the first argument)
#
#🧾 Logs all output to logs/backup_YYYY-MM-DD.log

#export MAILGUN_API_KEY=...
#export MAILGUN_DOMAIN=...
#export MAILGUN_FROM=...
#export MAILGUN_TO=...
#export RCLONE_REMOTE=gdrive
#export RCLONE_TARGET=n8n-backups

# === CONFIG ===
BACKUP_DIR="$(pwd)/backups"
LOG_DIR="$(pwd)/logs"
DATE=$(date +%F_%H-%M-%S)
DAYS_TO_KEEP=7
ENABLE_EMAIL="$1" # Pass 'email' to enable email alerts

# Email (Mailgun) variables - set these in your environment or .env loader
MAILGUN_API_KEY="${MAILGUN_API_KEY}"
MAILGUN_DOMAIN="${MAILGUN_DOMAIN}"
MAILGUN_FROM="${MAILGUN_FROM}"
MAILGUN_TO="${MAILGUN_TO}"

# Cloud sync
RCLONE_REMOTE="${RCLONE_REMOTE}"
RCLONE_TARGET="${RCLONE_TARGET}"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$DATE.log"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'handle_error' ERR

handle_error() {
  echo "❌ Backup failed."
  if [[ "$ENABLE_EMAIL" == "email" && -n "$MAILGUN_API_KEY" ]]; then
    curl -s --user "api:$MAILGUN_API_KEY" \
      https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages \
      -F from="$MAILGUN_FROM" \
      -F to="$MAILGUN_TO" \
      -F subject="🚨 n8n Backup Failed" \
      -F text="Backup failed at $(date)"
  fi
  exit 1
}

echo "📦 Starting backup at $DATE..."

# === DETECT COMPOSED CONTAINERS ===
CONTAINERS=$(docker ps --filter "label=com.docker.compose.project" --format "{{.Names}}")

if [ -z "$CONTAINERS" ]; then
  echo "❌ No Docker Compose containers detected. Exiting."
  exit 1
fi

for CONTAINER in $CONTAINERS; do
  echo "🔍 Inspecting container: $CONTAINER"
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

    echo "📁 Backed up: $BACKUP_FILE"
    ((i++))
  done <<< "$MOUNTS"
done

# === BACKUP POSTGRES (if found) ===
POSTGRES_CONTAINER=$(docker ps --filter "ancestor=postgres" --format "{{.Names}}" | head -1)
if [ -n "$POSTGRES_CONTAINER" ]; then
  DB_BACKUP="$BACKUP_DIR/${POSTGRES_CONTAINER}_db_$DATE.sql"
  docker exec "$POSTGRES_CONTAINER" pg_dump -U n8n -d n8ndb > "$DB_BACKUP"
  echo "📦 DB backup: $DB_BACKUP"
fi

# === RCLONE SYNC ===
if command -v rclone &> /dev/null && [ -n "$RCLONE_REMOTE" ]; then
  echo "☁️ Syncing to cloud: $RCLONE_REMOTE/$RCLONE_TARGET"
  rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE:$RCLONE_TARGET" --create-dirs

  # === CLEANUP OLD REMOTE BACKUPS ===
  echo "🧹 Cleaning cloud backups older than $DAYS_TO_KEEP days..."
  rclone delete --min-age ${DAYS_TO_KEEP}d "$RCLONE_REMOTE:$RCLONE_TARGET"
  echo "✅ Cloud cleanup done."
fi

echo "✅ All done at $(date)"

# === SUCCESS EMAIL ALERT (optional) ===
if [[ "$ENABLE_EMAIL" == "email" && -n "$MAILGUN_API_KEY" ]]; then
  curl -s --user "api:$MAILGUN_API_KEY" \
    https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages \
    -F from="$MAILGUN_FROM" \
    -F to="$MAILGUN_TO" \
    -F subject="✅ n8n Backup Success" \
    -F text="Backup completed successfully at $(date)"
fi
