
#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail

# ============================================================
# Pliik Workstation - Termux installer
#
# Components:
#   - Pliik
#   - VS-CODE-IN-TERMUX (reference project)
#   - termux-qemu-docker
#   - Alpine Linux Docker VM
#   - code-server
#
# Docker runs inside QEMU, not directly on Android.
# ============================================================

APP_NAME="Pliik Workstation"

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
QEMU_DIR="$BASE_DIR/termux-qemu-docker"

BIN_DIR="$PREFIX/bin"
CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
VSCODE_REPO="https://github.com/Skynetfc/VS-CODE-IN-TERMUX.git"
QEMU_REPO="https://github.com/luisdavim/termux-qemu-docker.git"

QEMU_BIN="$BIN_DIR/termux-qemu-docker"

CONTAINER_NAME="pliik-code-server"
CODE_SERVER_PORT="8080"

ENV_FILE="$CONFIG_DIR/.env"

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# 1. Environment checks
# ------------------------------------------------------------

log "Checking Termux environment"

[ -n "${PREFIX:-}" ] || fail "This script must run inside Termux."

case "$PREFIX" in
    /data/data/com.termux/files/usr) ;;
    *) fail "Unsupported Termux PREFIX: $PREFIX" ;;
esac

mkdir -p "$BASE_DIR" "$PROJECTS_DIR" "$CONFIG_DIR"

# ------------------------------------------------------------
# 2. Install Termux dependencies
# ------------------------------------------------------------

log "Updating Termux packages"

pkg update -y

log "Installing required packages"

pkg install -y \
    git \
    curl \
    wget \
    openssh \
    golang \
    openssl \
    coreutils \
    findutils \
    grep \
    sed \
    tar

# ------------------------------------------------------------
# 3. Clone or update repositories
# ------------------------------------------------------------

clone_or_update() {
    local repo="$1"
    local destination="$2"

    if [ -d "$destination/.git" ]; then
        log "Updating $(basename "$destination")"

        git -C "$destination" pull --ff-only || {
            warn "Could not fast-forward $(basename "$destination")."
            warn "Keeping the existing checkout."
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

log "Downloading VS Code reference project"

clone_or_update "$VSCODE_REPO" "$VSCODE_DIR"

log "Downloading QEMU Docker"

clone_or_update "$QEMU_REPO" "$QEMU_DIR"

# ------------------------------------------------------------
# 4. Build termux-qemu-docker
# ------------------------------------------------------------

log "Building termux-qemu-docker"

cd "$QEMU_DIR"

go build -o "$QEMU_BIN" .

[ -x "$QEMU_BIN" ] || fail "QEMU Docker binary was not created."

log "QEMU Docker binary installed: $QEMU_BIN"

# ------------------------------------------------------------
# 5. Configure QEMU Docker
# ------------------------------------------------------------

log "Running QEMU Docker setup"

"$QEMU_BIN" setup

# ------------------------------------------------------------
# 6. Start QEMU Docker VM
# ------------------------------------------------------------

log "Starting QEMU Docker virtual machine"

"$QEMU_BIN" start

# ------------------------------------------------------------
# 7. Wait for VM health
# ------------------------------------------------------------

log "Waiting for Docker VM to become healthy"

MAX_WAIT=1200
INTERVAL=10
ELAPSED=0
VM_READY=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do

    STATUS="$("$QEMU_BIN" status 2>&1 || true)"

    if printf '%s\n' "$STATUS" | grep -qi "healthy"; then
        VM_READY=1
        break
    fi

    printf '\r[PLIIK] Waiting for VM... %s/%s seconds' \
        "$ELAPSED" "$MAX_WAIT"

    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

printf '\n'

if [ "$VM_READY" -ne 1 ]; then
    warn "The VM did not report healthy within 20 minutes."
    warn "Check its status with: termux-qemu-docker status"
    fail "Docker VM startup was not confirmed."
fi

log "Docker VM is healthy"

# ------------------------------------------------------------
# 8. Verify Docker access through QEMU wrapper
# ------------------------------------------------------------

log "Testing Docker connection"

if ! "$QEMU_BIN" docker info; then
    fail "Docker daemon is not responding inside the QEMU VM."
fi

log "Docker connection verified"

# ------------------------------------------------------------
# 9. Create persistent Code Server password
# ------------------------------------------------------------

log "Configuring Code Server"

if [ ! -f "$ENV_FILE" ]; then

    PASSWORD="$(openssl rand -hex 24)"

    printf 'CODE_SERVER_PASSWORD=%s\n' "$PASSWORD" > "$ENV_FILE"

    chmod 600 "$ENV_FILE"

    log "Generated a new Code Server password"
else
    log "Using existing Code Server password"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

[ -n "${CODE_SERVER_PASSWORD:-}" ] ||
    fail "Code Server password is missing."

# ------------------------------------------------------------
# 10. Create project directory
# ------------------------------------------------------------

mkdir -p "$PROJECTS_DIR"

# ------------------------------------------------------------
# 11. Pull Code Server image
# ------------------------------------------------------------

log "Downloading Code Server Docker image"

"$QEMU_BIN" docker pull codercom/code-server:latest

# ------------------------------------------------------------
# 12. Replace existing Code Server container
# ------------------------------------------------------------

log "Preparing Code Server container"

"$QEMU_BIN" docker rm -f "$CONTAINER_NAME" \
    >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 13. Deploy Code Server
# ------------------------------------------------------------

log "Starting Code Server"

"$QEMU_BIN" docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${CODE_SERVER_PORT}:8080" \
    -e "PASSWORD=${CODE_SERVER_PASSWORD}" \
    -v "${PROJECTS_DIR}:/home/coder/project" \
    codercom/code-server:latest

# ------------------------------------------------------------
# 14. Install management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

termux-qemu-docker start

termux-qemu-docker docker start pliik-code-server \
    >/dev/null 2>&1 || true

echo "Pliik Workstation started."
echo "Open http://localhost:8080"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

termux-qemu-docker docker stop pliik-code-server \
    >/dev/null 2>&1 || true

termux-qemu-docker stop

echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

echo "=== QEMU Docker VM ==="
termux-qemu-docker status || true

echo
echo "=== Code Server ==="
termux-qemu-docker docker ps \
    --filter name=pliik-code-server

echo
echo "URL: http://localhost:8080"
EOF

chmod +x \
    "$BIN_DIR/bin-dev-start" \
    "$BIN_DIR/bin-dev-stop" \
    "$BIN_DIR/bin-dev-status"

# ------------------------------------------------------------
# 15. Installation summary
# ------------------------------------------------------------

log "Installation completed"

echo
echo "=========================================="
echo "       Pliik Workstation installed"
echo "=========================================="
echo
echo "Workspace:       $BASE_DIR"
echo "Pliik:           $PLIIK_DIR"
echo "Projects:        $PROJECTS_DIR"
echo "QEMU Docker:     $QEMU_BIN"
echo
echo "Code Server URL: http://localhost:8080"
echo "Password file:   $ENV_FILE"
echo
echo "Management commands:"
echo "  bin-dev-start"
echo "  bin-dev-stop"
echo "  bin-dev-status"
echo
echo "To display your password:"
echo "  cat $ENV_FILE"
echo
echo "=========================================="
