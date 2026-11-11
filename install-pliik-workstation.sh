
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Pliik Workstation - Termux ARM64 installer
#
# Installs:
#   - Pliik repository
#   - VS-CODE-IN-TERMUX reference repository
#   - Docker + Docker Compose runtime
#   - Code Server container
#
# Docker Compose path:
#   - Installs the direct Docker runtime in the Ubuntu proot environment
#   - Uses docker-compose or docker compose for the Pliik stack
#   - Avoids the old QEMU helper flow entirely
# ============================================================

APP_NAME="Pliik Workstation"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_DISTRO_TAG="${PROOT_DISTRO_TAG:-24.04}"

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    export PREFIX="/usr"
    export TERMUX__PREFIX="/usr"
fi

is_termux() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        return 1
    fi

    if [ -f /etc/os-release ] && grep -Eq '^(ID|NAME)=(ubuntu|debian|alpine)' /etc/os-release 2>/dev/null; then
        return 1
    fi

    if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ]; then
        return 0
    fi
    return 1
}

debug_environment() {
    log "Environment debug snapshot"
    printf 'TERMUX_VERSION=%s\n' "${TERMUX_VERSION:-unset}"
    printf 'PLIIK_PROOT_BOOTSTRAP=%s\n' "${PLIIK_PROOT_BOOTSTRAP:-0}"
    printf 'PREFIX=%s\n' "${PREFIX:-unset}"
    printf 'USER=%s\n' "${USER:-$(id -un 2>/dev/null || echo unknown)}"
    printf 'UID=%s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf 'PATH=%s\n' "$PATH"
    printf 'OS_RELEASE=%s\n' "$(grep -E '^NAME=' /etc/os-release 2>/dev/null | head -n 1 || echo 'not-found')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || echo 'unknown')"
    printf 'termux_dir_exists=%s\n' "$(if [ -d /data/data/com.termux/files/usr ]; then echo yes; else echo no; fi)"
    printf 'pkg_path=%s\n' "$(command -v pkg 2>/dev/null || echo not-found)"
    printf 'proot_distro_path=%s\n' "$(command -v proot-distro 2>/dev/null || echo not-found)"
    printf 'is_termux=%s\n' "$(if is_termux; then echo yes; else echo no; fi)"
    printf 'is_alpine=%s\n' "$(if is_alpine; then echo yes; else echo no; fi)"
}

is_alpine() {
    if [ -f "/etc/alpine-release" ] || command -v apk >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ensure_regular_termux_user() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        return 0
    fi

    if is_termux && [ "$(id -u)" -eq 0 ]; then
        debug_environment
        fail "This installer must run as the regular Termux user. Exit the root shell and re-run it without sudo."
    fi
}

proot_distro_exists() {
    local name="${1:-${PROOT_DISTRO}}"
    local list_output
    local installed_output
    local list_status
    local escape_sequence=$'\033'

    if list_output="$(proot-distro list 2>&1)"; then
        list_status=0
    else
        list_status=$?
    fi

    list_output="$(printf '%s\n' "$list_output" | tr -d '\r' | sed "s/${escape_sequence}\\[[0-9;]*[[:alpha:]]//g")"
    if [ "$list_status" -ne 0 ]; then
        warn "proot-distro list failed with exit status ${list_status} while checking '${name}'. Output:"
        printf '%s\n' "${list_output:-<no output>}" >&2
        return 1
    fi

    if [ -z "$list_output" ]; then
        warn "proot-distro list returned no output while checking '${name}'."
        return 1
    fi

    installed_output="$(printf '%s\n' "$list_output" | sed -n \
        -e '/^[[:space:]]*Installed containers:/,/^[[:space:]]*Supported distributions:/p' \
        -e '/^[[:space:]]*Installed distributions:/,/^[[:space:]]*Supported distributions:/p')"
    if [ -z "$installed_output" ]; then
        warn "No installed-container section was recognized while checking '${name}'. Normalized proot-distro list output:"
        printf '%s\n' "$list_output" >&2
        return 1
    fi

    if printf '%s\n' "$installed_output" | tr -cs '[:alnum:]_-' '\n' | grep -Fixq -- "$name"; then
        return 0
    fi

    warn "Container '${name}' was not found in the installed section. Normalized proot-distro list output:"
    printf '%s\n' "$list_output" >&2
    return 1
}

validate_proot_distro_container() {
    local name="${1:-${PROOT_DISTRO}}"

    if ! proot_distro_exists "$name"; then
        return 1
    fi

    if proot-distro login "$name" -- bash -lc 'test -f /etc/os-release && test -d /root'; then
        return 0
    fi

    warn "Existing proot container '${name}' failed validation. It will not be reset or removed automatically."
    return 1
}

bootstrap_proot_distro() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        log "Already running inside the ${PROOT_DISTRO} proot bootstrap; continuing with the Docker Compose path."
        return 0
    fi

    if ! is_termux; then
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        fail "Do not run proot-distro as root. Exit the root shell and run this installer as the regular Termux user."
    fi

    if command -v proot-distro >/dev/null 2>&1; then
        log "proot-distro detected. Ensuring ${PROOT_DISTRO} is present..."
    else
        log "Installing proot-distro in Termux..."
        pkg install -y proot-distro tar || fail "Failed to install proot-distro."
    fi

    if proot-distro list 2>/dev/null | grep -q 'alpine'; then
        log "Removing stale Alpine container before installing ${PROOT_DISTRO}."
        proot-distro remove alpine || true
    fi

    if proot_distro_exists "${PROOT_DISTRO}"; then
        if validate_proot_distro_container "${PROOT_DISTRO}"; then
            log "${PROOT_DISTRO} container is already present and valid; reusing it."
        else
            if [ -n "${PROOT_DISTRO_TAG}" ] && [ "${PROOT_DISTRO_TAG}" != "latest" ]; then
                fail "Existing '${PROOT_DISTRO}' cannot be entered. Close active proot sessions, then as the regular Termux user run: proot-distro remove ${PROOT_DISTRO} && proot-distro install ${PROOT_DISTRO}:${PROOT_DISTRO_TAG}"
            else
                fail "Existing '${PROOT_DISTRO}' cannot be entered. Close active proot sessions, then as the regular Termux user run: proot-distro remove ${PROOT_DISTRO} && proot-distro install ${PROOT_DISTRO}"
            fi
        fi
    else
        if [ -n "${PROOT_DISTRO_TAG}" ] && [ "${PROOT_DISTRO_TAG}" != "latest" ]; then
            log "Installing ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro..."
            if ! proot-distro install "${PROOT_DISTRO}:${PROOT_DISTRO_TAG}"; then
                if proot_distro_exists "${PROOT_DISTRO}"; then
                    log "The container became available after the failed install attempt; continuing."
                else
                    fail "Failed to install ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro."
                fi
            fi
        else
            log "Installing ${PROOT_DISTRO} via proot-distro..."
            if ! proot-distro install "${PROOT_DISTRO}"; then
                if proot_distro_exists "${PROOT_DISTRO}"; then
                    log "The container became available after the failed install attempt; continuing."
                else
                    fail "Failed to install ${PROOT_DISTRO} via proot-distro."
                fi
            fi
        fi
    fi

    export PLIIK_PROOT_BOOTSTRAP=1

    log "Re-entering installer inside ${PROOT_DISTRO} proot..."
    exec env PLIIK_PROOT_BOOTSTRAP=1 PROOT_DISTRO="${PROOT_DISTRO}" proot-distro login "${PROOT_DISTRO}" -- bash -lc '
        export PLIIK_PROOT_BOOTSTRAP=1
        export PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
        if ! command -v git >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates || {
                printf "[ERROR] Could not install git and CA certificates inside the proot.\n" >&2
                exit 1
            }
        fi
        if [ ! -d /root/pliik ]; then
            git clone https://github.com/mutualendemic/pliik.git /root/pliik || exit 1
        else
            git -C /root/pliik pull --ff-only origin main || {
                printf "[ERROR] Could not update /root/pliik to the latest installer.\n" >&2
                exit 1
            }
        fi
        cd /root/pliik || exit 1
        exec env PLIIK_PROOT_BOOTSTRAP=1 PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}" bash install-pliik-workstation.sh "$@"
    ' -- "$@"
}

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

BIN_DIR="${PREFIX:-/usr/local}/bin"

ENV_FILE="$CONFIG_DIR/.env"
OPENSSL_BIN=""
PORTAL_BIN="$BIN_DIR/pliik-portal"
PORTAL_PORT=8080
CODE_SERVER_BACKEND_PORT=18080

PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
VSCODE_REPO="https://github.com/Skynetfc/VS-CODE-IN-TERMUX.git"

CONTAINER_NAME="pliik-code-server"
CODE_SERVER_PORT=8080
CODE_SERVER_IMAGE="codercom/code-server:latest"

MAX_WAIT=1200
WAIT_INTERVAL=10

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

log() {
    printf '\n[PLIIK] %s\n' "$*"
}

warn() {
    printf '\n[WARNING] %s\n' "$*" >&2
}

fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

# ------------------------------------------------------------
# Environment compatibility
# ------------------------------------------------------------

if is_alpine; then
    if command -v docker >/dev/null 2>&1; then
        log "Detected Alpine proot environment with Docker available."
        log "Using the native Alpine Docker Compose path instead of the Termux QEMU flow."
        log "Run the project inside this Alpine environment directly; do not invoke the legacy Termux installer here."
        exit 0
    fi

    log "Detected Alpine environment without Docker."
    log "Install Docker within Alpine and rerun the installer: apk add docker openrc && rc-service docker start"
    exit 1
fi

if is_termux; then
    ensure_regular_termux_user
    bootstrap_proot_distro
fi

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    log "Running inside the ${PROOT_DISTRO} proot with Docker Compose support."
    export DEBIAN_FRONTEND=noninteractive
    export PREFIX="${PREFIX:-/usr}"
    command -v apt-get >/dev/null 2>&1 || fail "Ubuntu apt-get is required inside the proot environment."
fi

if ! is_termux && [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
    if command -v docker >/dev/null 2>&1; then
        log "Native Docker detected. Using the direct Docker Compose path."
        log "This installer is optimized for Termux; local Docker environments should run Docker Compose directly."
    else
        warn "Neither Termux nor Docker was detected. This installer expects a Termux environment or a local Docker-capable workstation."
        exit 1
    fi
fi

debug_openssl() {
    local candidate
    local version_output
    local random_value
    local package
    local candidates=(
        "${PREFIX:-}/bin/openssl"
        "/data/data/com.termux/files/usr/local/bin/openssl"
        "/data/data/com.termux/files/bin/openssl"
        "/usr/bin/openssl"
        "/bin/openssl"
    )

    log "OpenSSL debug snapshot"
    printf 'SCRIPT=%s\n' "${BASH_SOURCE[0]}"
    printf 'BASH_VERSION=%s\n' "$BASH_VERSION"
    printf 'PREFIX=%s\n' "${PREFIX:-unset}"
    printf 'PATH=%s\n' "$PATH"

    if command -v dpkg-query >/dev/null 2>&1; then
        for package in openssl openssl-tool; do
            if ! dpkg-query -W -f="PACKAGE_STATUS=\${Status} PACKAGE_VERSION=\${Version}\\n" "$package" 2>&1; then
                warn "dpkg-query could not find package: $package"
            fi
        done
    else
        warn "dpkg-query is unavailable; package status could not be checked"
    fi

    if command -v openssl >/dev/null 2>&1; then
        printf 'OPENSSL_FROM_PATH=%s\n' "$(command -v openssl)"
    else
        printf '%s\n' 'OPENSSL_FROM_PATH=not-found'
    fi

    for candidate in "${candidates[@]}"; do
        if [ ! -e "$candidate" ]; then
            printf 'CANDIDATE=%s STATUS=missing\n' "$candidate"
            continue
        fi

        ls -ld "$candidate" 2>&1
        if [ ! -x "$candidate" ]; then
            printf 'CANDIDATE=%s STATUS=not-executable\n' "$candidate"
            continue
        fi

        if version_output="$("$candidate" version 2>&1)"; then
            printf 'CANDIDATE=%s VERSION=%s\n' "$candidate" "$version_output"
        else
            printf 'CANDIDATE=%s VERSION_CHECK=failed OUTPUT=%s\n' "$candidate" "$version_output"
        fi

        if random_value="$("$candidate" rand -hex 24 2>/dev/null)" && [[ "$random_value" =~ ^[[:xdigit:]]{48}$ ]]; then
            printf 'CANDIDATE=%s RAND_CHECK=passed HEX_LENGTH=%s\n' "$candidate" "${#random_value}"
        else
            printf 'CANDIDATE=%s RAND_CHECK=failed\n' "$candidate"
        fi
    done
}

diagnose_openssl() {
    local candidate
    local candidates=()

    debug_openssl

    if command -v openssl >/dev/null 2>&1; then
        candidates+=("$(command -v openssl)")
    fi

    candidates+=(
        "${PREFIX}/bin/openssl"
        "/data/data/com.termux/files/usr/local/bin/openssl"
        "/data/data/com.termux/files/bin/openssl"
        "/usr/bin/openssl"
        "/bin/openssl"
    )

    for candidate in "${candidates[@]}"; do
        OPENSSL_BIN="$candidate"
        if openssl_works; then
            printf 'OPENSSL_DIAGNOSIS=passed BINARY=%s\n' "$OPENSSL_BIN"
            return 0
        fi
    done

    OPENSSL_BIN=""
    printf '%s\n' 'OPENSSL_DIAGNOSIS=failed'
    return 1
}

openssl_works() {
    local random_value

    [ -n "$OPENSSL_BIN" ] && [ -x "$OPENSSL_BIN" ] || return 1
    "$OPENSSL_BIN" version >/dev/null 2>&1 || return 1
    random_value="$("$OPENSSL_BIN" rand -hex 24 2>/dev/null)" || return 1
    [[ "$random_value" =~ ^[[:xdigit:]]{48}$ ]]
}

ensure_openssl() {
    local candidate
    local path_candidates=(
        "/data/data/com.termux/files/usr/bin"
        "/data/data/com.termux/files/usr/local/bin"
        "/data/data/com.termux/files/bin"
        "/usr/bin"
        "/bin"
    )

    OPENSSL_BIN=""
    export PATH="/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/local/bin:/data/data/com.termux/files/bin:/usr/bin:/bin:${PATH}"
    hash -r 2>/dev/null || true

    log "Checking for OpenSSL in: ${path_candidates[*]}"

    for candidate in "${path_candidates[@]}"; do
        if [ -x "$candidate/openssl" ]; then
            OPENSSL_BIN="$candidate/openssl"
            export PATH="$candidate:${PATH}"
            hash -r 2>/dev/null || true
            log "Resolved OpenSSL to $OPENSSL_BIN"
            if openssl_works; then
                return 0
            else
                warn "Resolved OpenSSL failed the version or random-generation check: $OPENSSL_BIN"
                OPENSSL_BIN=""
            fi
        fi
    done

    if command -v openssl >/dev/null 2>&1; then
        OPENSSL_BIN="$(command -v openssl)"
        log "Resolved OpenSSL from PATH to $OPENSSL_BIN"
        if openssl_works; then
            return 0
        fi
        warn "OpenSSL from PATH failed the version or random-generation check: $OPENSSL_BIN"
        OPENSSL_BIN=""
    fi

    log "OpenSSL CLI is missing; installing openssl and openssl-tool"
    if is_termux; then
        pkg install -y openssl openssl-tool || {
            log "First OpenSSL install attempt failed; refreshing package metadata and retrying"
            pkg update -y || true
            pkg install -y openssl openssl-tool || fail "OpenSSL packages could not be installed."
        }
    else
        apt-get update -y || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl openssl-tool || fail "OpenSSL packages could not be installed."
    fi

    export PATH="/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/local/bin:/data/data/com.termux/files/bin:/usr/bin:/bin:${PATH}"
    hash -r 2>/dev/null || true

    for candidate in "${path_candidates[@]}"; do
        if [ -x "$candidate/openssl" ]; then
            OPENSSL_BIN="$candidate/openssl"
            export PATH="$candidate:${PATH}"
            hash -r 2>/dev/null || true
            log "Post-install OpenSSL resolved to $OPENSSL_BIN"
            if openssl_works; then
                return 0
            fi
            warn "Installed OpenSSL failed the version or random-generation check: $OPENSSL_BIN"
            OPENSSL_BIN=""
        fi
    done

    if command -v openssl >/dev/null 2>&1; then
        OPENSSL_BIN="$(command -v openssl)"
        log "Post-install OpenSSL from PATH: $OPENSSL_BIN"
        if openssl_works; then
            return 0
        fi
        warn "Installed OpenSSL from PATH failed the version or random-generation check: $OPENSSL_BIN"
        OPENSSL_BIN=""
    fi

    debug_openssl
    fail "OpenSSL is unavailable or failed validation after installation."
}

# ------------------------------------------------------------
# Check Termux
# ------------------------------------------------------------

log "Checking Termux environment"

if command -v git >/dev/null 2>&1; then
    log "Git version: $(git --version 2>/dev/null || echo 'unknown')"
else
    log "Git version: not installed"
fi

if [ -z "${PREFIX:-}" ]; then
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
        debug_environment
        fail "Run this script inside Termux."
    fi
fi

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
    case "$PREFIX" in
        /data/data/com.termux/files/usr) ;;
        *)
            debug_environment
            fail "Unsupported Termux installation."
            ;;
    esac
fi

if [[ "${1:-}" == "--diagnose-openssl" ]]; then
    if diagnose_openssl; then
        exit 0
    else
        exit 1
    fi
fi

mkdir -p \
    "$BASE_DIR" \
    "$CONFIG_DIR" \
    "$PROJECTS_DIR"

# ------------------------------------------------------------
# Local repo recovery for stale checkouts
# ------------------------------------------------------------

safe_git_pull() {
    local repo_dir="$1"
    local repo_name="$(basename "$repo_dir")"
    local upstream_ref
    local local_ref

    if [ ! -d "$repo_dir/.git" ]; then
        return 0
    fi

    git -C "$repo_dir" status --porcelain --untracked-files=normal >/dev/null 2>&1 || return 0

    if git -C "$repo_dir" diff --quiet && git -C "$repo_dir" diff --cached --quiet && \
       [ -z "$(git -C "$repo_dir" status --porcelain --untracked-files=normal)" ]; then
        git -C "$repo_dir" pull --ff-only || {
            warn "Could not fast-forward $repo_name; leaving the existing checkout intact."
        }
        return 0
    fi

    if ! git -C "$repo_dir" fetch --quiet; then
        warn "Could not check upstream for $repo_name; preserving the local working tree."
        return 0
    fi

    upstream_ref="$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    local_ref="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$upstream_ref" ] && [ "$local_ref" = "$(git -C "$repo_dir" rev-parse "$upstream_ref" 2>/dev/null || true)" ]; then
        log "$repo_name has local changes but already matches upstream; preserving them without stashing."
        return 0
    fi

    warn "$repo_name has local changes. Stashing them before the update so the installer stays idempotent."
    if git -C "$repo_dir" stash push --include-untracked -m "pliik auto-stash before installer update" >/dev/null 2>&1; then
        log "Stashed local work in $repo_name; retrying the update."
    else
        warn "Could not stash local work in $repo_name; the update will be retried without touching the working tree."
    fi

    if git -C "$repo_dir" pull --ff-only; then
        return 0
    fi

    warn "Could not fast-forward $repo_name after stashing; leaving the checkout intact."
    return 1
}

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    log "Skipping Termux package-manager setup because the installer is already running inside the ${PROOT_DISTRO} proot bootstrap."
elif is_termux; then
    log "Enabling required Termux repositories"
    pkg install -y root-repo

    log "Updating Termux"
    pkg update -y

    log "Upgrading installed packages"
    pkg upgrade -y
fi

log "Installing required packages"

if is_termux; then
    pkg install -y \
        git \
        curl \
        wget \
        openssl \
        openssl-tool \
        openssh \
        coreutils \
        findutils \
        grep \
        sed \
        tar
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        git curl wget ca-certificates openssl openssh-client build-essential \
        docker.io docker-compose \
        coreutils findutils grep sed tar
fi

# ------------------------------------------------------------
# Docker Compose runtime
# ------------------------------------------------------------

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    elif docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        return 127
    fi
}

docker_info_ready() {
    timeout 5s docker info >/dev/null 2>&1
}

start_docker_daemon_if_needed() {
    if docker_info_ready; then
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        timeout 15s service docker start >/dev/null 2>&1 || true
    fi

    if ! docker_info_ready; then
        log "Starting Docker daemon in the background"
        dockerd >/tmp/pliik-dockerd.log 2>&1 &
        local daemon_pid=$!
        local deadline=$((SECONDS + 120))
        local next_report=$((SECONDS + 10))

        for i in $(seq 1 60); do
            if docker_info_ready; then
                return 0
            fi

            if ! kill -0 "$daemon_pid" 2>/dev/null; then
                break
            fi
            if [ "$SECONDS" -ge "$deadline" ]; then
                break
            fi
            if [ "$SECONDS" -ge "$next_report" ]; then
                log "Docker daemon is still starting inside ${PROOT_DISTRO}..."
                next_report=$((SECONDS + 10))
            fi
            sleep 2
        done

        kill "$daemon_pid" 2>/dev/null || true
        warn "Docker daemon did not become ready. Recent dockerd output:"
        tail -n 80 /tmp/pliik-dockerd.log >&2 || true
        fail "Docker daemon could not be started for the Compose installation path."
    fi

    docker_info_ready || fail "Docker daemon could not be started for the Compose installation path."
}

COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"

write_compose_file() {
    cat > "$COMPOSE_FILE" <<EOF
services:
  pliik-code-server:
    image: ${CODE_SERVER_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${CODE_SERVER_PORT}:8080"
    environment:
      PASSWORD: ${CODE_SERVER_PASSWORD}
    volumes:
      - "${PROJECTS_DIR}:/home/coder/project"
EOF
}

log "Ensuring Docker and Docker Compose are available"

if ! docker_compose_cmd version >/dev/null 2>&1; then
    if is_termux; then
        pkg install -y docker docker-compose || fail "Docker and Docker Compose could not be installed in Termux."
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends docker.io docker-compose || fail "Docker and Docker Compose could not be installed in Ubuntu."
    fi
fi

start_docker_daemon_if_needed

# ------------------------------------------------------------
# Clone or update repositories
# ------------------------------------------------------------

clone_or_update() {
    local repo="$1"
    local destination="$2"

    if [ -d "$destination/.git" ]; then

        log "Updating $(basename "$destination")"

        if ! safe_git_pull "$destination"; then
            if [ "$destination" = "$PLIIK_DIR" ]; then
                warn "Pliik checkout remains on the current working tree. Local stash entries were preserved so the job can be retried safely."
                warn "To restore your local work, run: git -C \"$destination\" stash list && git -C \"$destination\" stash pop"
                return 0
            fi
            warn "Update failed. Keeping existing checkout."
        fi

    else

        if [ -e "$destination" ]; then
            fail "$destination exists but is not a Git repository."
        fi

        log "Cloning $(basename "$destination")"

        git clone "$repo" "$destination"

    fi
}

log "Downloading Pliik"
clone_or_update "$PLIIK_REPO" "$PLIIK_DIR"

log "Downloading VS-CODE-IN-TERMUX"
clone_or_update "$VSCODE_REPO" "$VSCODE_DIR"

# ------------------------------------------------------------
# Configure Code Server password
# ------------------------------------------------------------

log "Configuring Code Server"

ensure_openssl

if [ -z "$OPENSSL_BIN" ]; then
    fail "OpenSSL could not be resolved to an executable binary."
fi

if [ ! -f "$ENV_FILE" ]; then
    if ! PASSWORD="$("$OPENSSL_BIN" rand -hex 24 2>/dev/null)"; then
        debug_openssl
        fail "OpenSSL could not generate the Code Server password."
    fi

    if [[ ! "$PASSWORD" =~ ^[[:xdigit:]]{48}$ ]]; then
        debug_openssl
        fail "OpenSSL generated a password with an unexpected format."
    fi

    printf 'CODE_SERVER_PASSWORD=%s\n' "$PASSWORD" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "Generated Code Server password"
fi

# Read existing configuration.
# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${CODE_SERVER_PASSWORD:-}" ]; then
    fail "Code Server password is missing."
fi

# ------------------------------------------------------------
# Deploy Code Server via Docker Compose
# ------------------------------------------------------------

log "Preparing Docker Compose stack"
write_compose_file

log "Pulling Code Server image"
if ! docker_compose_cmd --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull "$CONTAINER_NAME"; then
    warn "Compose pull failed; retrying with the default service name."
    if ! docker_compose_cmd --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull; then
        fail "Code Server image could not be pulled with Docker Compose."
    fi
fi

log "Starting Code Server with Docker Compose"
if ! docker_compose_cmd --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d; then
    fail "Code Server could not be started via Docker Compose."
fi

# ------------------------------------------------------------
# Create management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<EOF
#!/usr/bin/env bash
set -e
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
else
    docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
fi

echo "Code Server: http://localhost:${CODE_SERVER_PORT}"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<EOF
#!/usr/bin/env bash
set -e
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" down
else
    docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" down
fi

echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<EOF
#!/usr/bin/env bash
set -e
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps
else
    docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps
fi

echo
echo "Code Server: http://localhost:${CODE_SERVER_PORT}"
EOF

chmod +x \
    "$BIN_DIR/bin-dev-start" \
    "$BIN_DIR/bin-dev-stop" \
    "$BIN_DIR/bin-dev-status"

# ------------------------------------------------------------
# Installation summary
# ------------------------------------------------------------

log "Installation completed successfully"

echo
echo "============================================"
echo "       Pliik Workstation installed"
echo "============================================"
echo
echo "Workspace:       $BASE_DIR"
echo "Pliik:           $PLIIK_DIR"
echo "Projects:        $PROJECTS_DIR"
echo "Compose file:    $COMPOSE_FILE"
echo
echo "Code Server:"
echo "  http://localhost:${CODE_SERVER_PORT}"
echo
echo "Password:"
echo "  cat $ENV_FILE"
echo
echo "Management:"
echo "  bin-dev-start"
echo "  bin-dev-stop"
echo "  bin-dev-status"
echo
echo "============================================"
