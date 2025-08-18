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
# Description:
#   Structured logger with levels (DEBUG, INFO, WARN, ERROR) and timestamps.
#
# Behaviors:
#   - Respects global LOG_LEVEL (defaults to INFO).
#   - Prints WARN/ERROR to stderr; others to stdout.
#   - Formats as: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
#
# Returns:
#   0 always.
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
# Description:
#   Print a compact stack trace (most recent call first) for error diagnostics.
#
# Behaviors:
#   - Skips the trap frame.
#   - Logs function name, source file, and line for each frame.
#
# Returns:
#   0 always.
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
# Description:
#   Trap handler for INT/TERM/HUP: stop stack cleanly and exit.
#
# Behaviors:
#   - Logs interrupt location.
#   - Runs `docker compose down` for current N8N_DIR if compose file exists.
#   - Exits with code 130.
#
# Returns:
#   Never returns (exits 130).
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
# Description:
#   Trap handler for ERR: log failing command/location, show stack & compose ps.
#
# Behaviors:
#   - Logs failed command, file, line, and function.
#   - Calls print_stacktrace().
#   - Runs `docker compose ps` (if compose file present).
#   - Exits with the original failing command’s exit code.
#
# Returns:
#   Never returns (exits with prior exit code).
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
# require_cmd()
# Description:
#   Ensure a required binary exists in PATH.
#
# Behaviors:
#   - Logs ERROR if command is missing.
#
# Returns:
#   0 if found; 1 if missing.
################################################################################
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log ERROR "Missing required command: $1"
        return 1
    fi
}

################################################################################
# check_root()
# Description:
#   Ensure the script is running as root (EUID = 0).
#
# Behaviors:
#   - Logs ERROR if not root.
#
# Returns:
#   0 if root; 1 otherwise.
################################################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root."
        return 1
    fi
}

################################################################################
# upsert_env_var()
# Description:
#   Insert or update KEY=VALUE in a .env file idempotently.
#
# Behaviors:
#   - Replaces existing line matching ^KEY=... or appends a new line.
#
# Returns:
#   0 on success; non-zero on failure.
################################################################################
upsert_env_var() {
	local key="$1" val="$2" file="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf "\n%s=%s\n" "$key" "$val" >> "$file"
    fi
}

################################################################################
# mask_secret()
# Description:
#   Mask a secret by showing only the first and last 4 characters.
#
# Behaviors:
#   - If length ≤ 8, prints the string unchanged.
#   - Else prints: XXXX***YYYY
#
# Returns:
#   0 always (prints masked value to stdout).
################################################################################
mask_secret() {
    # Show first/last 4 chars only
    local s="$1"
    local n=${#s}
    (( n<=8 )) && { printf '%s\n' "$s"; return; }
    printf '%s\n' "${s:0:4}***${s: -4}"
}

################################################################################
# looks_like_b64()
# Description:
#   Heuristic check whether a string looks like base64.
#
# Behaviors:
#   - Tests against regex: ^[A-Za-z0-9+/=]+$
#
# Returns:
#   0 if matches; 1 otherwise.
################################################################################
looks_like_b64() {
    local s="$1"
    [[ "$s" =~ ^[A-Za-z0-9+/=]+$ ]]
}

################################################################################
# load_env_file()
# Description:
#   Load environment variables from a .env file into the current shell.
#
# Behaviors:
#   - Uses provided path or falls back to ENV_FILE or $N8N_DIR/.env.
#   - Warns and no-ops if file does not exist.
#
# Returns:
#   0 on success or when file missing (no-op); non-zero on source errors.
################################################################################
load_env_file() {
  local f="${1:-${ENV_FILE:-}}"
  [[ -z "$f" ]] && f="${N8N_DIR:-$PWD}/.env"
  [[ -f "$f" ]] || { log INFO "No .env to load at: $f (skip)"; return 0; }
  set -o allexport
  # shellcheck disable=SC1090
  source "$f"
  set +o allexport
}

################################################################################
# read_env_var()
# Description:
#   Read and print the value of KEY from a .env-style file.
#
# Behaviors:
#   - Ignores blank lines and full-line comments.
#   - Supports unquoted, single-quoted, and double-quoted values.
#   - Trims inline comments for unquoted values.
#   - Only the first '=' is treated as the separator.
#
# Returns:
#   0 if key found (prints value); 1 if file missing or key not found.
################################################################################
read_env_var() { # usage: read_env_var /path/.env KEY
    local file="$1" key="$2" line val
    [[ -f "$file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip Windows CR
        line="${line%$'\r'}"
        # skip blanks and full-line comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # match KEY=... (first '=' only)
        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            # trim leading spaces
            val="${val#"${val%%[![:space:]]*}"}"

            if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
                # double-quoted value, strip quotes and unescape \"
                val="${BASH_REMATCH[1]}"
                val="${val//\\\"/\"}"

            elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
                # single-quoted value, strip quotes
                val="${BASH_REMATCH[1]}"

            else
                # unquoted → cut trailing inline comment and trim
                val="${val%%#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi

            printf '%s\n' "$val"
            return 0
        fi
    done < "$file"

    return 1
}

################################################################################
# ensure_encryption_key_exists()
# Description:
#   Verify N8N_ENCRYPTION_KEY exists in the given .env and looks reasonable.
#
# Behaviors:
#   - Reads N8N_ENCRYPTION_KEY via read_env_var().
#   - ERROR if missing; WARN if not base64-like.
#   - Logs masked key on success.
#
# Returns:
#   0 if present; 1 if missing.
################################################################################
ensure_encryption_key_exists() {
    local env_file="$1"
    local key
    key="$(read_env_var "$env_file" N8N_ENCRYPTION_KEY || true)"
    if [[ -z "$key" ]]; then
        log ERROR "N8N_ENCRYPTION_KEY is missing in $env_file. Aborting to avoid an unrecoverable restore."
        return 1
    fi
    if ! looks_like_b64 "$key"; then
        log WARN "N8N_ENCRYPTION_KEY in $env_file does not look like base64. Continue at your own risk."
    fi
    log INFO "N8N_ENCRYPTION_KEY present (masked): $(mask_secret "$key")"
}

################################################################################
# parse_domain_arg()
# Description:
#   Normalize and validate a domain/hostname string.
#
# Behaviors:
#   - Lowercases; strips scheme, path, query, fragment, port, trailing dot, and www.
#   - Validates against strict hostname regex and overall length.
#   - Prints normalized domain on success.
#
# Returns:
#   0 on success (prints domain); exits 2 on invalid input.
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
# Description:
#   Wrapper around `docker compose` that always supplies --env-file and -f.
#
# Behaviors:
#   - Requires ENV_FILE and COMPOSE_FILE to be set.
#   - Forwards all additional arguments to `docker compose`.
#
# Returns:
#   Exit code from `docker compose`; 1 if ENV_FILE/COMPOSE_FILE unset.
################################################################################
# Expect: ENV_FILE, COMPOSE_FILE set by caller scripts.
compose() {
    if [[ -z "${COMPOSE_FILE:-}" || -z "${ENV_FILE:-}" ]]; then
        log ERROR "compose(): COMPOSE_FILE/ENV_FILE not set"; return 1
    fi
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

################################################################################
# strict_env_check()
# Description:
#   Validate that all ${VARS} used in compose file exist in the .env file.
#
# Behaviors:
#   - Extracts ${VAR} tokens from compose file.
#   - Builds a set of keys present in .env (ignores comments/blank).
#   - Logs missing variables, if any.
#
# Returns:
#   0 if all present; 1 if any are missing or .env is missing.
################################################################################
strict_env_check() {
    local compose_file="$1" env_file="$2"
    [[ -f "$env_file" ]] || { log ERROR ".env file not found at $env_file"; return 1; }

    log INFO "Checking for unset environment variables in $compose_file..."
    local vars_in_compose missing_vars=()
	# Extract VAR from ${VAR}, ${VAR:-...}, ${VAR?err}, etc.
	vars_in_compose=$(grep -oP '\$\{\K[A-Za-z_][A-Za-z0-9_]*(?=[^}]*)' "$compose_file" | sort -u)

    # Build KEY set from .env (ignore comments/blank). Accept: KEY=..., no "export".
	
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
# Description:
#   Run strict_env_check and `compose config` to catch unset Vars/syntax errors.
#
# Behaviors:
#   - Verifies COMPOSE_FILE and ENV_FILE exist.
#   - Fails if strict_env_check reports missing keys.
#   - Runs `compose config` and checks for "variable is not set" or errors.
#
# Returns:
#   0 if valid; 1 on any validation error.
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
# dump_service_logs()
# Description:
#   Print the last N log lines for a specific compose service.
#
# Behaviors:
#   - Resolves service container ID via compose.
#   - Runs `docker logs --tail <N>` if container exists; warns if not found.
#
# Returns:
#   0 always.
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
# dump_unhealthy_container_logs()
# Description:
#   For all containers in the compose project, print logs for non-running/unhealthy ones.
#
# Behaviors:
#   - Iterates `compose ps -q` containers.
#   - Inspects state and health; prints last logs for offenders.
#
# Returns:
#   0 always.
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
# wait_for_containers_healthy()
# Description:
#   Wait until all compose containers are running and healthy (or timeout).
#
# Behaviors:
#   - Polls every <interval> seconds (default 10) up to <timeout> (default 180).
#   - Logs per-container status each cycle.
#   - On timeout, lists offenders and dumps their logs.
#
# Returns:
#   0 if all healthy before timeout; 1 on timeout.
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
# Description:
#   Wait until a specific container is running and healthy (or timeout).
#
# Behaviors:
#   - Resolves container by compose service name, falling back to docker ps by name.
#   - Accepts health "none" or "healthy" as OK when status is "running".
#   - Polls every <interval> seconds until <timeout>.
#
# Returns:
#   0 if healthy; 1 on timeout or not found.
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
#   Lightweight post-deploy TLS check: confirm HTTPS reaches Traefik (valid TLS)
#   and (best-effort) log issuer/subject/dates via openssl.
#
# Behavior:
#   - DNS hint (A/AAAA) if `dig` is available.
#   - Treats HTTPS status 200/301/302/308/404 as success (TLS OK even if 404).
#   - Retries HTTPS up to 6 times with short delays.
#   - Tries to read and log certificate issuer/subject/notBefore/notAfter.
#   - Cert introspection is best-effort; failure to parse does NOT fail the check.
#
# Returns:
#   0 on HTTPS success (TLS established), regardless of cert introspection result.
#   1 only if HTTPS cannot be reached after retries.
################################################################################
verify_traefik_certificate() {
    local domain="${1:-${DOMAIN:-}}"
    local MAX_RETRIES="${2:-6}"
    local SLEEP_INTERVAL="${3:-10}"
    local domain_url curl_rc http_code success=false

    if [[ -z "$domain" ]]; then
        log ERROR "verify_traefik_certificate: domain is empty"
        return 1
    fi
    domain_url="https://${domain}"

    # DNS A/AAAA (optional)
    if command -v dig >/dev/null 2>&1; then
        log INFO "DNS A records for ${domain}:"
        dig +short A "$domain" | sed 's/^/  - /' || true
        log INFO "DNS AAAA records for ${domain}:"
        dig +short AAAA "$domain" | sed 's/^/  - /' || true
    else
        log WARN "'dig' not found; skipping DNS details."
    fi

    log INFO "Checking HTTPS reachability (valid chain required by curl)…"
    for ((i=1; i<=MAX_RETRIES; i++)); do
        # --fail makes curl exit non-zero on HTTP >= 400 and TLS/conn errors
        if http_code="$(curl -fsS -o /dev/null -w '%{http_code}' \
                         --connect-timeout 5 --max-time 15 \
                         "${domain_url}")"; then
            # Consider TLS OK if HTTP is up: 200/301/302/308/404
            if [[ "$http_code" =~ ^(200|301|302|308|404)$ ]]; then
                log INFO "HTTPS reachable (HTTP ${http_code}) [attempt ${i}/${MAX_RETRIES}]"
                success=true
                break
            else
                log WARN "HTTPS up but app not ready yet (HTTP ${http_code}) [attempt ${i}/${MAX_RETRIES}]"
            fi
        else
            curl_rc=$?
            # When curl fails, http_code will usually be empty or "000"
            log WARN "HTTPS not ready (curl_exit=${curl_rc}, http=${http_code:-N/A}) [attempt ${i}/${MAX_RETRIES}]"
        fi
        [[ $i -lt $MAX_RETRIES ]] && { log INFO "Retrying in ${SLEEP_INTERVAL}s..."; sleep "$SLEEP_INTERVAL"; }
    done

    if ! $success; then
        log ERROR "${domain} is not reachable via HTTPS after ${MAX_RETRIES} attempts."
        dump_service_logs traefik 200
        log INFO "Tip: follow live Traefik logs with: docker logs -f traefik"
        return 1
    fi

    # Best-effort cert details (non-fatal)
    if command -v openssl >/dev/null 2>&1; then
        log INFO "Fetching certificate details (best-effort)…"
        local cert_info issuer subject not_before not_after
        cert_info=$(echo | openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
                    | openssl x509 -noout -issuer -subject -dates 2>/dev/null || true)
        if [[ -n "$cert_info" ]]; then
            issuer=$(echo "$cert_info"  | grep '^issuer='   || true)
            subject=$(echo "$cert_info" | grep '^subject='  || true)
            not_before=$(echo "$cert_info"| grep '^notBefore=' || true)
            not_after=$(echo "$cert_info" | grep '^notAfter='  || true)
            [[ -n "$issuer"     ]] && log INFO "Issuer: $issuer"
            [[ -n "$subject"    ]] && log INFO "Subject: $subject"
            [[ -n "$not_before" ]] && log INFO "Valid from: ${not_before#notBefore=}"
            [[ -n "$not_after"  ]] && log INFO "Valid till:  ${not_after#notAfter=}"
        else
            log WARN "Could not parse certificate via openssl (continuing)."
        fi
    else
        log WARN "'openssl' not found; skipping certificate inspection."
    fi

    return 0
}

################################################################################
# get_current_n8n_version()
# Description:
#   Print the running n8n version by exec'ing into the n8n container.
#
# Behaviors:
#   - Tries `compose ps -q n8n`; falls back to `docker exec n8n`.
#   - Prints "unknown" if not available.
#
# Returns:
#   0 always (prints version or "unknown").
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
# Description:
#   Fetch the latest stable semver tag (x.y.z) of n8n from Docker Hub.
#
# Behaviors:
#   - Requests tags page and filters stable semver names.
#   - Prints the newest version (by sort -Vr | head -n1).
#
# Returns:
#   0 on success (may print empty on API issues); 1 if jq missing.
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
# Description:
#   Retrieve and print all stable semver tags (x.y.z) from Docker Hub.
#
# Behaviors:
#   - Requires jq.
#   - Follows pagination; aggregates results.
#   - Prints unique ascending-sorted list.
#
# Returns:
#   0 on success (even if none found); 1 if jq missing.
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
# Description:
#   Start the compose stack in detached mode via the compose wrapper.
#
# Behaviors:
#   - Logs start message then runs `compose up -d`.
#
# Returns:
#   Exit code from `compose up -d`.
################################################################################
docker_compose_up() {
    log INFO "Starting Docker Compose..."
    compose up -d
}

################################################################################
# check_services_up_running()
# Description:
#   High-level health gate for the stack: containers + TLS certificate.
#
# Behaviors:
#   - Calls wait_for_containers_healthy().
#   - Calls verify_traefik_certificate "$DOMAIN".
#   - Logs ERROR and returns non-zero on any failure.
#
# Returns:
#   0 if all checks pass; 1 otherwise.
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
