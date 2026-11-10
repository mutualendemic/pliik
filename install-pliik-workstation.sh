
#!/data/data/com.termux/files/usr/bin/bash

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

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
QEMU_DIR="$BASE_DIR/termux-qemu-docker"

CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

BIN_DIR="$PREFIX/bin"
QEMU_BIN="$BIN_DIR/termux-qemu-docker"

ENV_FILE="$CONFIG_DIR/.env"

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
# Check Termux
# ------------------------------------------------------------

log "Checking Termux environment"

if [ -z "${PREFIX:-}" ]; then
    fail "Run this script inside Termux."
fi

case "$PREFIX" in
    /data/data/com.termux/files/usr) ;;
    *) fail "Unsupported Termux installation." ;;
esac

mkdir -p \
    "$BASE_DIR" \
    "$CONFIG_DIR" \
    "$PROJECTS_DIR"

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

        git -C "$destination" pull --ff-only || {
            warn "Update failed. Keeping existing checkout."
        }

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

log "Checking QEMU Docker VM status"

VM_STATUS="$("$QEMU_BIN" status)"
printf '%s\n' "$VM_STATUS"

if printf '%s\n' "$VM_STATUS" | grep -q 'is RUNNING'; then
    log "QEMU Docker VM is already running; reusing it"
else
    log "Starting QEMU Docker VM"
    "$QEMU_BIN" start
fi

# ------------------------------------------------------------
# Wait for Docker daemon
# ------------------------------------------------------------

log "Waiting for Docker daemon"

ELAPSED=0
DOCKER_READY=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do

    if "$QEMU_BIN" docker info >/dev/null 2>&1; then
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

    fail "Docker daemon did not become ready."
fi

log "Docker daemon is ready"

# ------------------------------------------------------------
# Configure Code Server password
# ------------------------------------------------------------

log "Configuring Code Server"

if [ ! -f "$ENV_FILE" ]; then

    PASSWORD="$(openssl rand -hex 24)"

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

"$QEMU_BIN" docker pull "$CODE_SERVER_IMAGE"

# ------------------------------------------------------------
# Remove previous container
# ------------------------------------------------------------

log "Removing previous Code Server container if present"

"$QEMU_BIN" docker rm -f "$CONTAINER_NAME" \
    >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Deploy Code Server
# ------------------------------------------------------------

log "Deploying Code Server"

"$QEMU_BIN" docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${CODE_SERVER_PORT}:8080" \
    -e "PASSWORD=${CODE_SERVER_PASSWORD}" \
    -v "${PROJECTS_DIR}:/home/coder/project" \
    "$CODE_SERVER_IMAGE"

# ------------------------------------------------------------
# Create management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

termux-qemu-docker start

echo "Waiting for Docker..."

for i in $(seq 1 120); do
    if termux-qemu-docker docker info >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

termux-qemu-docker docker start pliik-code-server

echo "Code Server: http://localhost:8080"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

termux-qemu-docker docker stop pliik-code-server || true
termux-qemu-docker stop

echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

echo "=== QEMU VM ==="
termux-qemu-docker status || true

echo
echo "=== Docker containers ==="
termux-qemu-docker docker ps -a || true

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
