#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Pliik Workstation"
BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"
ENV_FILE="$CONFIG_DIR/.env"
PREFIX_PATH="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="${PREFIX_PATH}/bin"
CODE_SERVER_PORT=8080
CODE_SERVER_PID_FILE="$CONFIG_DIR/code-server.pid"
PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
VSCODE_REPO="https://github.com/Skynetfc/VS-CODE-IN-TERMUX.git"

log() { printf '\n[PLIIK] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ] || [ -d "/data/data/com.termux/files/home" ]
}

if ! is_termux; then
    fail "Run this installer from Termux."
fi

if [ "$(id -u)" -eq 0 ]; then
    fail "Run this installer as the regular Termux user, not root."
fi

mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$PROJECTS_DIR"

ensure_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        OPENSSL_BIN="$(command -v openssl)"
        return 0
    fi
    pkg install -y openssl openssl-tool || fail "OpenSSL is required and could not be installed."
    OPENSSL_BIN="$(command -v openssl)"
}

clone_or_update() {
    local repo="$1"
    local destination="$2"

    if [ -d "$destination/.git" ]; then
        log "Updating $(basename "$destination")"
        git -C "$destination" pull --ff-only || warn "Update skipped; leaving the existing checkout intact."
        return 0
    fi

    if [ -e "$destination" ]; then
        fail "$destination exists but is not a Git repository."
    fi

    log "Cloning $(basename "$destination")"
    git clone "$repo" "$destination"
}

install_code_server() {
    export PATH="$HOME/.local/bin:$PATH"

    if command -v code-server >/dev/null 2>&1; then
        return 0
    fi

    log "Installing code-server"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://code-server.dev/install.sh | sh || fail "Could not install Code Server."
    else
        pkg install -y curl || fail "curl is required and could not be installed."
        curl -fsSL https://code-server.dev/install.sh | sh || fail "Could not install Code Server."
    fi

    export PATH="$HOME/.local/bin:$PATH"
    command -v code-server >/dev/null 2>&1 || fail "code-server is still unavailable after install."
}

create_management_scripts() {
    cat > "$BIN_DIR/bin-dev-start" <<EOF_START
#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

CODE_SERVER_PASSWORD="$(sed -n 's/^CODE_SERVER_PASSWORD=//p' "$ENV_FILE")"
if [ -z "\${CODE_SERVER_PASSWORD:-}" ]; then
    echo "Code Server password is missing." >&2
    exit 1
fi

if [ -f "$CODE_SERVER_PID_FILE" ] && kill -0 "\$(cat "$CODE_SERVER_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "Code Server already running at http://localhost:${CODE_SERVER_PORT}"
    exit 0
fi

nohup code-server \
    --bind-addr 0.0.0.0:${CODE_SERVER_PORT} \
    --auth password \
    --password "\${CODE_SERVER_PASSWORD}" \
    --disable-telemetry \
    --host 0.0.0.0 \
    --port ${CODE_SERVER_PORT} \
    > "$CONFIG_DIR/code-server.log" 2>&1 &

echo \$! > "$CODE_SERVER_PID_FILE"
echo "Code Server: http://localhost:${CODE_SERVER_PORT}"
EOF_START

    cat > "$BIN_DIR/bin-dev-stop" <<EOF_STOP
#!/usr/bin/env bash
set -e
if [ -f "$CODE_SERVER_PID_FILE" ]; then
    PID="\$(cat "$CODE_SERVER_PID_FILE" 2>/dev/null || true)"
    if [ -n "\${PID:-}" ] && kill -0 "\${PID}" 2>/dev/null; then
        kill "\${PID}" || true
    fi
    rm -f "$CODE_SERVER_PID_FILE"
fi
echo "Code Server stopped."
EOF_STOP

    cat > "$BIN_DIR/bin-dev-status" <<EOF_STATUS
#!/usr/bin/env bash
if [ -f "$CODE_SERVER_PID_FILE" ] && kill -0 "\$(cat "$CODE_SERVER_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "Code Server is running at http://localhost:${CODE_SERVER_PORT}"
else
    echo "Code Server is not running."
fi
if command -v curl >/dev/null 2>&1; then
    curl -I --max-time 5 http://127.0.0.1:${CODE_SERVER_PORT} 2>/dev/null | sed -n '1,3p' || true
fi
EOF_STATUS

    chmod +x "$BIN_DIR/bin-dev-start" "$BIN_DIR/bin-dev-stop" "$BIN_DIR/bin-dev-status"
}

main() {
    log "Checking Termux environment"
    pkg install -y git curl wget openssl openssl-tool || {
        pkg update -y || true
        pkg install -y git curl wget openssl openssl-tool || fail "Required Termux packages could not be installed."
    }

    ensure_openssl
    install_code_server

    clone_or_update "$PLIIK_REPO" "$PLIIK_DIR"
    clone_or_update "$VSCODE_REPO" "$VSCODE_DIR"

    if [ ! -f "$ENV_FILE" ]; then
        if ! PASSWORD="$($OPENSSL_BIN rand -hex 24 2>/dev/null)"; then
            fail "Failed to generate the Code Server password."
        fi
        printf 'CODE_SERVER_PASSWORD=%s\n' "$PASSWORD" > "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "Generated Code Server password"
    fi

    create_management_scripts

    if [ -f "$CODE_SERVER_PID_FILE" ] && kill -0 "$(cat "$CODE_SERVER_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log "Code Server already running; keeping it active."
    else
        export PATH="$HOME/.local/bin:$PATH"
        log "Starting Code Server directly in Termux"
        nohup code-server \
            --bind-addr 0.0.0.0:${CODE_SERVER_PORT} \
            --auth password \
            --password "$(sed -n 's/^CODE_SERVER_PASSWORD=//p' "$ENV_FILE")" \
            --disable-telemetry \
            --host 0.0.0.0 \
            --port ${CODE_SERVER_PORT} \
            > "$CONFIG_DIR/code-server.log" 2>&1 &
        echo $! > "$CODE_SERVER_PID_FILE"
        sleep 2
    fi

    log "Installation completed successfully"
    echo
    echo "============================================"
    echo "       Pliik Workstation installed"
    echo "============================================"
    echo
    echo "Workspace:       $BASE_DIR"
    echo "Pliik:           $PLIIK_DIR"
    echo "Projects:        $PROJECTS_DIR"
    echo "Runtime:         direct Termux code-server"
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
}

main "$@"
