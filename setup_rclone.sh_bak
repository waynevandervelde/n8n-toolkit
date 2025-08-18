#!/usr/bin/env bash
set -euo pipefail

#############################################################################################
# setup_rclone.sh
# Author: TheNguyen
# Email: thenguyen.ai.automation@gmail.com
# Version: 1.0.0
# Date: 2025-08-09
#
# Description:
#   A one‐stop installer & tester for Rclone → Google Drive
#############################################################################################

# ------------------------------
# Logging
# ------------------------------
LOG_LEVEL="${LOG_LEVEL:-INFO}"
log() {
  local level="$1"; shift
  local show=1
  case "$LOG_LEVEL" in
    DEBUG) show=0 ;;
    INFO)  [[ "$level" != "DEBUG" ]] && show=0 ;;
    WARN)  [[ "$level" == "WARN" || "$level" == "ERROR" ]] && show=0 ;;
    ERROR) [[ "$level" == "ERROR" ]] && show=0 ;;
  esac
  [[ $show -eq 0 ]] && echo "[$level] $*"
}

# ------------------------------
# Usage & Help
# ------------------------------
usage() {
  cat <<EOF
setup_rclone.sh — Interactive Rclone→Google Drive Setup

USAGE:
  $0 [ -h | --help ]   # Show this manual
  $0 [ -t ]            # Test mode: install/check rclone & show existing config
  $0                   # Full interactive setup + test cycle

OPTIONS:
  -h, --help   Show detailed manual steps.
  -t           Test/install rclone and list any existing Rclone config/remotes.

MANUAL STEPS (shown with -h):
  1) Create OAuth credentials:
     • Go to https://console.cloud.google.com/apis/credentials
     • +CREATE CREDENTIALS → OAuth client ID → Desktop app
     • Copy Client ID & Client Secret

  2) Add yourself as a Test User:
     • In Cloud Console → OAuth consent screen → Test users → Add your email

  3) Perform headless OAuth:
     • On Windows:
         ssh -N -L 53682:127.0.0.1:53682 root@VPS_IP
     • On VPS:
         rclone authorize "drive" --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
     • In your Windows browser:
         1. Paste the printed URL
         2. Sign in & click Allow
         3. Copy the entire JSON blob

  4) Create & share your backup folder:
     • In Google Drive, create a folder named "n8n-backups"
     • Share it with your service account or yourself
     • Copy its folder ID (string after /folders/ in the URL)

  5) Manual config & test cycle:
     ```bash
     mkdir -p ~/.config/rclone
     nano ~/.config/rclone/rclone.conf
     ```
     Paste this block (fill YOUR_* values):
     ```
     [gdrive-user]
     type = drive
     client_id = YOUR_CLIENT_ID
     client_secret = YOUR_CLIENT_SECRET
     scope = drive.file
     root_folder_id = YOUR_N8N_BACKUPS_FOLDER_ID
     token = YOUR_COPIED_JSON_BLOB
     ```
     Save & exit.
     Test upload with timestamped file:
     ```bash
     # list (empty or existing)
     rclone ls gdrive-user:

     # create test file
     F="rclone_setup_test_$(date +%s).txt"
     echo "rclone setup test $(date)" > "/tmp/$F"

     # upload
     rclone copy "/tmp/$F" gdrive-user:"$F"

     # verify
     rclone ls gdrive-user:

     # cleanup
     rclone delete gdrive-user:"$F"
     rm "/tmp/$F"
     ```
EOF
}

# ------------------------------
# Helpers
# ------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERROR "Missing command: $1"; exit 1; }
}

read_default() {
  local prompt="$1" default="$2" __outvar="$3" reply
  read -e -rp "$prompt [$default]: " reply || true
  [[ -z "$reply" ]] && reply="$default"
  printf -v "$__outvar" "%s" "$reply"
}

read_required() {
  local prompt="$1" __outvar="$2" reply
  while :; do
    read -e -rp "$prompt: " reply
    [[ -n "$reply" ]] && break
    echo "  → This value is required."
  done
  printf -v "$__outvar" "%s" "$reply"
}

extract_folder_id() {
  local input="${1%/}"
  echo "${input##*/}"
}

# ---------------------------------------------------
# Argument parsing
# ---------------------------------------------------
TEST_ONLY=0
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  usage; exit 0
elif [[ "${1:-}" == "-t" ]]; then
  TEST_ONLY=1
fi

# ---------------------------------------------------
# TEST MODE
# ---------------------------------------------------
if [[ $TEST_ONLY -eq 1 ]]; then
  log INFO "🚦 Test mode: verifying Rclone & config"
  if ! command -v rclone >/dev/null; then
    log INFO "Rclone not found. Installing..."
    curl https://rclone.org/install.sh | sudo bash
  else
    log INFO "Rclone is installed: $(rclone version | head -n1)"
  fi

  CONFIG="$HOME/.config/rclone/rclone.conf"
  if [[ -f "$CONFIG" ]]; then
    log INFO "Found rclone config at $CONFIG"
    rclone listremotes
  else
    log WARN "No rclone config found at $CONFIG"
  fi
  exit 0
fi

# ---------------------------------------------------
# FULL INTERACTIVE SETUP
# ---------------------------------------------------
log INFO "🛠️  Rclone Google Drive OAuth Setup"

require_cmd rclone
require_cmd mkdir
require_cmd nano

echo
read_default  "Remote name"              "gdrive-user"        REMOTE_NAME
read_required "Google OAuth Client ID"   CLIENT_ID
read_required "Google OAuth Client Secret" CLIENT_SECRET

echo
echo "❗ Paste the OAuth JSON blob you copied (single line):"
read_required "OAuth JSON" PASTED_JSON

echo
read_required "Drive folder (URL or ID)" RAW_FOLDER
FOLDER_ID="$(extract_folder_id "$RAW_FOLDER")"
log INFO "Using Drive folder ID: $FOLDER_ID"

# Write config
CONFIG_DIR="$HOME/.config/rclone"
CONFIG_FILE="$CONFIG_DIR/rclone.conf"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
[$REMOTE_NAME]
type = drive
client_id = $CLIENT_ID
client_secret = $CLIENT_SECRET
scope = drive.file
root_folder_id = $FOLDER_ID
token = $PASTED_JSON
EOF
log INFO "Config written to $CONFIG_FILE"

# Connectivity & test cycle
echo
log INFO "➤ Listing existing files in '$REMOTE_NAME:'"
rclone ls "$REMOTE_NAME:" || { log ERROR "List failed"; exit 1; }

TEST_LOCAL="/tmp/rclone_setup_test_$(date +%s).txt"
echo "rclone setup test $(date)" > "$TEST_LOCAL"
log INFO "Created local test file: $TEST_LOCAL"

TEST_REMOTE="rclone_setup_test_$(date +%s).txt"
log INFO "Uploading test file as '$TEST_REMOTE'..."
rclone copyto "$TEST_LOCAL" "$REMOTE_NAME:$TEST_REMOTE" || { log ERROR "Upload failed"; exit 1; }

log INFO "Confirming remote file..."
rclone ls "$REMOTE_NAME:" | grep -q "$TEST_REMOTE" || { log ERROR "Remote test not found"; exit 1; }

log INFO "Cleaning up test file..."
rclone delete "$REMOTE_NAME:$TEST_REMOTE" || log WARN "Could not delete remote test"
rm -f "$TEST_LOCAL"

echo
log INFO "✅ Setup & test complete! '$REMOTE_NAME' is bound to folder ID $FOLDER_ID."
