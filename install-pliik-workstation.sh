
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Pliik Workstation - Termux ARM64 installer
#
# Installs:
#   - Pliik repository
#   - VS-CODE-IN-TERMUX reference repository
#   - QEMU Linux guest with Docker runtime
#   - Code Server container
#
# Runtime path:
#   - Builds and runs the QEMU manager in Termux
#   - Runs Docker and Code Server inside its Linux guest
# ============================================================

APP_NAME="Pliik Workstation"
is_termux() {
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
    printf 'PREFIX=%s\n' "${PREFIX:-unset}"
    printf 'USER=%s\n' "${USER:-$(id -un 2>/dev/null || echo unknown)}"
    printf 'UID=%s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf 'PATH=%s\n' "$PATH"
    printf 'OS_RELEASE=%s\n' "$(grep -E '^NAME=' /etc/os-release 2>/dev/null | head -n 1 || echo 'not-found')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || echo 'unknown')"
    printf 'termux_dir_exists=%s\n' "$(if [ -d /data/data/com.termux/files/usr ]; then echo yes; else echo no; fi)"
    printf 'pkg_path=%s\n' "$(command -v pkg 2>/dev/null || echo not-found)"
    printf 'is_termux=%s\n' "$(if is_termux; then echo yes; else echo no; fi)"
}

ensure_regular_termux_user() {
    if is_termux && [ "$(id -u)" -eq 0 ]; then
        debug_environment
        fail "This installer must run as the regular Termux user. Exit the root shell and re-run it without sudo."
    fi
}

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
QEMU_DIR="$BASE_DIR/termux-qemu-docker"
CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

BIN_DIR="${PREFIX:-/usr/local}/bin"
QEMU_BIN="$BIN_DIR/termux-qemu-docker"
QEMU_HOME="$HOME/.termux-qemu-docker"

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

if ! is_termux; then
    debug_environment
    fail "Run this installer from Termux; Docker runs in the QEMU guest."
fi

ensure_regular_termux_user

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

case "${PREFIX:-}" in
    /data/data/com.termux/files/usr) ;;
    *)
        debug_environment
        fail "Unsupported Termux installation."
        ;;
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
# QEMU Docker guest
# ------------------------------------------------------------

QEMU_CMD_TIMEOUT=30
QEMU_START_TIMEOUT=300
DOCKER_CMD_TIMEOUT=180
DOCKER_PROBE_TIMEOUT=15
DOCKER_PULL_TIMEOUT=600

run_qemu_cmd() {
    local timeout_seconds="${1:-$QEMU_CMD_TIMEOUT}"
    shift

    timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$QEMU_BIN" "$@"
}

qemu_docker_cmd() {
    local timeout_seconds="${1:-$DOCKER_CMD_TIMEOUT}"
    shift

    run_qemu_cmd "$timeout_seconds" docker "$@"
}

qemu_diagnostics() {
    warn "QEMU status:"
    run_qemu_cmd "$QEMU_CMD_TIMEOUT" status >&2 || true
    if [ -f "$QEMU_HOME/qemu-default.log" ]; then
        warn "Recent QEMU log entries:"
        tail -n 50 "$QEMU_HOME/qemu-default.log" >&2 || true
    fi
}

qemu_docker_ready() {
    local output
    output="$(qemu_docker_cmd "$DOCKER_PROBE_TIMEOUT" info 2>&1 || true)"

    if printf '%s\n' "$output" | grep -q 'Server Version:'; then
        return 0
    fi

    if printf '%s\n' "$output" | grep -Eq 'timed out|timeout|failed to connect|Cannot connect'; then
        warn "Docker readiness probe failed: $output"
    fi

    return 1
}

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

log "Downloading QEMU Docker"
clone_or_update "$QEMU_REPO" "$QEMU_DIR"

log "Preparing QEMU Docker Go compatibility"
cd "$QEMU_DIR"
[ -f go.mod ] || fail "QEMU repository does not contain go.mod."

GO_VERSION="$(go env GOVERSION)"
GO_VERSION_NUMBER="${GO_VERSION#go}"
GO_MAJOR="${GO_VERSION_NUMBER%%.*}"
GO_REMAINDER="${GO_VERSION_NUMBER#*.}"
GO_MINOR="${GO_REMAINDER%%.*}"
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 27 ]; }; then
    fail "Go 1.27 or newer is required to build the QEMU helper. Installed: $GO_VERSION"
fi
export GOTOOLCHAIN=local

if [ -f pkg/setup/setup.go ]; then
    sed -i '/packages := \[\]string{/,/}/ s/, "docker"//' pkg/setup/setup.go
    if sed -n '/packages := \[\]string{/,/}/p' pkg/setup/setup.go | grep -q '"docker"'; then
        fail "Could not remove the unavailable Docker host package from QEMU setup requirements."
    fi
fi

export GOTOOLCHAIN=local
go mod edit -go=1.27.0 -toolchain=none

log "Resolving QEMU Docker Go dependencies"
GOTOOLCHAIN=local go mod tidy

log "Building termux-qemu-docker"
GOTOOLCHAIN=local go build -mod=mod -o "$QEMU_BIN" main.go
[ -x "$QEMU_BIN" ] || fail "QEMU Docker binary was not generated."

log "Setting up QEMU Docker guest"
pkg install -y root-repo
pkg update -y
"$QEMU_BIN" setup

log "Checking QEMU guest status"
VM_STATUS="$(run_qemu_cmd "$QEMU_CMD_TIMEOUT" status 2>&1 || true)"
printf '%s\n' "$VM_STATUS"
if printf '%s\n' "$VM_STATUS" | grep -q 'is STALE'; then
    rm -f "$QEMU_HOME/vm-default.pid"
    VM_STATUS=""
fi

if ! printf '%s\n' "$VM_STATUS" | grep -q 'is RUNNING'; then
    log "Starting QEMU Docker guest"
    if ! run_qemu_cmd "$QEMU_START_TIMEOUT" start; then
        qemu_diagnostics
        fail "QEMU Docker guest failed to start within ${QEMU_START_TIMEOUT}s."
    fi
fi

log "Waiting for Docker in the QEMU guest"
started_at=$SECONDS
deadline=$((started_at + MAX_WAIT))
docker_ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
    if qemu_docker_ready; then
        docker_ready=1
        break
    fi
    elapsed=$((SECONDS - started_at))
    printf '\r[PLIIK] Waiting for guest Docker... %s/%s seconds' "$elapsed" "$MAX_WAIT"
    sleep "$WAIT_INTERVAL"
done
printf '\n'

if [ "$docker_ready" -ne 1 ]; then
    qemu_diagnostics
    fail "Docker in the QEMU guest did not become ready."
fi
log "Docker in the QEMU guest is ready"

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
# Deploy Code Server in the QEMU guest
# ------------------------------------------------------------

log "Pulling Code Server image"
qemu_docker_cmd "$DOCKER_PULL_TIMEOUT" pull "$CODE_SERVER_IMAGE" || fail "Code Server image could not be pulled in the QEMU guest."

qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${CODE_SERVER_PORT}:8080" \
    -e "PASSWORD=${CODE_SERVER_PASSWORD}" \
    -v "${PROJECTS_DIR}:/home/coder/project" \
    "$CODE_SERVER_IMAGE" || fail "Code Server could not be started in the QEMU guest."

# ------------------------------------------------------------
# Create management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<EOF
#!/usr/bin/env bash
set -euo pipefail
QEMU_BIN="$QEMU_BIN"
STATUS="\$(timeout 30s "\$QEMU_BIN" status 2>&1 || true)"
if printf '%s\\n' "\$STATUS" | grep -q 'is STALE'; then
    rm -f "$QEMU_HOME/vm-default.pid"
    STATUS=""
fi
if ! printf '%s\\n' "\$STATUS" | grep -q 'is RUNNING'; then
    timeout 300s "\$QEMU_BIN" start
fi
ready=0
for attempt in \$(seq 1 12); do
    if timeout 5s "\$QEMU_BIN" docker info >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
done
[ "\$ready" -eq 1 ] || { echo "Docker in the QEMU guest is not ready." >&2; exit 1; }
timeout 30s "\$QEMU_BIN" docker start "$CONTAINER_NAME"
echo "Code Server: http://localhost:${CODE_SERVER_PORT}"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<EOF
#!/usr/bin/env bash
set -e
QEMU_BIN="$QEMU_BIN"
timeout 30s "\$QEMU_BIN" docker stop "$CONTAINER_NAME" || true
timeout 30s "\$QEMU_BIN" stop || true
echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<EOF
#!/usr/bin/env bash
QEMU_BIN="$QEMU_BIN"
echo "=== QEMU guest ==="
timeout 30s "\$QEMU_BIN" status || true
echo
echo "=== Docker containers ==="
timeout 30s "\$QEMU_BIN" docker ps -a || true
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
echo "QEMU guest:      $QEMU_HOME"
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
