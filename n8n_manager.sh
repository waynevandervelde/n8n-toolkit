#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
#############################################################################################
# N8N Installation & Management Script
# Author: TheNguyen
# Email: thenguyen.ai.automation@gmail.com
# Version: 1.0.0
# Date: 2025-08-05
#
# Description:
#   Automates the installation, upgrade, and cleanup of the n8n automation
#   platform using Docker Compose.
#
# Features:
#   - Validates domain DNS resolution
#   - Installs Docker and Docker Compose if not present
#   - Creates persistent Docker volumes
#   - Starts n8n services with health and certificate checks
#   - Supports force-upgrade option
#   - Cleans up containers, volumes, and networks completely
#
# Usage:
#   ./n8n_manager.sh -i <DOMAIN> [-l INFO|DEBUG]    # Install n8n with specified domain
#   ./n8n_manager.sh -u <DOMAIN>                    # Upgrade n8n with specified domain
#   ./n8n_manager.sh -d <TARGET_DIR>                # Target install directory (default: ${PWD})
#   ./n8n_manager.sh -u -f <DOMAIN>                 # Force upgrade n8n
#   ./n8n_manager.sh -c                             # Cleanup n8n containers and volumes
#############################################################################################
trap 'on_interrupt' INT

# Catches Ctrl+C (SIGINT) and gracefully shuts down running containers before exiting
on_interrupt() {
    log ERROR "Interrupted by user. Stopping containers and exiting..."
    if [[ -f "$N8N_DIR/docker-compose.yml" ]]; then
        cd "$N8N_DIR"
        docker compose down || true
    fi
    exit 1
}

# Global variables
INSTALL=false
UPGRADE=false
CLEANUP=false
FORCE_UPGRADE=false
LOG_LEVEL="INFO"
TARGET_DIR=""
VOLUMES=("n8n-data" "postgres-data" "letsencrypt")

# Handles conditional logging based on the defined log level (DEBUG, INFO, WARN, ERROR)
log() {
    local level="$1"
    shift
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

# Displays script usage/help information when incorrect or no arguments are passed
usage() {
    echo "Usage: $0 [-i DOMAIN] [-u DOMAIN] [-f] [-c] [-d TARGET_DIR] [-l LOG_LEVEL] -h"
    echo "  $0 -i <DOMAIN>         Install n8n stack"
    echo "  $0 -u <DOMAIN> [-f]    Upgrade n8n stack (optionally force)"
    echo "  $0 -c                  Cleanup all containers, volumes, and network"
    echo "  $0 -d <TARGET_DIR>     Target install directory (default: $PWD)"
    echo "  $0 -l                  Set log level: DEBUG, INFO (default), WARN, ERROR"
    echo "  $0 -h                  Show script usage"
    exit 1
}

# Ensures the script is run as root user; exits if not
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root."
        exit 1
    fi
}

# Validates that the provided domain points to the current server's public IP
check_domain() {
    local server_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "Unavailable")
    local domain_ip=$(dig +short $DOMAIN)
    log INFO "Your server's public IP is: $server_ip"
    log INFO "Domain $DOMAIN currently resolves to: $domain_ip"
    if [ "$domain_ip" = "$server_ip" ]; then
        log INFO "Domain $DOMAIN is correctly pointing to this server."
    else
        log ERROR "Domain $DOMAIN is NOT pointing to this server."
        log INFO "Please update your DNS record to point to: $(curl -s https://api.ipify.org)"
        exit 1
    fi
}

# Prompts the user to input a valid email address for SSL certificate generation
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

# Prepares docker-compose.yml and .env by copying templates and injecting variables
prepare_compose_file() {
    # Copy docker-compose and .env template to the target dir
    local compose_template="$PWD/docker-compose.yml"
    local compose_file="$N8N_DIR/docker-compose.yml"
    local env_template="$PWD/.env"
    local env_file="$N8N_DIR/.env"
    local password="$(openssl rand -base64 16)"

    if [[ ! -f "$compose_template" ]]; then
        log ERROR "docker-compose.yml not found at $compose_template"
        exit 1 
    fi

    if [[ ! -f "$env_template" ]]; then
        log ERROR ".env file not found at $env_template"
        exit 1 
    fi

    if [[ "$compose_template" != "$compose_file" ]]; then
        cp "$compose_template" "$compose_file"
    fi

    if [[ "$env_template" != "$env_file" ]]; then
        cp "$env_template" "$env_file"
    fi

    log INFO "Updating .env file with provided domain, email..."
    # Use sed to replace variables
    sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "$env_file"
    sed -i "s|^SSL_EMAIL=.*|SSL_EMAIL=${SSL_EMAIL}|" "$env_file"

    # Inside prepare_compose_file
    local password_line
    password_line=$(grep "^STRONG_PASSWORD=" "$env_file" | cut -d '=' -f2)
    if [[ "$password_line" == "myStrongPassword123!@#" || -z "$password_line" ]]; then
        local new_password
        new_password="$(openssl rand -base64 16)"
        log INFO "Updating .env with new strong password..."
        sed -i "s|^STRONG_PASSWORD=.*|STRONG_PASSWORD=${new_password}|" "$env_file"
    else
    log DEBUG "Existing STRONG_PASSWORD found. Not modifying it."
    log DEBUG "STRONG_PASSWORD=$password_line"
    fi
}

# Ensures all required environment variables in the Docker Compose file are defined
strict_env_check() {
    local compose_file="$1"
    local env_file="$2"

    # Load .env variables
    if [[ -f "$env_file" ]]; then
        set -o allexport
        source "$env_file"
        set +o allexport
    else
        log ERROR ".env file not found at $env_file"
        return 1
    fi

    log INFO "Checking for unset environment variables in $compose_file..."

    # Extract all variable names from docker-compose.yml (like ${VAR_NAME})
    missing_vars=()
    vars_in_compose=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$compose_file" | sort -u | tr -d '${}')

    for var in $vars_in_compose; do
        if [[ -z "${!var+x}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if (( ${#missing_vars[@]} > 0 )); then
        log ERROR "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo " - $var"
        done
        return 1
    fi

    log INFO "All required environment variables are set."
    return 0
}

# Validates the syntax of the docker-compose.yml and ensures all .env variables are present
validate_compose_and_env() {
    local compose_file="$N8N_DIR/docker-compose.yml"
    local env_file="$N8N_DIR/.env"

    log INFO "Validating Docker Compose configuration and .env file..."

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "docker-compose.yml not found at $compose_file"
        exit 1 
    fi

    if [[ ! -f "$env_file" ]]; then
        log ERROR ".env file not found at $env_file"
        exit 1 
    fi

    # Validate required env vars are defined
    if ! strict_env_check "$compose_file" "$env_file"; then
        exit 1 
    fi

    # Validate docker-compose config syntax
    local config_output
    config_output=$(docker compose --env-file "$env_file" -f "$compose_file" config 2>&1)
    if echo "$config_output" | grep -q 'variable is not set'; then
        log ERROR "Docker Compose config found unset variables:"
        echo "$config_output" | grep 'variable is not set'
        exit 1 
    elif echo "$config_output" | grep -q 'error'; then
        log ERROR "Docker Compose config error:"
        echo "$config_output"
        exit 1 
    fi

    log INFO "docker-compose.yml and .env validated successfully."
}

# Installs Docker, Docker Compose, and related system dependencies
install_docker() {
    log INFO "Removing any old Docker versions..."
    apt-get remove -y docker docker-engine docker.io containerd runc

    log INFO "Installing required dependencies..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release jq vim yamllint

    log INFO "Adding Docker GPG key (non-interactive)..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null

    log INFO "Adding Docker repository..."
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

    log INFO "Installing Docker Engine and Docker Compose v2..."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    CURRENT_USER=${SUDO_USER:-$(whoami)}

    log INFO "Adding user '$CURRENT_USER' to the docker group..."
    usermod -aG docker "$CURRENT_USER"

    log INFO "Docker and Docker Compose installed successfully."
}

# Returns the currently running version of n8n from the Docker container
get_current_n8n_version() {
    docker exec n8n n8n --version 2>/dev/null
}

# Fetches the latest stable n8n version tag from Docker Hub
get_latest_n8n_version() {
    curl -s https://hub.docker.com/v2/repositories/n8nio/n8n/tags \
    | jq -r '.results[].name' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -Vr | head -n 1
}

# Creates all Docker volumes required by the n8n stack if they don't already exist
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

# Starts the n8n stack using Docker Compose
run_docker_compose() {
    log INFO "Starting Docker Compose..."
    cd "$N8N_DIR"
    docker compose up -d
}

# Waits for all containers to reach a healthy state within a timeout window
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

# Prints final status messages after install or upgrade with version and URL info
print_summary_message() {
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

# Verifies DNS, HTTPS, and SSL certificate health for the domain using curl and openssl
verify_traefik_certificate() {
    local domain_url="https://${DOMAIN}"

    log INFO "Checking DNS resolution for domain..."
    domain_ip=$(dig +short "$DOMAIN")
    if [[ -z "$domain_ip" ]]; then
        log ERROR "DNS lookup failed for $DOMAIN. Ensure it points to your server's IP."
        return 1
    fi

    log INFO "Checking if your domain is reachable via HTTPS..."
    response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$domain_url")

    if [[ "$response" == "200" || "$response" == "301" || "$response" == "302" ]]; then
        log INFO "Domain is reachable with HTTPS: $domain_url (HTTP Code: $response)"
    elif [[ "$response" == "000" ]]; then
        log ERROR "No HTTPS response received. Check if Traefik is exposing port 443 or if certs are valid."
        return 1
    else
        log ERROR "Domain is not reachable via HTTPS (HTTP Code: $response)"
        return 1
    fi

    log INFO "Validating SSL certificate from Let's Encrypt..."

    cert_info=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates)
    if [[ -z "$cert_info" ]]; then
        log ERROR "Could not retrieve certificate details. The certificate might not be installed, or SSL handshake failed."
        return 1
    fi

    issuer=$(echo "$cert_info" | grep '^issuer=')
    subject=$(echo "$cert_info" | grep '^subject=')
    not_before=$(echo "$cert_info" | grep '^notBefore=')
    not_after=$(echo "$cert_info" | grep '^notAfter=')

    log INFO "Issuer: $issuer"
    log INFO "Subject: $subject"
    log INFO "Certificate Valid from: ${not_before#notBefore=}"
    log INFO "Certificate Expires on: ${not_after#notAfter=}"

    return 0
}

# Verifies DNS, HTTPS, and SSL certificate health for the domain using curl and openssl
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

# Combines container health and optional certificate checks to confirm stack is operational
check_services_up_running() {
    if ! check_containers_healthy; then
        log ERROR "Some containers are not running or unhealthy. Please check the logs above."
        exit 1
    fi

    if ! verify_traefik_certificate; then
        log ERROR "Traefik failed to issue a valid TLS certificate. Please check DNS, Traefik logs, and try again."
        exit 1
    fi
    print_summary_message
}

# Orchestrates the full installation flow: validation, config setup, Docker install, service start
install_n8n() {
    log INFO "Starting N8N installation for domain: $DOMAIN"
    get_user_email
    check_domain
    prepare_compose_file
    validate_compose_and_env
    install_docker
    create_volumes
    run_docker_compose
    check_services_up_running
}

# Manages the upgrade flow: version check, image pull, and redeploy the stack with the latest image
upgrade_n8n() {
    log INFO "Checking current and latest n8n versions..."
    cd "$N8N_DIR"
    current_version=$(get_current_n8n_version)
    latest_version=$(get_latest_n8n_version)

    log INFO "Current version: $current_version"
    log INFO "Latest version:  $latest_version"

    if [[ "$(echo -e "$latest_version\n$current_version" | sort -V | head -n1)" == "$latest_version" && "$FORCE_UPGRADE" != true ]]; then
    log INFO "You are already running the latest version ($latest_version). Use -f to force upgrade."
    exit 0
    fi

    log INFO "Pulling latest image..."
    docker pull n8nio/n8n:$latest_version

    log INFO "Stopping and removing existing containers..."
    docker compose down

    validate_compose_and_env
    run_docker_compose

    check_services_up_running
}

# Stops the n8n stack and cleans up Docker containers, volumes, images, and networks
cleanup_n8n() {
    log INFO "Stopping containers and removing containers, volumes, and orphan services..."
    docker compose down --remove-orphans

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

#  Main
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

while getopts ":i:u:fcd:l:" opt; do
  case $opt in
    i)
      DOMAIN="$OPTARG"
      INSTALL=true
      ;;
    u)
      DOMAIN="$OPTARG"
      UPGRADE=true
      ;;
    f)
      FORCE_UPGRADE=true
      ;;
    c)
      CLEANUP=true
      ;;
    d)
      TARGET_DIR="$OPTARG"
      ;;
    l)
      LOG_LEVEL="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG"
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument."
      usage
      ;;
  esac
done

# Main execution
check_root
N8N_DIR="${TARGET_DIR:-$PWD}"
log INFO "Working on directory: $N8N_DIR"
mkdir -p "$N8N_DIR/logs"
sudo chown -R $USER:$USER "$N8N_DIR"
LOG_FILE="$N8N_DIR/logs/n8n_manager.log"
exec > >(tee "$LOG_FILE") 2>&1
log INFO "Logging to $LOG_FILE"

if [[ $INSTALL == true ]]; then
    install_n8n
elif [[ $UPGRADE == true ]]; then
    upgrade_n8n
elif [[ $CLEANUP == true ]]; then
    cleanup_n8n
else
    usage
fi
