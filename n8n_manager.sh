#!/bin/bash
set -euo pipefail
set -o errtrace
IFS=$'\n\t'

#############################################################################################
# N8N Installation & Management Script
# Author: TheNguyen
# Email: thenguyen.ai.automation@gmail.com
# Version: 1.1.0
# Date: 2025-08-16
#
# Description:
#   A unified management tool for installing, upgrading, listing versions, and cleaning up
#   the n8n automation stack running on Docker Compose with Traefik + Let's Encrypt.
#
# Key features:
#   - Validates domain DNS resolution
#   - Installs Docker & Compose v2 if missing
#   - Creates persistent Docker volumes
#   - Starts stack and checks container health + TLS certificate (Traefik/LE)
#   - Forces upgrade/downgrade with -f
#   - Cleanup all containers, volumes, and network
#   - Verbose logging with selectable log levels (DEBUG, INFO, WARN, ERROR) + timestamps
#   - Troubleshooting-friendly: fails with function + line context
#############################################################################################

# Load common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/n8n_common.sh"

trap 'on_interrupt' INT TERM HUP
trap 'log INFO "Exiting (code $?)"' EXIT
trap 'on_error' ERR

# ------------------------------- Globals -------------------------------------
INSTALL=false
UPGRADE=false
CLEANUP=false
LIST_VERSIONS=false
FORCE_UPGRADE=false
LOG_LEVEL="INFO"
TARGET_DIR=""
N8N_VERSION="latest"
DOMAIN=""
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")
################################################################################
# usage()
#   Displays script usage/help information when incorrect or no arguments are passed
################################################################################
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -a, --available
        List available n8n versions
        * If n8n is running → show all newer versions than current
        * If n8n is not running → show top 5 latest versions

  -i, --install <DOMAIN>
        Install n8n stack with specified domain
        Use -v|--version to specify a version

  -u, --upgrade <DOMAIN>
        Upgrade n8n stack with specified domain
        Use -f|--force to force upgrade/downgrade
        Use -v|--version to specify a version

  -v, --version <N8N_VERSION>
        Install/upgrade with a specific n8n version. If omitted/empty, uses latest-stable

  -m, --email <SSL_EMAIL>
        Email address for Let's Encrypt SSL certificate

  -c, --cleanup
        Cleanup all containers, volumes, and network

  -d, --dir <TARGET_DIR>
        /path/to/n8n: your n8n project directory (default: /home/n8n)

  -l, --log-level <LEVEL>
        Set log level: DEBUG, INFO (default), WARN, ERROR

  -h, --help
        Show script usage

Examples:
  $0 -a
      # List available versions

  $0 -i n8n.YourDomain.com -m you@YourDomain.com
      # Install the latest n8n version

  $0 -i n8n.YourDomain.com -m you@YourDomain.com -v 1.105.3
      # Install a specific n8n version

  $0 -i n8n.YourDomain.com -m you@YourDomain.com -d /path/to/n8n
      # Install the latest n8n version to a specific target directory

  $0 -u n8n.YourDomain.com
      # Upgrade to the latest n8n version

  $0 -u n8n.YourDomain.com -f -v 1.107.2
      # Upgrade to a specific n8n version

  $0 -c
      # Cleanup everything
EOF
    exit 1
}

################################################################################
# check_domain()
# Description:
#   Verify the provided DOMAIN’s A record points to this server’s public IP.
#
# Behaviors:
#   - Detects server IP via api.ipify.org.
#   - Resolves DOMAIN with `dig` (preferred) or `getent`; logs resolved IPs.
#   - If no resolver present → warns and continues (cannot verify).
#   - If resolved IPs include server IP → logs success.
#   - Else logs error and terminates installation/upgrade flow.
#
# Returns:
#   0 on success/skip (no resolver); exits 1 on mismatch.
################################################################################
check_domain() {
    local server_ip domain_ips resolver=""
    server_ip=$(curl -s https://api.ipify.org || echo "Unavailable")
    # Resolve A records using whichever tool is present
    if command -v dig >/dev/null 2>&1; then
        resolver="dig"
        domain_ips=$(dig +short A "$DOMAIN" | tr '\n' ' ')
    elif command -v getent >/dev/null 2>&1; then
        resolver="getent"
        domain_ips=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')
    else
        log WARN "Neither 'dig' nor 'getent' found; DNS check will be skipped."
        domain_ips=""
    fi

    log INFO "Your server's public IP is: $server_ip"
    [[ -n "$resolver" ]] && log INFO "Domain $DOMAIN resolves to (via $resolver): $domain_ips"

    if [[ -z "$resolver" ]]; then
        log WARN "Cannot verify DNS -> continuing, but Let's Encrypt may fail if DNS is wrong."
        return 0
    fi

    if echo "$domain_ips" | tr ' ' '\n' | grep -Fxq "$server_ip"; then
        log INFO "Domain $DOMAIN is correctly pointing to this server."
    else
        log ERROR "Domain $DOMAIN is NOT pointing to this server."
        log INFO  "Please update your DNS A record to: $server_ip"
        exit 1
    fi
}

################################################################################
# get_user_email()
# Description:
#   Prompt the operator for a valid email used for Let's Encrypt registration.
#
# Behaviors:
#   - Re-prompts until input matches a simple RFC-ish email regex.
#   - Exports SSL_EMAIL on success.
#
# Returns:
#   0 after a valid email is captured (exported).
################################################################################
get_user_email() {
    while true; do
        read -e -p "Enter your email address (used for SSL cert): " SSL_EMAIL
        if [[ "$SSL_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            export SSL_EMAIL
            break
        else
            log ERROR "Invalid email. Please try again."
        fi
    done
}

################################################################################
# list_available_versions()
# Description:
#   Context-aware listing of n8n versions available on Docker Hub.
#
# Behaviors:
#   - Detects current running version (if any).
#   - If running: prints versions newer than the current one (ascending).
#   - If not running: prints top 5 latest stable versions.
#   - Uses fetch_all_stable_versions() as the source of truth.
#
# Returns:
#   0 on success; 1 if versions could not be fetched.
################################################################################
list_available_versions() {
    # Make sure jq exists even if user calls -a before install
    if ! command -v jq >/dev/null 2>&1; then
        log INFO "jq not found; installing..."
        yum update -y && yum install -y jq
    fi

    local current_version
    current_version="$(get_current_n8n_version 2>/dev/null || true)"

    # Only treat as "running" if current_version looks like x.y.z
    local has_running=false
    if [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        has_running=true
    fi

    log INFO "Fetching tags from Docker Hub…"
    local all_versions
    all_versions="$(fetch_all_stable_versions)"

    if [[ -z "$all_versions" ]]; then
        log ERROR "Could not fetch version list."
        return 1
    fi

    if $has_running; then
        log INFO "Current n8n version detected: $current_version"
        echo "═════════════════════════════════════════════════════════════"
        # Build a list of all versions newer than current_version (ascending)
        # Trick: append current, sort -V, then print lines after current
        local newer
        newer="$(printf "%s\n%s\n" "$all_versions" "$current_version" \
                 | sort -V \
                 | awk -v c="$current_version" '
                        $0==c { seen=1; next }
                        seen  { print }')"
        if [[ -z "$newer" ]]; then
            echo "You are already on the latest detected version ($current_version)."
        else
            echo "Newer n8n versions available than $current_version:"
            echo "$newer"
        fi
        echo "═════════════════════════════════════════════════════════════"
    else
        # No running n8n detected → show top 5 latest
        local top5
        top5="$(printf "%s\n" "$all_versions" | tail -n 5)"
        echo "═════════════════════════════════════════════════════════════"
        echo "Top 5 latest stable n8n versions (no running version detected):"
        echo "$top5"
        echo "═════════════════════════════════════════════════════════════"
    fi
}

################################################################################
# validate_image_tag()
# Description:
#   Check whether a given n8n image tag exists in docker.n8n.io or docker.io.
#
# Behaviors:
#   - Tries `docker manifest inspect` against both registries.
#   - Logs an INFO line about the tag being validated.
#
# Returns:
#   0 if the tag exists in either registry; 1 otherwise.
################################################################################
validate_image_tag() {
    local tag="$1"
    log INFO "Validate if n8n version '$tag' is available in Docker Hub."
    if docker manifest inspect "docker.n8n.io/n8nio/n8n:${tag}" >/dev/null 2>&1; then return 0; fi
    if docker manifest inspect "docker.io/n8nio/n8n:${tag}"  >/dev/null 2>&1; then return 0; fi
    return 1
}

################################################################################
# create_volumes()
# Description:
#   Ensure required named Docker volumes exist for the stack.
#
# Behaviors:
#   - For each volume in VOLUMES: create if missing; log if present.
#   - Prints `docker volume ls` at the end for visibility.
#
# Returns:
#   0 always (best-effort creation/logging).
################################################################################
create_volumes() {
    log INFO "Creating Docker volumes..."
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            log INFO "Volume '$vol' already exists."
        else
            docker volume create "$vol" >/dev/null && log INFO "Created volume: $vol"
        fi
    done

    log INFO "Current Docker volumes:"
    docker volume ls
}

################################################################################
# prepare_compose_file()
# Description:
#   Populate $N8N_DIR with docker-compose.yml and .env, pin desired version,
#   and rotate secrets if missing/default.
#
# Behaviors:
#   - Copies templates from $PWD to $N8N_DIR (backing up existing as *.bak.TIMESTAMP).
#   - Sets DOMAIN, SSL_EMAIL (if provided) in .env.
#   - Resolves target n8n version: explicit -v or latest stable via get_latest_n8n_version().
#   - Validates tag with validate_image_tag(); writes N8N_IMAGE_TAG in .env.
#   - Rotates STRONG_PASSWORD (base64 16) if missing/default.
#   - Rotates N8N_ENCRYPTION_KEY (base64 32) if missing/default.
#   - Hardens permissions: .env (600), docker-compose.yml (640).
#
# Returns:
#   0 on success; exits non-zero on missing templates or invalid tag.
################################################################################
prepare_compose_file() {
    # Copy docker-compose and .env template to the target dir
    local compose_template="$PWD/docker-compose.yml"
    local env_template="$PWD/.env"
    local compose_file="$COMPOSE_FILE"
    local env_file="$ENV_FILE"

    if [[ ! -f "$compose_template" ]]; then
        log ERROR "docker-compose.yml not found at $compose_template"
        exit 1
    fi

    if [[ ! -f "$env_template" ]]; then
        log ERROR ".env file not found at $env_template"
        exit 1
    fi
    
    # Copy compose & env templates when source/target differ; back up if overwriting
    if [[ "$compose_template" != "$compose_file" ]]; then
        if [[ -f "$compose_file" ]]; then
            cp -a "$compose_file" "${compose_file}.bak.$(date +%F_%H-%M-%S)"
            log WARN "Existing docker-compose.yml backed up to ${compose_file}.bak.*"
        fi
        cp -a "$compose_template" "$compose_file"
    fi
    
    if [[ "$env_template" != "$env_file" ]]; then
        if [[ -f "$env_file" ]]; then
            cp -a "$env_file" "${env_file}.bak.$(date +%F_%H-%M-%S)"
            log WARN "Existing .env backed up to ${env_file}.bak.*"
        fi
        cp -a "$env_template" "$env_file"
    fi

    log INFO "Updating .env with DOMAIN, SSL_EMAIL and N8N_IMAGE_TAG…"
    upsert_env_var "DOMAIN" "$DOMAIN" "$env_file"
    [[ -n "${SSL_EMAIL:-}" ]] && upsert_env_var "SSL_EMAIL" "$SSL_EMAIL" "$env_file"


    # Resolve target version: explicit -v wins; else latest stable
    local target_version="${N8N_VERSION}"
    if [[ -z "$target_version" || "$target_version" == "latest" ]]; then
        target_version="$(get_latest_n8n_version)"
        [[ -z "$target_version" ]] && { log ERROR "Could not determine latest n8n tag."; exit 1; }
    fi

    validate_image_tag "$target_version" || {
        log ERROR "Image tag not found on docker.n8n.io or docker.io: $target_version"
        exit 1
    }

    # Pin the tag into .env (insert or update)
    log INFO "Installing n8n version: $target_version"
    log INFO "Updating .env with N8N_IMAGE_TAG=$target_version"
    upsert_env_var "N8N_IMAGE_TAG" "$target_version" "$env_file"

    # Rotate STRONG_PASSWORD if missing/default
    local password_line
    password_line=$(awk -F= '/^STRONG_PASSWORD=/{print $2; found=1} END{if(!found) print ""}' "$env_file")
    if [[ "$password_line" == "CHANGE_ME_BASE64_16_BYTES" || -z "$password_line" ]]; then
        local new_password
        new_password="$(openssl rand -base64 16)"
        log INFO "Setting STRONG_PASSWORD in .env"
        upsert_env_var "STRONG_PASSWORD" "${new_password}" "$env_file"
    else
        log INFO "Existing STRONG_PASSWORD found. Not modifying it."
    fi

    # Rotate N8N_ENCRYPTION_KEY if missing/default
    local enc_key_line
    enc_key_line=$(awk -F= '/^N8N_ENCRYPTION_KEY=/{print $2; found=1} END{if(!found) print ""}' "$env_file")
    if [[ -z "$enc_key_line" || "$enc_key_line" == "CHANGE_ME_BASE64_32_BYTES" ]]; then
        local new_key
        new_key="$(openssl rand -base64 32)"
        log INFO "Setting N8N_ENCRYPTION_KEY in .env"
        upsert_env_var "N8N_ENCRYPTION_KEY" "${new_key}" "$env_file"
    else
        log INFO "Existing N8N_ENCRYPTION_KEY found. Not modifying it."
    fi

    # Secure secrets file
    chmod 600 "$env_file" 2>/dev/null || true
    chmod 640 "$compose_file" 2>/dev/null || true
}

################################################################################
# install_docker()
# Description:
#   Install Docker Engine and Compose v2 on Ubuntu with safe fallbacks.
#
# Behaviors:
#   - If Docker present → skip install.
#   - Else add Docker apt repo & key, install engine + compose plugin.
#   - Fallback to get.docker.com script if apt install fails.
#   - Installs common dependencies (jq, rsync, tar, msmtp, rclone, dnsutils, openssl, etc.).
#   - Enables & starts docker via systemd if available.
#   - Adds invoking user to docker group.
#
# Returns:
#   0 on success (best-effort with fallbacks).
################################################################################
install_docker() {
    if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        log INFO "Docker already installed. Skipping Docker install."
    else
        log INFO "Installing Docker Engine and Docker Compose v2..."
        if ! yum install -y docker; then
            log WARN "YUM install from Docker repo failed. Falling back to official convenience script..."
            curl -fsSL https://get.docker.com | sh
        fi
    fi
    log INFO "Installing required dependencies..."
    yum install -y \
    jq \
    vim \
    rsync \
    tar \
    msmtp \
    rclone \
    dnsutils \
    openssl

    # Make sure the daemon is running/enabled
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker || true
    fi

    CURRENT_USER=${SUDO_USER:-$(whoami)}
    log INFO "Adding user '$CURRENT_USER' to the docker group..."
    usermod -aG docker "$CURRENT_USER"

    log INFO "Docker and Docker Compose installed successfully."
}

################################################################################
# print_summary_message()
# Description:
#   Print a human-friendly final summary after install/upgrade.
#
# Behaviors:
#   - Loads .env for current context.
#   - Prints domain URL, detected n8n version, timestamp, user, target dir,
#     SSL email (if set), and log file path.
#
# Returns:
#   0 always.
################################################################################
print_summary_message() {
    load_env_file
    echo "═════════════════════════════════════════════════════════════"
    if [[ "$INSTALL" == true ]]; then
        echo "N8N has been successfully installed!"
    elif [[ "$UPGRADE" == true ]]; then
        echo "N8N has been successfully upgraded!"
    fi
    echo "Domain:             https://${DOMAIN}"
    echo "Installed Version:  $(get_current_n8n_version)"
    echo "Install Timestamp:  $(date "+%Y-%m-%d %H:%M:%S")"
    echo "Installed By:       ${USER:-unknown}"
    echo "Target Directory:   $N8N_DIR"
    echo "SSL Email:          ${SSL_EMAIL:-N/A}"
    echo "Execution log:      ${LOG_FILE}"
    echo "═════════════════════════════════════════════════════════════"
}

################################################################################
# install_n8n()
# Description:
#   Orchestrate a fresh installation of the n8n stack behind Traefik/LE.
#
# Behaviors:
#   - Prompts for SSL_EMAIL if missing.
#   - Verifies DOMAIN DNS points to this host (check_domain()).
#   - Installs Docker/Compose and dependencies (install_docker()).
#   - Prepares compose + .env with pinned version and secrets (prepare_compose_file()).
#   - Validates compose/env (validate_compose_and_env()).
#   - Creates named volumes (create_volumes()).
#   - Starts stack (docker_compose_up()).
#   - Waits for containers and TLS to be healthy (check_services_up_running()).
#   - Prints a summary on success.
#
# Returns:
#   0 on success; exits non-zero if any step fails.
################################################################################
install_n8n() {
    log INFO "Starting N8N installation for domain: $DOMAIN"
    [[ -z "${SSL_EMAIL:-}" ]] && get_user_email
    check_domain
    install_docker
    prepare_compose_file
    validate_compose_and_env
    create_volumes
    docker_compose_up
    check_services_up_running || { log ERROR "Stack unhealthy after install."; exit 1; }
    print_summary_message
}

################################################################################
# upgrade_n8n()
# Description:
#   Upgrade (or force re-deploy/downgrade with -f) the running n8n stack.
#
# Behaviors:
#   - Detects current n8n version; resolves target:
#       * explicit -v, else latest stable via get_latest_n8n_version()
#   - Prevents downgrades unless --force; prevents no-op redeploy unless --force.
#   - Validates target tag with validate_image_tag().
#   - Writes N8N_IMAGE_TAG to .env; brings stack down (compose down).
#   - Re-validates compose/env; brings stack up; waits for health & TLS.
#   - Prints a summary on success.
#
# Returns:
#   0 on success; exits non-zero on validation/health failures.
################################################################################
upgrade_n8n() {
    log INFO "Checking current and latest n8n versions..."
    cd "$N8N_DIR"
    load_env_file

    # Make sure jq is available for tag lookups
    if ! command -v jq >/dev/null 2>&1; then
        yum update -y && yum install -y jq
    fi

    local current_version target_version
    current_version=$(get_current_n8n_version || echo "0.0.0")
    # Decide target version
    target_version="$N8N_VERSION"
    if [[ -z "$target_version" || "$target_version" == "latest" ]]; then
        target_version=$(get_latest_n8n_version)
        [[ -z "$target_version" ]] && { log ERROR "Could not determine latest n8n tag."; exit 1; }
    fi

    log INFO "Current version: $current_version  ->  Target version: $target_version"

    # Refuse to downgrade unless -f
    if [[ "$(printf "%s\n%s" "$target_version" "$current_version" | sort -V | head -n1)" == "$target_version" \
          && "$target_version" != "$current_version" \
          && "$FORCE_UPGRADE" != true ]]; then
        log INFO "Target ($target_version) <= current ($current_version). Use -f to force downgrade."
        exit 0
    fi

    # If same version, allow redeploy only with -f
    if [[ "$target_version" == "$current_version" && "$FORCE_UPGRADE" != true ]]; then
        log INFO "Already on $current_version. Use -f to force redeploy."
        exit 0
    fi

    # Validate tag exists (either registry)
    validate_image_tag "$target_version" || { log ERROR "Image tag not found: $target_version"; exit 1; }

    # Pin the tag into .env (insert or update)
    upsert_env_var "N8N_IMAGE_TAG" "$target_version" "$N8N_DIR/.env"

    log INFO "Stopping and removing existing containers..."
    compose down

    validate_compose_and_env
    docker_compose_up
    check_services_up_running || { log ERROR "Stack unhealthy after upgrade."; exit 1; }
    print_summary_message
}

################################################################################
# cleanup_n8n()
# Description:
#   Interactively tear down the stack and remove named resources.
#
# Behaviors:
#   - Prints a plan and asks for confirmation.
#   - Runs `compose down --remove-orphans`.
#   - Removes named volumes in VOLUMES; respects KEEP_CERTS=true for letsencrypt.
#   - Prunes dangling images; optionally removes base images if REMOVE_IMAGES=true.
#   - Logs completion and whether certs were preserved.
#
# Returns:
#   0 on completion; 0 if user cancels; non-zero only on unexpected errors.
################################################################################
cleanup_n8n() {
    # Settings (can be overridden via env)
    local NETWORK_NAME="${NETWORK_NAME:-n8n-network}"
    local KEEP_CERTS="${KEEP_CERTS:-true}"
    local REMOVE_IMAGES="${REMOVE_IMAGES:-false}"

    log WARN "This will stop containers, remove the compose stack, and delete named resources."
    echo "Planned actions:"
    echo "  - docker compose down --remove-orphans -v"
    echo "  - Remove external volumes: ${VLIST[*]}  (letsencrypt kept: ${KEEP_CERTS})"
    echo "  - Remove docker network: ${NETWORK_NAME}"
    echo "  - Remove dangling images (docker image prune -f)"
    echo "  - Remove base images (n8nio/n8n, postgres) : ${REMOVE_IMAGES}"
    echo

    read -e -p "Continue? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { log INFO "Cleanup cancelled."; return 0; }
    
    log INFO "Shutting down stack and removing orphans + anonymous volumes..."
    if [[ -f "$N8N_DIR/docker-compose.yml" ]]; then
        compose down --remove-orphans || true
    else
        log WARN "docker-compose.yml not found at \$N8N_DIR; attempting plain 'docker compose down' in $PWD."
        docker compose down --remove-orphans || true
    fi

    log INFO "Removing related volumes..."
    for vol in "${VOLUMES[@]}"; do
        if [[ "$KEEP_CERTS" == "true" && "$vol" == "letsencrypt" ]]; then
            log INFO "Skipping volume '$vol' (KEEP_CERTS=true)"
            continue
        fi
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            if docker volume rm "$vol" >/dev/null 2>&1; then
                log INFO "Removed volume: $vol"
            else
                log WARN "Could not remove volume '$vol' (in use?)."
            fi
        else
            log INFO "Volume '$vol' not found; skipping."
        fi
    done

    log INFO "Pruning dangling images…"
    docker image prune -f >/dev/null 2>&1 || true
    if [[ "$REMOVE_IMAGES" == "true" ]]; then
        log WARN "Removing base images: n8nio/n8n and postgres (explicit request)"
        docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
          | grep -E '^(n8nio/n8n|docker\.n8n\.io/n8nio/n8n|postgres):' \
          | awk '{print $2}' \
          | xargs -r docker rmi -f || true
    fi

    log INFO "Cleanup completed."
    [[ "$KEEP_CERTS" == "true" ]] && log INFO "Note: kept 'letsencrypt' volume (certs preserved). Set KEEP_CERTS=false to reset TLS."
}

################################################################################
# Arg parsing
################################################################################
# Define short/long specs
SHORT="i:u:v:m:fcad:l:h"
LONG="install:,upgrade:,version:,email:,force,cleanup,available,dir:,log-level:,help"

# Parse
PARSED=$(getopt --options="$SHORT" --longoptions="$LONG" --name "$0" -- "$@") || usage
eval set -- "$PARSED"

while true; do
    case "$1" in
        -i|--install)
            INSTALL=true
            DOMAIN="$(parse_domain_arg "$2")"
            shift 2
            ;;
        -u|--upgrade)
            UPGRADE=true
            DOMAIN="$(parse_domain_arg "$2")"
            shift 2
            ;;
        -v|--version)
            N8N_VERSION="$2"
            shift 2
            ;;
        -m|--email)
            SSL_EMAIL="$2"
            shift 2
            ;;
        -f|--force)
            FORCE_UPGRADE=true
            shift
            ;;
        -c|--cleanup)
            CLEANUP=true
            shift
            ;;
        -a|--available)
            LIST_VERSIONS=true
            shift
            ;;
        -d|--dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        -l|--log-level)
            LOG_LEVEL="${2^^}"
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

# === Post-parse validations ===================================================
_actions=0
$INSTALL && _actions=$((_actions+1))
$UPGRADE && _actions=$((_actions+1))
$CLEANUP && _actions=$((_actions+1))
$LIST_VERSIONS && _actions=$((_actions+1))

if (( _actions == 0 )); then
    log ERROR "No action specified. Use one of: -i/--install, -u/--upgrade, -c/--cleanup, -a/--available"
    usage
fi

if (( _actions > 1 )); then
    log ERROR "Choose exactly one action (not multiple): -i/--install, -u/--upgrade, -c/--cleanup, or -a/--available"
    usage
fi

# Require DOMAIN for install/upgrade
if $INSTALL || $UPGRADE; then
    if [[ -z "${DOMAIN:-}" ]]; then
        log ERROR "Domain is required for $( $INSTALL && echo install || echo upgrade ). Provide with -i <DOMAIN> or -u <DOMAIN>."
        exit 2
    fi
fi

################################################################################
# Main()
################################################################################
check_root || { log ERROR "Please run as root (needed to read Docker volumes)."; exit 1; }
DEFAULT_N8N_DIR="/home/n8n"
mkdir -p "$DEFAULT_N8N_DIR"
N8N_DIR="${TARGET_DIR:-$DEFAULT_N8N_DIR}"

ENV_FILE="$N8N_DIR/.env"
COMPOSE_FILE="$N8N_DIR/docker-compose.yml"

mkdir -p "$N8N_DIR/logs"
LOG_FILE="$N8N_DIR/logs/n8n_manager.log"

exec > >(tee "$LOG_FILE") 2>&1
log INFO "Logging to $LOG_FILE"
log INFO "Working on directory: $N8N_DIR"
N8N_VERSION="${N8N_VERSION:-latest}"

if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER":"$SUDO_USER" "$N8N_DIR"
fi

if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
    export PS4='+ $(date "+%H:%M:%S") ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
    set -x
fi

# Execute selected action
if [[ $INSTALL == true ]]; then
    install_n8n
elif [[ $UPGRADE == true ]]; then
    upgrade_n8n
elif [[ $CLEANUP == true ]]; then
    cleanup_n8n
elif [[ $LIST_VERSIONS == true ]]; then
    list_available_versions
else
    usage
fi
