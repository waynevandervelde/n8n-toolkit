#!/bin/bash
# n8n_common.sh — Common helpers reused by n8n_manager.sh & n8n_backup_restore.sh
set -euo pipefail
IFS=$'\n\t'

#############################################################################################
# n8n_common.sh - Shared functions for n8n_manager.sh and n8n_backup_restore.sh
# Provides:
#   • Logging with levels & timestamps
#   • Error/interrupt handling
#   • Root privilege check
#   • Env file loading and updating
#   • Docker Compose wrapper
#   • Service health check
#   • Version fetching/parsing utilities
#   • SSL certificate verification via Traefik
#############################################################################################

# Logging
LOG_LEVEL="${LOG_LEVEL:-INFO}"; LOG_LEVEL="${LOG_LEVEL^^}"
################################################################################
# log()
#   Handles conditional logging based on the defined log level (DEBUG, INFO, WARN, ERROR)
################################################################################
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
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        # Send WARN/ERROR to stderr so they aren't swallowed by command substitution
        if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
            echo "[$ts] [$level] $*" >&2
        else
            echo "[$ts] [$level] $*"
        fi
    fi
}

################################################################################
# print_stacktrace()
#   Helper for error diagnostics: prints a compact stack trace (most recent first).
################################################################################
print_stacktrace() {
    # Skip the last frame (the trap context)
    local depth=$(( ${#FUNCNAME[@]} - 1 ))
    [[ $depth -lt 1 ]] && return 0

    log ERROR "Stack trace (most recent call first):"
    # i=0 is the failing function; BASH_SOURCE[i+1] is the caller's file
    for ((i=0; i<depth; i++)); do
        local func="${FUNCNAME[$i]:-main}"
        local src="${BASH_SOURCE[$i+1]:-${BASH_SOURCE[0]}}"
        local line="${BASH_LINENO[$i]:-0}"
        log ERROR "  at ${func}()  ${src}:${line}"
    done
}

################################################################################
# on_interrupt()
#   Trap for INT/TERM/HUP: logs, attempts to stop the stack cleanly, exits 130.
################################################################################
on_interrupt() {
    log ERROR "Interrupted by user (SIGINT) at ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-0} in ${FUNCNAME[1]:-main}(). Stopping containers and exiting..."
    if [[ -n "${N8N_DIR:-}" && -f "$N8N_DIR/docker-compose.yml" ]]; then
        (cd "$N8N_DIR" && docker compose -f "$N8N_DIR/docker-compose.yml" down) || true
    fi
    exit 130
}

################################################################################
# on_error()
#   Trap for ERR: logs failing command + location, prints stack, shows `ps`,
#   exits with the original command’s exit code.
################################################################################
on_error() {
    local exit_code=$?
    local cmd="${BASH_COMMAND}"
    local where_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    local where_line="${BASH_LINENO[0]:-0}"
    local where_func="${FUNCNAME[1]:-main}"

    log ERROR "Command failed (exit $exit_code): $cmd"
    log ERROR "Location: ${where_file}:${where_line} in ${where_func}()"

    print_stacktrace

    if [[ -n "${N8N_DIR:-}" && -f "$N8N_DIR/docker-compose.yml" ]]; then
        (cd "$N8N_DIR" && docker compose -f "$N8N_DIR/docker-compose.yml" ps) || true
    fi

    exit "$exit_code"
}

################################################################################
# require_cmd(cmd)
#   Bail out early with an error if the given command is not installed.
################################################################################
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log ERROR "Missing required command: $1"
        return 1
    fi
}

################################################################################
# check_root()
#   Ensures the script is run as root (EUID=0). Exits if not.
################################################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root."
        return 1
    fi
}

################################################################################
# upsert_env_var(key, value, file)
#   Inserts or replaces KEY=VALUE in an .env file (idempotent).
################################################################################
upsert_env_var() {
	local key="$1" val="$2" file="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf "\n%s=%s\n" "$key" "$val" >> "$file"
    fi
	log INFO "Added the $key=$val to $file"
}

################################################################################
# load_env_file
################################################################################
load_env_file() {
  local f="${1:-${ENV_FILE:-}}"
  [[ -z "$f" ]] && f="${N8N_DIR:-$PWD}/.env"
  [[ -f "$f" ]] || { log WARN "No .env to load at: $f"; return 0; }
  set -o allexport
  # shellcheck disable=SC1090
  source "$f"
  set +o allexport
}

################################################################################
# parse_domain_arg(raw)
#   Normalizes a domain-like string (strips scheme, path, port, www, whitespace,
#   lowercases) and validates it against a strict hostname regex.
#   Echoes the cleaned domain or exits(2) on invalid input.
################################################################################
parse_domain_arg() {
    local raw="$1"
    local d

    # Normalize
    d="${raw,,}"                              # lowercase
    d="${d#"${d%%[![:space:]]*}"}"            # trim leading space
    d="${d%"${d##*[![:space:]]}"}"            # trim trailing space
    d="${d#http://}"; d="${d#https://}"       # strip scheme
    d="${d%%/*}"                              # strip path (/...), if any
    d="${d%%\?*}"                             # strip query
    d="${d%%\#*}"                             # strip fragment
    d="${d%%:*}"                              # strip :port
    d="${d%.}"                                # strip trailing dot

    # Strip "www."
    [[ "$d" == www.* ]] && d="${d#www.}"

    # Validate
    # Hostname labels: a-z, 0-9, hyphen (no leading/trailing '-'), 1–63 chars per label
    # At least one dot; TLD 2–63 letters; total length <= 253
    local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    if [[ -z "$d" || ${#d} -gt 253 || ! "$d" =~ $re ]]; then
        log ERROR "Invalid domain: '$raw' → '$d'. Expected a hostname like n8n.example.com"
        exit 2
    fi

    printf '%s\n' "$d"
}

################################################################################
# compose()
#   Wrapper for `docker compose` that always supplies --env-file "$ENV_FILE"
#   and -f "$COMPOSE_FILE". Use this for all compose operations.
################################################################################
# Expect: ENV_FILE, COMPOSE_FILE set by caller scripts.
compose() {
    if [[ -z "${COMPOSE_FILE:-}" || -z "${ENV_FILE:-}" ]]; then
        log ERROR "compose(): COMPOSE_FILE/ENV_FILE not set"; return 1
    fi
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

################################################################################
# strict_env_check(compose_file, env_file)
#   Scans the compose file for ${VARS} and verifies each exists in env_file.
#   Prints missing keys and returns non-zero if any are absent.
################################################################################
strict_env_check() {
    local compose_file="$1" env_file="$2"
    [[ -f "$env_file" ]] || { log ERROR ".env file not found at $env_file"; return 1; }

    log INFO "Checking for unset environment variables in $compose_file..."
    local vars_in_compose missing_vars=()
    vars_in_compose=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$compose_file" | sort -u | tr -d '${}')

    # Build a map of KEYs that exist in .env (ignore comments/blank lines)
    declare -A envmap
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" =~ ^\s*# ]] && continue
        k="${k%% *}"; k="${k%%	*}"
        envmap["$k"]=1
    done < "$env_file"

    for var in $vars_in_compose; do
        [[ -n "${envmap[$var]:-}" ]] || missing_vars+=("$var")
    done

    if (( ${#missing_vars[@]} )); then
        log ERROR "Missing required environment variables:"
        printf ' - %s\n' "${missing_vars[@]}"
        return 1
    fi

    log INFO "All required environment variables are set."
    return 0
}

################################################################################
# validate_compose_and_env()
#   Runs strict_env_check, then `docker compose config` via the wrapper to catch
#   unresolved variables or syntax errors.
################################################################################
validate_compose_and_env() {
    [[ -f "${COMPOSE_FILE:-}" ]] || { log ERROR "Missing COMPOSE_FILE"; return 1; }
    [[ -f "${ENV_FILE:-}" ]]     || { log ERROR "Missing ENV_FILE"; return 1; }
    strict_env_check "$COMPOSE_FILE" "$ENV_FILE" || return 1

    # Validate docker-compose config syntax
    local config_output
    config_output=$(compose config 2>&1) || true

    if grep -q 'variable is not set' <<<"$config_output"; then
        log ERROR "Compose config found unset variables:"
        echo "$config_output" | grep 'variable is not set'
        return 1
    elif grep -qi 'error' <<<"$config_output"; then
        log ERROR "Compose config error:"
        echo "$config_output"
        return 1
    fi
    log INFO "docker-compose.yml and .env validated successfully."
}

################################################################################
# dump_service_logs(service [, tail=200])
#   Prints last N log lines for a compose service (by service name).
################################################################################
dump_service_logs() {
    local svc="$1"; local tail="${2:-200}"
    local cid
    cid="$(compose ps -q "$svc" 2>/dev/null | head -n1 || true)"
    if [[ -n "$cid" ]]; then
        log INFO "===== Logs: ${svc} (last ${tail} lines) ====="
        docker logs --tail "$tail" "$cid" || true
    else
        log WARN "Service '$svc' not found (no container id)."
    fi
}

################################################################################
# dump_unhealthy_container_logs([tail=200])
#   For all containers in this compose project:
#     - If not running or unhealthy → print container name & tail logs.
################################################################################
dump_unhealthy_container_logs() {
    local tail="${1:-200}"
    local containers name status health
    containers="$(compose ps -q || true)"
    [[ -n "$containers" ]] || { log WARN "No containers found to dump logs for."; return 0; }

    for container_id in $containers; do
        name="$(docker inspect --format='{{.Name}}' "$container_id" | sed 's#^/##')"
        status="$(docker inspect --format='{{.State.Status}}' "$container_id")"
        health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"

        if [[ "$status" != "running" || ( "$health" != "none" && "$health" != "healthy" ) ]]; then
            log INFO "Container needs attention: name=${name} status=${status} health=${health}"
            log INFO "----- Begin logs (${name}) -----"
            docker logs --tail "$tail" "$container_id" || true
            log INFO "----- End logs (${name}) -----"
        fi
    done
}


################################################################################
# wait_for_containers_healthy([timeout=180], [interval=10])
#   Polls `compose ps` containers until all are running and healthy (or timeout).
#   Logs status each interval; returns non-zero on timeout.
################################################################################
wait_for_containers_healthy() {
	local timeout="${1:-180}"
	local interval="${2:-10}"
 	local containers all_ok name status health
    local elapsed=0
    local -a offenders=()

    log INFO "Checking container status..."

    while [ $elapsed -lt $timeout ]; do
        log INFO "Status check at $(date +%T)..."
        all_ok=true
        compose ps
        offenders=()

		containers="$(compose ps -q || true)"
        for container_id in $containers; do
            name=$(docker inspect --format='{{.Name}}' "$container_id" | sed 's/^\/\(.*\)/\1/')
            status=$(docker inspect --format='{{.State.Status}}' "$container_id")
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")

            if [[ "$status" != "running" ]]; then
                log WARN "$name is not running (status: $status)"
                offenders+=("$name")
                all_ok=false
            elif [[ "$health" != "none" && "$health" != "healthy" ]]; then
                log WARN "$name is running but not healthy (health: $health)"
                offenders+=("$name")
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
    if ((${#offenders[@]})); then
        local uniq
        uniq="$(printf '%s\n' "${offenders[@]}" | sort -u | xargs)"
        log INFO "Containers needing attention after timeout: ${uniq}"
        log INFO "Tip: stream a container's logs with:  docker logs -f <container_name>"
    fi

    # Collect logs from all non-running/unhealthy containers
    dump_unhealthy_container_logs 200
    return 1
}

################################################################################
# check_container_healthy()
#   Polls defined container until it's running & healthy (or times out).
################################################################################
check_container_healthy() {
    local container_name="$1"
    local timeout="${2:-60}"
    local interval="${3:-5}"
    local elapsed=0

    log INFO "Checking health for container: $container_name"

    while [ $elapsed -lt $timeout ]; do
        local container_id
		compose ps || true
		container_id="$(compose ps -q "$container_name" 2>/dev/null || true)"
		if [[ -z "$container_id" ]]; then
            container_id=$(docker ps -q -f "name=${container_name}" || true)
        fi

        if [[ -z "$container_id" ]]; then
            log WARN "Container '$container_name' not found or not running."
        else
            local status health
            status=$(docker inspect --format='{{.State.Status}}' "$container_id")
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")

            if [[ "$status" == "running" && ( "$health" == "none" || "$health" == "healthy" ) ]]; then
                log INFO "$container_name is running and ${health:-no-health-check}"
                return 0
            else
                log WARN "$container_name is running but not healthy (status: $status, health: $health)"
            fi
        fi

        log INFO "Waiting ${interval}s for next check"
        for ((i = 0; i < interval; i++)); do
            echo -n "."
            sleep 1
        done
        echo ""
        elapsed=$((elapsed + interval))
    done

    log ERROR "Timeout after ${timeout}s. Container '$container_name' is not healthy."
    return 1
}

################################################################################
# verify_traefik_certificate()
#   Optional post-deploy check:
#     - Ensures HTTPS responds (200/301/302)
#     - Retrieves and logs LE certificate issuer/subject/dates via openssl.
################################################################################
verify_traefik_certificate() {
    local domain="${1:-${DOMAIN:-}}"
    if [[ -z "$domain" ]]; then
        log ERROR "verify_traefik_certificate: domain is empty"
        return 1
    fi

    local domain_url="https://${domain}"
    local MAX_RETRIES=6
    local SLEEP_INTERVAL=10
    local domain_ip=""
    local response=""
    local success=false
    
    if command -v dig >/dev/null 2>&1; then
        log INFO "Checking DNS resolution for domain..."
        domain_ip=$(dig +short "$domain")
        if [[ -z "$domain_ip" ]]; then
            log ERROR "DNS lookup failed for $domain. Ensure it points to your server's IP."
            return 1
        fi
        log INFO "Domain $domain resolves to IP: $domain_ip"
    else
        log WARN "'dig' not found; skipping DNS lookup step."
    fi

    log INFO "Checking if your domain is reachable via HTTPS..."
    for ((i=1; i<=MAX_RETRIES; i++)); do
        response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$domain_url" || true)
        if [[ "$response" == "200" || "$response" == "301" || "$response" == "302" || "$response" == "308" ]]; then
            log INFO "$domain is reachable with HTTPS (HTTP $response)"
            success=true
            break
        elif [[ "$response" == "000" || -z "$response" ]]; then
            log WARN "No HTTPS response received (attempt $i/$MAX_RETRIES). Traefik or certs might not be ready."
        else
            log WARN "Domain not reachable (HTTP $response) (attempt $i/$MAX_RETRIES)."
        fi
        [[ $i -lt $MAX_RETRIES ]] && { log INFO "Retrying in ${SLEEP_INTERVAL}s..."; sleep $SLEEP_INTERVAL; }
    done

    if [[ "$success" != true ]]; then
        log ERROR "$domain is not reachable via HTTPS after $MAX_RETRIES attempts."
        dump_service_logs traefik 200
        log INFO "Tip: follow live Traefik logs with:  docker logs -f traefik"
        return 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        log WARN "'openssl' not found; skipping certificate inspection."
        return 0
    fi

    log INFO "Validating SSL certificate from Let's Encrypt..."
    for ((i=1; i<=MAX_RETRIES; i++)); do
        local cert_info issuer subject not_before not_after
        cert_info=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null | \
                    openssl x509 -noout -issuer -subject -dates || true)
        if [[ -n "$cert_info" ]]; then
            issuer=$(echo "$cert_info"  | grep '^issuer='   || true)
            subject=$(echo "$cert_info" | grep '^subject='  || true)
            not_before=$(echo "$cert_info" | grep '^notBefore=' || true)
            not_after=$(echo "$cert_info"  | grep '^notAfter='  || true)
            [[ -n "$issuer"     ]] && log INFO "Issuer: $issuer"
            [[ -n "$subject"    ]] && log INFO "Subject: $subject"
            [[ -n "$not_before" ]] && log INFO "Certificate Valid from: ${not_before#notBefore=}"
            [[ -n "$not_after"  ]] && log INFO "Certificate Expires on: ${not_after#notAfter=}"
            return 0
        else
            log WARN "Unable to retrieve certificate (attempt $i/$MAX_RETRIES)."
            [[ $i -lt $MAX_RETRIES ]] && sleep $SLEEP_INTERVAL
        fi
    done

    log ERROR "Could not retrieve certificate details after $MAX_RETRIES attempts."
    dump_service_logs traefik 200
    log INFO "Tip: follow live Traefik logs with:  docker logs -f traefik"
    return 1
}

################################################################################
# get_current_n8n_version()
#   Determines the running n8n version by exec'ing into the n8n container.
#   Falls back to "unknown" if not running.
################################################################################
get_current_n8n_version() {
    local cid
    cid=$(compose ps -q n8n 2>/dev/null || true)
    if [[ -n "$cid" ]]; then
        docker exec "$cid" n8n --version 2>/dev/null && return 0
    fi
    docker exec n8n n8n --version 2>/dev/null || echo "unknown"
}

################################################################################
# get_latest_n8n_version()
#   Fetches the latest stable semver tag from Docker Hub (n8nio/n8n).
################################################################################
get_latest_n8n_version() {
    if ! command -v jq >/dev/null 2>&1; then
        log ERROR "'jq' is required to fetch tags from Docker Hub."
        return 1
    fi

    local response
    response=$(curl -fsS --connect-timeout 5 --retry 3 --retry-delay 2 \
          'https://hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=100' 2>/dev/null | \
          jq -r '.results[].name' 2>/dev/null | \
          grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vr | head -n 1 || true)
    [[ -z "$response" ]] && log ERROR "Could not fetch latest n8n tag from Docker Hub"
    echo "$response"
}

################################################################################
# fetch_all_stable_versions()
#   Retrieves all stable semver tags (paginated) from Docker Hub.
#   Prints unique, natural-sorted ascending list of x.y.z.
################################################################################
fetch_all_stable_versions() {
    if ! command -v jq >/dev/null 2>&1; then
        log ERROR "'jq' is required to fetch tags from Docker Hub."
        return 1
    fi

    local url="https://registry.hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=100"
    local next page_json
    local -a all=()

    while [[ -n "$url" ]]; do
        page_json=$(curl -fsS --retry 3 --retry-delay 2 "$url" 2>/dev/null || true)
        [[ -z "$page_json" ]] && { log WARN "Failed to fetch tags page"; break; }
        mapfile -t page_tags < <(jq -r '.results[].name' <<<"$page_json" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
        all+=("${page_tags[@]}")
        next=$(jq -r '.next // empty' <<<"$page_json" 2>/dev/null || true)
        url="$next"
    done

    if ((${#all[@]}==0)); then
        log WARN "No n8n stable version found from Docker Hub"
        return 0
    fi

    # print unique, sorted ascending (natural/semantic)
    printf "%s\n" "${all[@]}" | sort -Vu
}

################################################################################
# docker_compose_up()
#   Starts the stack in detached mode using the compose wrapper.
################################################################################
docker_compose_up() {
    log INFO "Starting Docker Compose..."
    compose up -d
}

################################################################################
# check_services_up_running()
#   Composite health gate: waits for healthy containers and (optionally) checks
#   the TLS certificate.
################################################################################
check_services_up_running() {
    if ! wait_for_containers_healthy; then
        log ERROR "Some containers are not running or unhealthy. Please check the logs above."
        return 1
    fi

    if ! verify_traefik_certificate "$DOMAIN"; then
        log ERROR "Traefik failed to issue a valid TLS certificate. Please check DNS, Traefik logs, and try again."
        return 1
    fi
    return 0
}
