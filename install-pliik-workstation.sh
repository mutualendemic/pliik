
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Pliik Workstation - Termux ARM64 installer
#
# Installs:
#   - Pliik repository
#   - VS-CODE-IN-TERMUX reference repository
#   - termux-qemu-docker
#   - Alpine Linux VM
#   - Docker
#   - Code Server
#
# Go compatibility:
#   - Uses Termux's installed Go toolchain
#   - Disables automatic toolchain downloads
#   - Pins dependencies to Go 1.23-compatible versions
# ============================================================

APP_NAME="Pliik Workstation"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_DISTRO_TAG="${PROOT_DISTRO_TAG:-24.04}"

is_termux() {
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ]; then
        return 0
    fi
    return 1
}

is_alpine() {
    if [ -f "/etc/alpine-release" ] || command -v apk >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

bootstrap_proot_distro() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        return 0
    fi

    if ! is_termux; then
        return 0
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

    if ! proot-distro list 2>/dev/null | grep -Eq "^${PROOT_DISTRO}($|[[:space:]])"; then
        if [ -n "${PROOT_DISTRO_TAG}" ] && [ "${PROOT_DISTRO_TAG}" != "latest" ]; then
            log "Installing ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro..."
            proot-distro install "${PROOT_DISTRO}:${PROOT_DISTRO_TAG}" || fail "Failed to install ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro."
        else
            log "Installing ${PROOT_DISTRO} via proot-distro..."
            proot-distro install "${PROOT_DISTRO}" || fail "Failed to install ${PROOT_DISTRO} via proot-distro."
        fi
    fi

    export PLIIK_PROOT_BOOTSTRAP=1

    log "Re-entering installer inside ${PROOT_DISTRO} proot..."
    exec proot-distro login "${PROOT_DISTRO}" -- bash -lc '
        if [ ! -d /root/pliik ]; then
            git clone https://github.com/mutualendemic/pliik.git /root/pliik || exit 1
        fi
        cd /root/pliik || exit 1
        bash install-pliik-workstation.sh "$@"
    ' -- "$@"
}

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
QEMU_DIR="$BASE_DIR/termux-qemu-docker"

CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

BIN_DIR="$PREFIX/bin"
QEMU_BIN="$BIN_DIR/termux-qemu-docker"

ENV_FILE="$CONFIG_DIR/.env"
OPENSSL_BIN=""
PORTAL_BIN="$BIN_DIR/pliik-portal"
PORTAL_PORT=8080
CODE_SERVER_BACKEND_PORT=18080

PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
VSCODE_REPO="https://github.com/Skynetfc/VS-CODE-IN-TERMUX.git"
QEMU_REPO="https://github.com/luisdavim/termux-qemu-docker.git"

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
        log "Skipping the QEMU-based Termux workflow and using the native Alpine Docker path instead."
        log "Run the project inside this Alpine environment directly; do not invoke the Termux QEMU installer here."
        exit 0
    fi

    log "Detected Alpine environment without Docker."
    log "Install Docker within Alpine and rerun the installer: apk add docker openrc && rc-service docker start"
    exit 1
fi

if is_termux; then
    bootstrap_proot_distro
fi

if ! is_termux; then
    if command -v docker >/dev/null 2>&1; then
        log "Native Docker detected. Skipping the Termux QEMU setup path."
        log "This installer is optimized for Termux; local Docker environments should run Docker commands directly."
        exit 0
    fi

    warn "Neither Termux nor Docker was detected. This installer expects a Termux environment or a local Docker-capable workstation."
    exit 1
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
    pkg install -y openssl openssl-tool || {
        log "First OpenSSL install attempt failed; refreshing package metadata and retrying"
        pkg update -y || true
        pkg install -y openssl openssl-tool || fail "OpenSSL packages could not be installed."
    }

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
    fail "Run this script inside Termux."
fi

case "$PREFIX" in
    /data/data/com.termux/files/usr) ;;
    *) fail "Unsupported Termux installation." ;;
esac

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

log "Enabling required Termux repositories"

pkg install -y root-repo

log "Updating Termux"

pkg update -y

log "Upgrading installed packages"

pkg upgrade -y

log "Installing required packages"

pkg install -y \
    git \
    curl \
    wget \
    golang \
    openssl \
    openssl-tool \
    openssh \
    coreutils \
    findutils \
    grep \
    sed \
    tar

# ------------------------------------------------------------
# Go configuration
# ------------------------------------------------------------

log "Checking local Go version"

if ! command -v go >/dev/null 2>&1; then
    fail "Go was not installed."
fi

GO_VERSION="$(go env GOVERSION)"

log "Installed Go: $GO_VERSION"

GO_VERSION_NUMBER="${GO_VERSION#go}"

GO_MAJOR="${GO_VERSION_NUMBER%%.*}"
GO_REMAINDER="${GO_VERSION_NUMBER#*.}"
GO_MINOR="${GO_REMAINDER%%.*}"

if [ "$GO_MAJOR" -lt 1 ] ||
   { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 23 ]; }; then
    fail "Go 1.23 or newer is required. Installed: $GO_VERSION"
fi

# Never attempt to download a different Go toolchain.
export GOTOOLCHAIN=local

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

if [ -d "$PLIIK_DIR/.git" ]; then
    safe_git_pull "$PLIIK_DIR"
fi
clone_or_update "$PLIIK_REPO" "$PLIIK_DIR"

log "Downloading VS-CODE-IN-TERMUX"

if [ -d "$VSCODE_DIR/.git" ]; then
    safe_git_pull "$VSCODE_DIR"
fi
clone_or_update "$VSCODE_REPO" "$VSCODE_DIR"

log "Downloading QEMU Docker"

if [ -d "$QEMU_DIR/.git" ]; then
    safe_git_pull "$QEMU_DIR"
fi
clone_or_update "$QEMU_REPO" "$QEMU_DIR"

# ------------------------------------------------------------
# Patch QEMU Go dependencies
# ------------------------------------------------------------

log "Preparing QEMU Docker Go compatibility"

cd "$QEMU_DIR"

if [ ! -f go.mod ]; then
    fail "QEMU repository does not contain go.mod."
fi

# Docker runs inside the VM, so the unavailable Termux host package is not needed.
if [ -f "pkg/setup/setup.go" ]; then
    sed -i '/packages := \[\]string{/,/}/ s/, "docker"//' pkg/setup/setup.go
    if sed -n '/packages := \[\]string{/,/}/p' pkg/setup/setup.go | grep -q '"docker"'; then
        fail "Could not remove the unavailable docker package from QEMU setup requirements."
    fi
fi

# The upstream go.mod currently requests Go 1.27.0.
# Termux may not be able to download that Android toolchain.
#
# Use the locally installed Go compiler and compatible
# dependency versions instead.

go mod edit -go=1.23.0 -toolchain=none

go mod edit \
    -require=github.com/GehirnInc/crypt@v0.0.0-20230320061759-8cc1b52080c5 \
    -require=github.com/spf13/cobra@v1.9.1 \
    -require=github.com/spf13/pflag@v1.0.6 \
    -require=github.com/inconshreveable/mousetrap@v1.1.0 \
    -require=golang.org/x/crypto@v0.38.0 \
    -require=golang.org/x/term@v0.32.0 \
    -require=golang.org/x/sys@v0.33.0 \
    -require=gopkg.in/yaml.v3@v3.0.1

log "Downloading compatible Go dependencies"

GOTOOLCHAIN=local go mod tidy

# ------------------------------------------------------------
# Build QEMU Docker
# ------------------------------------------------------------

log "Building termux-qemu-docker"

GOTOOLCHAIN=local go build \
    -mod=mod \
    -o "$QEMU_BIN" \
    main.go

if [ ! -x "$QEMU_BIN" ]; then
    fail "QEMU Docker binary was not generated."
fi

log "QEMU Docker successfully built"

# ------------------------------------------------------------
# Configure QEMU Docker
# ------------------------------------------------------------

log "Running QEMU Docker setup"

# Some Termux packages, including docker, live in the root-repo repository.
# Ensure the repo is enabled before the upstream setup script invokes pkg.
pkg install -y root-repo
pkg update -y

"$QEMU_BIN" setup

# ------------------------------------------------------------
# Start virtual machine
# ------------------------------------------------------------

QEMU_HOME="$HOME/.termux-qemu-docker"
VM_PID_FILE="$QEMU_HOME/vm-default.pid"
VM_LOG_FILE="$QEMU_HOME/qemu-default.log"
QEMU_CMD_TIMEOUT="30"
DOCKER_CMD_TIMEOUT="180"
DOCKER_PULL_TIMEOUT="600"

run_qemu_cmd() {
    local timeout_seconds="${1:-$QEMU_CMD_TIMEOUT}"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$QEMU_BIN" "$@"
    else
        "$QEMU_BIN" "$@"
    fi
}

qemu_docker_cmd() {
    local timeout_seconds="${1:-$DOCKER_CMD_TIMEOUT}"
    shift

    run_qemu_cmd "$timeout_seconds" docker "$@"
}

qemu_diagnostics() {
    local stage="${1:-unknown}"

    warn "QEMU diagnostic snapshot (stage: $stage)"
    warn "QEMU binary: $QEMU_BIN"
    warn "QEMU home: $QEMU_HOME"
    warn "Profile status: ${VM_STATUS:-unknown}"

    if [ -f "$VM_PID_FILE" ]; then
        local pid
        pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
        warn "PID file present: ${pid:-missing}"
        if [ -n "$pid" ]; then
            warn "PID process detail: $(ps -p "$pid" -o pid=,comm=,args= 2>/dev/null || echo 'not running')"
        fi
    else
        warn "PID file not present: $VM_PID_FILE"
    fi

    if [ -f "$VM_LOG_FILE" ]; then
        warn "Recent QEMU log entries:"
        tail -n 50 "$VM_LOG_FILE" >&2 || true
    else
        warn "QEMU log file not found: $VM_LOG_FILE"
    fi

    warn "QEMU home listing:"
    ls -la "$QEMU_HOME" 2>&1 || true

    warn "Process scan:"
    pgrep -af 'qemu-system|termux-qemu-docker|dockerd|alpine' || true
}

qemu_docker_ready() {
    local output
    output="$(qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" info 2>&1 || true)"

    if printf '%s\n' "$output" | grep -q 'Server Version:'; then
        return 0
    fi

    if printf '%s\n' "$output" | grep -Eq 'timed out|timeout|failed to connect|Cannot connect'; then
        warn "Docker readiness probe reported a timeout or connection failure: $output"
    fi

    return 1
}

log "Checking QEMU Docker VM status"

VM_STATUS="$(run_qemu_cmd "$QEMU_CMD_TIMEOUT" status 2>&1 || true)"
printf '%s\n' "$VM_STATUS"

if [ -f "$VM_PID_FILE" ]; then
    pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        warn "PID file references a stale process; clearing it before restart"
        rm -f "$VM_PID_FILE"
    else
        log "Default profile PID file present: ${pid:-unknown}"
    fi
fi

if printf '%s\n' "$VM_STATUS" | grep -q 'is RUNNING'; then
    log "QEMU Docker VM is already running; reusing it"
elif printf '%s\n' "$VM_STATUS" | grep -q 'is STALE'; then
    log "QEMU Docker VM PID is stale; clearing it and restarting"
    if [ -f "$VM_PID_FILE" ]; then
        stale_pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            warn "Killing stale QEMU process $stale_pid before restart"
            kill "$stale_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$VM_PID_FILE"
    run_qemu_cmd "$QEMU_CMD_TIMEOUT" start
elif qemu_docker_ready; then
    log "QEMU Docker VM is already healthy; reusing it"
else
    log "Starting QEMU Docker VM"
    if ! run_qemu_cmd "$QEMU_CMD_TIMEOUT" start; then
        qemu_diagnostics "start-failed"
        fail "QEMU Docker VM failed to start within ${QEMU_CMD_TIMEOUT}s. See the diagnostics above for the exact VM and log state."
    fi
fi

# ------------------------------------------------------------
# Wait for Docker daemon
# ------------------------------------------------------------

log "Waiting for Docker daemon"

ELAPSED=0
DOCKER_READY=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do

    if qemu_docker_ready; then
        DOCKER_READY=1
        break
    fi

    printf '\r[PLIIK] Waiting for Docker... %s/%s seconds' \
        "$ELAPSED" "$MAX_WAIT"

    sleep "$WAIT_INTERVAL"

    ELAPSED=$((ELAPSED + WAIT_INTERVAL))

done

printf '\n'

if [ "$DOCKER_READY" -ne 1 ]; then
    warn "QEMU VM status:"
    "$QEMU_BIN" status || true
    qemu_diagnostics "docker-not-ready"

    fail "Docker daemon did not become ready."
fi

log "Docker daemon is ready"

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
# Download Code Server image
# ------------------------------------------------------------

log "Downloading Code Server image"

if ! qemu_docker_cmd "$DOCKER_PULL_TIMEOUT" pull "$CODE_SERVER_IMAGE"; then
    fail "Code Server image download timed out or failed in the QEMU Docker VM."
fi

# ------------------------------------------------------------
# Remove previous container
# ------------------------------------------------------------

log "Removing previous Code Server container if present"

if ! qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
    warn "Could not remove any existing Code Server container cleanly; continuing."
fi

# ------------------------------------------------------------
# Deploy Code Server
# ------------------------------------------------------------

log "Deploying Code Server"

if ! qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${CODE_SERVER_PORT}:8080" \
    -e "PASSWORD=${CODE_SERVER_PASSWORD}" \
    -v "${PROJECTS_DIR}:/home/coder/project" \
    "$CODE_SERVER_IMAGE"; then
    fail "Code Server container startup timed out or failed in the QEMU Docker VM."
fi

# ------------------------------------------------------------
# Create management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

STATUS="$(timeout 30s termux-qemu-docker status 2>&1 || true)"
if printf '%s\n' "$STATUS" | grep -q 'is RUNNING'; then
    echo "QEMU VM already running; reusing it."
elif printf '%s\n' "$STATUS" | grep -q 'is STALE'; then
    echo "QEMU VM status is stale; cleaning up PID file."
    rm -f "$HOME/.termux-qemu-docker/vm-default.pid"
    timeout 30s termux-qemu-docker start || true
else
    timeout 30s termux-qemu-docker start || true
fi

for i in $(seq 1 120); do
    if timeout 30s termux-qemu-docker docker info >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

timeout 30s termux-qemu-docker docker start pliik-code-server || true

echo "Code Server: http://localhost:8080"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

timeout 30s termux-qemu-docker docker stop pliik-code-server || true
timeout 30s termux-qemu-docker stop || true
rm -f "$HOME/.termux-qemu-docker/vm-default.pid" || true

echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

echo "=== QEMU VM ==="
timeout 30s termux-qemu-docker status || true

echo
echo "=== Docker containers ==="
timeout 30s termux-qemu-docker docker ps -a || true

echo
echo "Code Server: http://localhost:8080"
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
echo "QEMU Docker:     $QEMU_BIN"
echo
echo "Code Server:"
echo "  http://localhost:8080"
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
