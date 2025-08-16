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
        Target install directory (default: \$PWD)

  -l, --log-level <LEVEL>
        Set log level: DEBUG, INFO (default), WARN, ERROR

  -h, --help
        Show script usage

Examples:
  $0 -a
      # List available versions

  $0 -i n8n.YourDomain.com -m you@YourDomain.com -d /home/n8n
      # Install the latest n8n version

  $0 -i n8n.YourDomain.com -m you@YourDomain.com -v 1.105.3 -d /home/n8n
      # Install a specific n8n version

  $0 -u n8n.YourDomain.com -d /home/n8n
      # Upgrade to the latest n8n version

  $0 -u n8n.YourDomain.com -f -v 1.107.2 -d /home/n8n
      # Upgrade to a specific n8n version

  $0 -c
      # Cleanup everything
EOF
    exit 1
}

################################################################################
# check_domain()
#   Verifies that provided $DOMAIN’s A record matches this server’s public IP.
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
#   Prompts for a valid email (RFC-ish regex) for Let's Encrypt usage.
#   Exports SSL_EMAIL on success.
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
#   Context-aware version listing:
#     - If n8n is detected, prints only versions newer than current.
#     - Otherwise, prints the top 5 latest stable versions.
################################################################################
list_available_versions() {
    # Make sure jq exists even if user calls -a before install
    if ! command -v jq >/dev/null 2>&1; then
        log INFO "jq not found; installing..."
        apt-get update -y && apt-get install -y --no-install-recommends jq
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
# validate_image_tag(tag)
#   Validates a tag exists on docker.n8n.io or docker.io for n8nio/n8n.
################################################################################
validate_image_tag() {
    local tag="$1"
    if docker manifest inspect "docker.n8n.io/n8nio/n8n:${tag}" >/dev/null 2>&1; then return 0; fi
    if docker manifest inspect "docker.io/n8nio/n8n:${tag}"  >/dev/null 2>&1; then return 0; fi
    return 1
}

################################################################################
# create_volumes()
#   Ensures required Docker volumes exist for the stack and lists volumes.
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
#   Copies docker-compose.yml and .env templates into $N8N_DIR (with backups),
#   injects DOMAIN/SSL_EMAIL/N8N_IMAGE_TAG, rotates STRONG_PASSWORD if default/
#   missing, and tightens file permissions.
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
    if [[ "$password_line" == "myStrongPassword123!@#" || -z "$password_line" ]]; then
        local new_password
        new_password="$(openssl rand -base64 16)"
        log INFO "Setting STRONG_PASSWORD in .env"
        upsert_env_var "STRONG_PASSWORD" "${new_password}" "$env_file"
    else
        log DEBUG "Existing STRONG_PASSWORD found. Not modifying it."
        log DEBUG "STRONG_PASSWORD=$password_line"
    fi

    # Secure secrets file
    chmod 600 "$env_file" 2>/dev/null || true
    chmod 640 "$compose_file" 2>/dev/null || true
}

################################################################################
# install_docker()
#   Installs Docker Engine + Compose v2 using the official repo (with fallback
#   to get.docker.com). Installs common dependencies, enables the service, and
#   adds the invoking user to the docker group.
################################################################################
install_docker() {
    if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        log INFO "Docker already installed. Skipping Docker install."
    else
        log INFO "Installing prerequisites (curl, ca-certificates, gpg, lsb-release)..."
        apt-get update -y
        apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release

        log INFO "Adding Docker GPG key (non-interactive)..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null
    
        chmod a+r /etc/apt/keyrings/docker.gpg

        log INFO "Adding Docker repository..."
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -y

        log INFO "Installing Docker Engine and Docker Compose v2..."
        if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            log WARN "APT install from Docker repo failed. Falling back to official convenience script..."
            curl -fsSL https://get.docker.com | sh
        fi
    fi
    log INFO "Installing required dependencies..."
    apt-get install -y --no-install-recommends \
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
#   Prints a human-friendly summary: domain, version, timestamp, dirs, log file.
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
#   Orchestrates a fresh install: prompt email (if missing), DNS check,
#   Docker install, compose prep/validation, volumes, up, health, summary.
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
#   Determines target version (explicit or latest), prevents accidental
#   downgrades unless --force, updates .env tag, `compose down`, re-validate,
#   bring up, health check, summary.
################################################################################
upgrade_n8n() {
    log INFO "Checking current and latest n8n versions..."
    cd "$N8N_DIR"
    load_env_file

    # Make sure jq is available for tag lookups
    if ! command -v jq >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y --no-install-recommends jq
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
#   Interactive destructive cleanup: `compose down --remove-orphans`, prune
#   images, remove known volumes and the n8n network (if present).
################################################################################
cleanup_n8n() {
    read -p "This will remove ALL n8n containers/volumes/images. Continue? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { log INFO "Cleanup cancelled."; return 0; }
    log INFO "Stopping containers and removing containers, volumes, and orphan services..."
    if [[ -f "$N8N_DIR/docker-compose.yml" ]]; then
        compose down --remove-orphans
    else
        log WARN "docker-compose.yml not found at \$N8N_DIR; attempting plain 'docker compose down' in $PWD."
        docker compose down --remove-orphans
    fi

    log INFO "Pruning unused Docker images..."
    docker image prune -f

    log INFO "Removing related volumes..."
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            docker volume rm "$vol" && log INFO "Removed volume: $vol"
        else
            log INFO "Volume '$vol' not found, skipping..."
        fi
    done

    log INFO "Removing n8n network (if exists)..."
    if docker network inspect n8n_network >/dev/null 2>&1; then
        if docker network rm n8n_network 2>/dev/null; then
            log INFO "Removed Docker network: n8n_network"
        else
            log WARN "Could not remove 'n8n_network' — it may still be in use."
        fi
    else
        log INFO "Network 'n8n_network' not found, skipping..."
    fi

    log INFO "Cleanup completed successfully!"
}

# Arg parsing
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
N8N_DIR="${TARGET_DIR:-$PWD}"
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
