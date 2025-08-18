#!/usr/bin/env bash
set -euo pipefail

################################################################################
# setup_rclone.sh
# Author: TheNguyen (refactor)
# Purpose: One-stop safe setup of rclone → Google Drive (OAuth or Service Account)
# Version: 2.0.0
################################################################################

LOG_LEVEL="${LOG_LEVEL:-INFO}"
REMOTE_NAME="gdrive-user"
SCOPE="drive.file"
FOLDER_ID=""
TEAM_DRIVE_ID=""
CLIENT_ID=""
CLIENT_SECRET=""
SERVICE_ACCOUNT_FILE=""
HEADLESS=0
TEST_ONLY=0
AUTO_INSTALL=0

log() {
    local level="$1"; shift
    local show=1
    case "$LOG_LEVEL" in
        DEBUG) show=0 ;;
        INFO)  [[ "$level" != "DEBUG" ]] && show=0 ;;
        WARN)  [[ "$level" =~ ^(WARN|ERROR)$ ]] && show=0 ;;
        ERROR) [[ "$level" == "ERROR" ]] && show=0 ;;
    esac
    [[ $show -eq 0 ]] && printf "[%s] %s\n" "$level" "$*"
}

die() {
    log ERROR "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

maybe_install_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        return
    fi
    if [[ $AUTO_INSTALL -eq 1 ]]; then
        log INFO "rclone not found. Installing…"
        curl -fsSL https://rclone.org/install.sh | sudo bash
    else
        die "rclone not found. Re-run with --auto-install to install automatically."
    fi
}

read_required() {
    local prompt="$1" __outvar="$2" reply
    while :; do
        read -e -rp "$prompt: " reply || true
        [[ -n "$reply" ]] && break
        echo "  → This value is required."
    done
    printf -v "$__outvar" "%s" "$reply"
}

read_default() {
    local prompt="$1" default="$2" __outvar="$3" reply
    read -e -rp "$prompt [$default]: " reply || true
    [[ -z "$reply" ]] && reply="$default"
    printf -v "$__outvar" "%s" "$reply"
}

extract_folder_id() {
    local input="${1%/}"
    if [[ "$input" =~ ([A-Za-z0-9_-]{20,}) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$input"
    fi
}

conf_path() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/rclone"
    mkdir -p "$dir"
    echo "$dir/rclone.conf"
}

ensure_secure_perms() {
    local f; f="$(conf_path)"
    [[ -f "$f" ]] && chmod 600 "$f"
}

usage() {
    cat <<EOF
setup_rclone.sh — Safe, interactive rclone→Google Drive setup

USAGE:
    $(basename "$0") [options]

OPTIONS:
    -t, --test-only           Only verify rclone + list remotes (no changes)
        --remote NAME         Remote name (default: gdrive-user)
        --scope SCOPE         drive | drive.file (default: drive.file)
        --folder ID|URL       Root folder ID or URL
        --team-drive ID       Shared Drive ID
        --client-id ID        Google OAuth client_id
        --client-secret SEC   Google OAuth client_secret
        --headless            Use rclone authorize flow explicitly
        --sa                  Configure using a Service Account JSON file
        --sa-file PATH        Path to service account JSON
        --auto-install        Install rclone if missing
    -h, --help                Show help
EOF
}

# ---------------------------------------------------
# Parse arguments
# ---------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--test-only) TEST_ONLY=1 ;;
        --remote) REMOTE_NAME="$2"; shift ;;
        --scope) SCOPE="$2"; shift ;;
        --folder) FOLDER_ID="$(extract_folder_id "$2")"; shift ;;
        --team-drive) TEAM_DRIVE_ID="$2"; shift ;;
        --client-id) CLIENT_ID="$2"; shift ;;
        --client-secret) CLIENT_SECRET="$2"; shift ;;
        --headless) HEADLESS=1 ;;
        --sa) SERVICE_ACCOUNT_FILE="ask" ;;
        --sa-file) SERVICE_ACCOUNT_FILE="$2"; shift ;;
        --auto-install) AUTO_INSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

# ---------------------------------------------------
# Test mode
# ---------------------------------------------------
if [[ $TEST_ONLY -eq 1 ]]; then
    maybe_install_rclone
    log INFO "🚦 Test mode: verifying rclone & config"
    if command -v rclone >/dev/null; then
        log INFO "rclone is installed: $(rclone version | head -n1)"
    fi
    CONFIG="$(conf_path)"
    if [[ -f "$CONFIG" ]]; then
        log INFO "Found rclone config at $CONFIG"
        rclone listremotes
    else
        log WARN "No rclone config found at $CONFIG"
    fi
    exit 0
fi

# ---------------------------------------------------
# Full interactive setup
# ---------------------------------------------------
maybe_install_rclone
require_cmd rclone

CONFIG_FILE="$(conf_path)"

if [[ "$SERVICE_ACCOUNT_FILE" == "ask" ]]; then
    read_required "Path to service account JSON" SERVICE_ACCOUNT_FILE
fi

if [[ -n "$SERVICE_ACCOUNT_FILE" ]]; then
    # --- Service account mode ---
    [[ -f "$SERVICE_ACCOUNT_FILE" ]] || die "File not found: $SERVICE_ACCOUNT_FILE"
    read_default "Remote name" "$REMOTE_NAME" REMOTE_NAME
    if [[ -z "$FOLDER_ID" ]]; then
        read_required "Google Drive folder ID/URL" RAW_FOLDER
        FOLDER_ID="$(extract_folder_id "$RAW_FOLDER")"
    fi
    cat >"$CONFIG_FILE" <<EOF
[$REMOTE_NAME]
type = drive
scope = $SCOPE
service_account_file = $SERVICE_ACCOUNT_FILE
root_folder_id = $FOLDER_ID
EOF
    [[ -n "$TEAM_DRIVE_ID" ]] && echo "team_drive = $TEAM_DRIVE_ID" >>"$CONFIG_FILE"
    ensure_secure_perms
    log INFO "✅ Service account remote '$REMOTE_NAME' configured."
else
    # --- OAuth mode ---
    read_default "Remote name" "$REMOTE_NAME" REMOTE_NAME
    [[ -z "$CLIENT_ID" ]] && read_required "Google OAuth Client ID" CLIENT_ID
    [[ -z "$CLIENT_SECRET" ]] && read_required "Google OAuth Client Secret" CLIENT_SECRET
    if [[ -z "$FOLDER_ID" ]]; then
        read_required "Google Drive folder ID/URL" RAW_FOLDER
        FOLDER_ID="$(extract_folder_id "$RAW_FOLDER")"
    fi
    log INFO "Starting rclone OAuth flow..."
    if [[ $HEADLESS -eq 1 ]]; then
        rclone authorize "drive" --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET"
        echo "Paste the returned JSON token:"
        read_required "OAuth token JSON" TOKEN_JSON
    else
        TOKEN_JSON="$(rclone config create "$REMOTE_NAME" drive \
            client_id "$CLIENT_ID" client_secret "$CLIENT_SECRET" scope "$SCOPE" \
            root_folder_id "$FOLDER_ID" --obscure --non-interactive 2>/dev/null \
            || true)"
        if [[ -z "$TOKEN_JSON" ]]; then
            echo "Paste the JSON token you copied from browser:"
            read_required "OAuth token JSON" TOKEN_JSON
        fi
    fi
    cat >"$CONFIG_FILE" <<EOF
[$REMOTE_NAME]
type = drive
client_id = $CLIENT_ID
client_secret = $CLIENT_SECRET
scope = $SCOPE
root_folder_id = $FOLDER_ID
token = $TOKEN_JSON
EOF
    [[ -n "$TEAM_DRIVE_ID" ]] && echo "team_drive = $TEAM_DRIVE_ID" >>"$CONFIG_FILE"
    ensure_secure_perms
    log INFO "✅ OAuth remote '$REMOTE_NAME' configured."
fi

# ---------------------------------------------------
# Smoke test
# ---------------------------------------------------
log INFO "Testing remote connectivity..."
rclone ls "$REMOTE_NAME:" >/dev/null 2>&1 || die "rclone ls failed"

TEST_LOCAL="/tmp/rclone_test_$(date +%s).txt"
TEST_REMOTE="rclone_test_$(date +%s).txt"
echo "rclone setup test $(date)" > "$TEST_LOCAL"

rclone copyto "$TEST_LOCAL" "$REMOTE_NAME:$TEST_REMOTE" || die "Upload failed"
if rclone ls "$REMOTE_NAME:" | grep -q "$TEST_REMOTE"; then
    log INFO "Test upload succeeded."
    rclone delete "$REMOTE_NAME:$TEST_REMOTE" || log WARN "Could not delete remote test"
else
    die "Test upload failed."
fi
rm -f "$TEST_LOCAL"

log INFO "✅ Setup complete. Remote '$REMOTE_NAME' ready."
