#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-$HOME/pliik-workstation}"

PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
REFERENCE_REPO="https://github.com/Skynetfc/VS-CODE-IN-TERMUX.git"
QEMU_REPO="https://github.com/luisdavim/termux-qemu-docker.git"

log() { printf '\n[PLIIK] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

command -v pkg >/dev/null 2>&1 || die "Run inside Termux."
[[ -n "${PREFIX:-}" ]] || die "Termux environment not detected."

mkdir -p "$APP_DIR"

log "Installing dependencies"
pkg update -y
pkg upgrade -y
pkg install -y git curl wget openssh gh golang openssl

clone_repo() {
    local url="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --ff-only || warn "Update failed: $dir"
    else
        git clone "$url" "$dir" || return 1
    fi
}

log "Cloning Pliik"
clone_repo "$PLIIK_REPO" "$APP_DIR/pliik" ||
    die "Pliik clone failed. Authenticate using gh auth login if private."

log "Cloning VS-CODE-IN-TERMUX reference"
clone_repo "$REFERENCE_REPO" "$APP_DIR/VS-CODE-IN-TERMUX" ||
    warn "Reference clone failed."

log "Cloning QEMU Docker"
clone_repo "$QEMU_REPO" "$APP_DIR/termux-qemu-docker" ||
    die "QEMU Docker clone failed."

cd "$APP_DIR/termux-qemu-docker"

if [[ -f setup.sh ]]; then
    bash setup.sh
elif [[ -f install.sh ]]; then
    bash install.sh
else
    warn "No setup script found. Follow upstream instructions."
fi

cd "$APP_DIR"

DOCKER_HOST_VALUE=""

for socket in \
    "$HOME/.termux-qemu-docker/docker-default.sock" \
    "$HOME/.termux-qemu-docker/docker.sock" \
    "$PREFIX/var/run/docker.sock"
do
    if [[ -S "$socket" ]]; then
        DOCKER_HOST_VALUE="unix://$socket"
        break
    fi
done

if [[ -z "$DOCKER_HOST_VALUE" ]]; then
    warn "Docker socket not detected."
    warn "Start QEMU Docker and rerun this installer."
    exit 0
fi

export DOCKER_HOST="$DOCKER_HOST_VALUE"

command -v docker >/dev/null 2>&1 || die "Docker unavailable."

if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    die "Docker Compose unavailable."
fi

cat > .env.example <<'EOF'
CODE_SERVER_PASSWORD=change-this-password
CODE_SERVER_PORT=8080
TZ=Europe/Lisbon
PLIIK_APP_PORT=3000
PLIIK_CONTAINER_PORT=3000
EOF

cat > compose.yaml <<'EOF'
services:
  code-server:
    image: codercom/code-server:latest
    container_name: pliik-code-server
    restart: unless-stopped
    environment:
      TZ: ${TZ:-Europe/Lisbon}
      PASSWORD: ${CODE_SERVER_PASSWORD:?Set password in .env}
      DEFAULT_WORKSPACE: /workspace
    ports:
      - "127.0.0.1:${CODE_SERVER_PORT:-8080}:8080"
    volumes:
      - ./pliik:/workspace/pliik
      - ./VS-CODE-IN-TERMUX:/workspace/VS-CODE-IN-TERMUX:ro
      - code_server_config:/home/coder/.config
      - code_server_data:/home/coder/.local/share/code-server

  pliik:
    profiles: ["pliik"]
    build:
      context: ./pliik
    container_name: pliik-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PLIIK_APP_PORT:-3000}:${PLIIK_CONTAINER_PORT:-3000}"

volumes:
  code_server_config:
  code_server_data:
EOF

if [[ ! -f .env ]]; then
    cp .env.example .env
    chmod 600 .env
fi

if grep -q '^CODE_SERVER_PASSWORD=change-this-password$' .env; then
    PASSWORD="$(openssl rand -hex 20)"
    sed -i "s/^CODE_SERVER_PASSWORD=.*/CODE_SERVER_PASSWORD=$PASSWORD/" .env
fi

chmod 600 .env

log "Starting Code Server"
"${COMPOSE[@]}" --env-file .env up -d --remove-orphans

create_helper() {
    local name="$1"
    local action="$2"

    cat > "$HOME/$name" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
export DOCKER_HOST="$DOCKER_HOST_VALUE"
cd "$APP_DIR"
docker compose --env-file .env $action
EOF
    chmod +x "$HOME/$name"
}

create_helper bin-dev-start "up -d"
create_helper bin-dev-stop "down"
create_helper bin-dev-status "ps"

log "Installation completed"

echo "Code Server: http://127.0.0.1:8080"
echo "Project: $APP_DIR/pliik"
echo "Password: $APP_DIR/.env"
echo "Commands: ~/bin-dev-start ~/bin-dev-stop ~/bin-dev-status"
