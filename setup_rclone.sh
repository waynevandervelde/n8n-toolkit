#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Logging (your function)
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
  if [[ $show -eq 0 ]]; then
    echo "[$level] $*"
  fi
}

# ------------------------------
# Helpers
# ------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERROR "Missing command: $1"; exit 1; }
}

# Sanitize/derive folder ID from input (URL or raw ID)
extract_folder_id() {
  local input="$1"
  # If it's a Drive folder URL, extract the ID; else return input as-is.
  if [[ "$input" =~ ^https?://[^/]+/drive/folders/([A-Za-z0-9_-]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$input"
  fi
}

read_default() {
  # read with default: read_default "Prompt" "default_value" varname
  local prompt="$1"
  local default="$2"
  local __outvar="$3"
  local reply
  read -r -p "$prompt [$default]: " reply || true
  if [[ -z "${reply:-}" ]]; then
    printf -v "$__outvar" "%s" "$default"
  else
    printf -v "$__outvar" "%s" "$reply"
  fi
}

# ------------------------------
# Pre-flight
# ------------------------------
log INFO "This will set up an rclone remote for Google Drive using a Service Account."

require_cmd rclone
require_cmd sed
require_cmd awk
# jq is optional for nicer JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  log WARN "jq is not installed. Falling back to basic parsing for service account email."
fi

# ------------------------------
# Inputs
# ------------------------------
REMOTE_NAME=""
SA_JSON=""
FOLDER_INPUT=""
ROOT_FOLDER_ID=""

read_default "Remote name" "gdrive-sa" REMOTE_NAME
read_default "Path to Service Account JSON" "/root/rclone-sa.json" SA_JSON

if [[ ! -f "$SA_JSON" ]]; then
  log ERROR "Service Account JSON not found at: $SA_JSON"
  log INFO "Make sure you uploaded the JSON file to the server. Example: scp rclone-sa.json user@server:/root/"
  exit 1
fi

# Extract service account email
if command -v jq >/dev/null 2>&1; then
  SA_EMAIL="$(jq -r '.client_email // empty' "$SA_JSON")"
else
  # crude fallback: try to parse email from JSON
  SA_EMAIL="$(grep -oE '"client_email"\s*:\s*"[^"]+"' "$SA_JSON" | sed -E 's/.*:\s*"([^"]+)".*/\1/')"
fi

if [[ -z "${SA_EMAIL:-}" ]]; then
  log WARN "Could not parse service account email from JSON."
else
  log INFO "Service Account email: $SA_EMAIL"
  log INFO "If your target folder is owned by another Google account, SHARE that folder with this email."
fi

echo
log INFO "OPTIONAL: Target a specific Google Drive folder (recommended)"
echo "- You can paste a folder URL (https://drive.google.com/drive/folders/XXXXXXXX) or just its ID"
echo "- Leave empty to use the Service Account's root drive"
read -r -p "Folder URL or ID (optional): " FOLDER_INPUT || true

ROOT_FOLDER_ID="$(extract_folder_id "${FOLDER_INPUT:-}")"
if [[ -n "$ROOT_FOLDER_ID" ]]; then
  log INFO "Using root_folder_id: $ROOT_FOLDER_ID"
else
  [[ -n "${FOLDER_INPUT:-}" ]] && log WARN "Could not parse a valid folder ID from input. Proceeding without root_folder_id."
fi

# ------------------------------
# Create / replace rclone remote
# ------------------------------
# If remote exists, offer to replace
if rclone config show | grep -q "^\[$REMOTE_NAME\]$"; then
  read -r -p "Remote '$REMOTE_NAME' already exists. Replace it? [y/N]: " yn || true
  yn="${yn:-N}"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    rclone config delete "$REMOTE_NAME" >/dev/null 2>&1 || true
  else
    log INFO "Keeping existing remote. Skipping creation."
  fi
fi

if ! rclone config show | grep -q "^\[$REMOTE_NAME\]$"; then
  log INFO "Creating rclone remote '$REMOTE_NAME'..."
  if [[ -n "$ROOT_FOLDER_ID" ]]; then
    rclone config create "$REMOTE_NAME" drive \
      scope=drive \
      service_account_file="$SA_JSON" \
      root_folder_id="$ROOT_FOLDER_ID" \
      --non-interactive >/dev/null
  else
    rclone config create "$REMOTE_NAME" drive \
      scope=drive \
      service_account_file="$SA_JSON" \
      --non-interactive >/dev/null
  fi
  log INFO "Remote '$REMOTE_NAME' created."
fi

# ------------------------------
# Connectivity tests
# ------------------------------
log INFO "Testing connection: listing folder..."
if ! rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
  log ERROR "Failed to list directory for ${REMOTE_NAME}:. Check sharing/permissions and folder ID."
  exit 1
fi
log INFO "List OK."

# Quick write probe: try to create an empty file in the target
log INFO "Probing write access..."
if ! rclone touch "${REMOTE_NAME}:__rclone_write_probe__.tmp" >/dev/null 2>&1; then
  log ERROR "Write probe failed. The Service Account likely has no write permission to this folder."
  log INFO "Fix: In Google Drive, share the folder with ${SA_EMAIL} as Editor (not Viewer), then re-run this script."
  exit 1
fi

# Clean up probe file
rclone delete "${REMOTE_NAME}:__rclone_write_probe__.tmp" >/dev/null 2>&1 || true

# Make a test file locally
TEST_NAME="rclone_setup_test_$(date +%s).txt"
TMP_FILE="$(mktemp)"
echo "rclone setup test $(date)" > "$TMP_FILE"

log INFO "Uploading test file (copy -> copyto -> rcat fallbacks): $TEST_NAME"

# 1) Try 'copy' to the remote root (works even if 'copyto' gets picky)
if rclone copy "$TMP_FILE" "${REMOTE_NAME}:" -vv; then
  log INFO "Upload via 'rclone copy' succeeded."
else
  log WARN "'rclone copy' failed. Trying 'copyto'..."
  # 2) Try copyto to a specific object path
  if rclone copyto "$TMP_FILE" "${REMOTE_NAME}:$TEST_NAME" -vv; then
    log INFO "Upload via 'rclone copyto' succeeded."
  else
    log WARN "'rclone copyto' failed. Trying 'rcat'..."
    # 3) Last resort: stream the content via rcat
    if echo "rclone setup test $(date)" | rclone rcat "${REMOTE_NAME}:$TEST_NAME" -vv; then
      log INFO "Upload via 'rclone rcat' succeeded."
    else
      log ERROR "All upload methods failed. See the verbose logs above for the exact error."
      rm -f "$TMP_FILE"
      exit 1
    fi
  fi
fi

rm -f "$TMP_FILE"

log INFO "Listing contents to verify..."
rclone ls "${REMOTE_NAME}:" | awk '{print "[INFO] " $0}'

log INFO "Removing test file..."
if ! rclone delete "${REMOTE_NAME}:$TEST_NAME" >/dev/null 2>&1; then
  log WARN "Could not delete test file. You can remove it manually later."
else
  log INFO "Test file removed."
fi

log INFO "rclone remote '$REMOTE_NAME' is ready to use."
if [[ -n "$ROOT_FOLDER_ID" ]]; then
  log INFO "All operations will target the folder with ID: $ROOT_FOLDER_ID"
else
  log INFO "No folder ID set; operations will use the Service Account's root drive."
fi
