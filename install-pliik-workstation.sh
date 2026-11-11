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
PI_WEB_PORT=8504
PI_WEB_PID_FILE="$CONFIG_DIR/pi-web.pid"
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

install_pi_web() {
    if command -v pi-web >/dev/null 2>&1; then
        return 0
    fi

    log "Installing Node.js, pi-web, and the Pi SDK required by the browser app"
    pkg install -y nodejs npm || fail "Node.js/npm could not be installed in Termux."
    npm install -g @jmfederico/pi-web --allow-scripts=node-pty || fail "pi-web could not be installed globally."
    npm install -g @earendil-works/pi-coding-agent || fail "The Pi SDK package could not be installed."
    command -v pi-web >/dev/null 2>&1 || fail "pi-web is still unavailable after install."
    pi-web install || warn "pi-web install completed with warnings; continuing."
}

create_management_scripts() {
    cat > "$BIN_DIR/bin-dev-start" <<EOF_START
#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
export PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"

if [ -f "$PI_WEB_PID_FILE" ] && kill -0 "\$(cat "$PI_WEB_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "PI WEB already running at http://localhost:${PI_WEB_PORT}"
    exit 0
fi

echo "[bin-dev-start] Starting pi-web on port ${PI_WEB_PORT}"
nohup env PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent" pi-web-server > "$CONFIG_DIR/pi-web.log" 2>&1 &

PID=\$!
echo \$PID > "$PI_WEB_PID_FILE"
echo "[bin-dev-start] PID=\${PID} written to $PI_WEB_PID_FILE"

sleep 2
if ! kill -0 "\${PID}" 2>/dev/null; then
    echo "[bin-dev-start] pi-web exited immediately. See log: $CONFIG_DIR/pi-web.log" >&2
    tail -n 50 "$CONFIG_DIR/pi-web.log" >&2 || true
    exit 1
fi

echo "PI WEB: http://localhost:${PI_WEB_PORT}"
EOF_START

    cat > "$BIN_DIR/bin-dev-stop" <<EOF_STOP
#!/usr/bin/env bash
set -e
if [ -f "$PI_WEB_PID_FILE" ]; then
    PID="\$(cat "$PI_WEB_PID_FILE" 2>/dev/null || true)"
    if [ -n "\${PID:-}" ] && kill -0 "\${PID}" 2>/dev/null; then
        kill "\${PID}" || true
    fi
    rm -f "$PI_WEB_PID_FILE"
fi
echo "PI WEB stopped."
EOF_STOP

    cat > "$BIN_DIR/bin-dev-status" <<EOF_STATUS
#!/usr/bin/env bash
if [ -f "$PI_WEB_PID_FILE" ]; then
    PID="\$(cat "$PI_WEB_PID_FILE" 2>/dev/null || true)"
    echo "[bin-dev-status] PID file: $PI_WEB_PID_FILE"
    echo "[bin-dev-status] PID value: \${PID:-<missing>}"
    if [ -n "\${PID:-}" ] && kill -0 "\${PID}" 2>/dev/null; then
        echo "PI WEB is running at http://localhost:${PI_WEB_PORT}"
    else
        echo "PI WEB is not running."
        if [ -f "$CONFIG_DIR/pi-web.log" ]; then
            echo "[bin-dev-status] Recent startup log:"
            tail -n 50 "$CONFIG_DIR/pi-web.log" || true
        fi
    fi
else
    echo "PI WEB is not running."
    echo "[bin-dev-status] PID file missing at $PI_WEB_PID_FILE"
fi
if command -v curl >/dev/null 2>&1; then
    curl -I --max-time 5 http://127.0.0.1:${PI_WEB_PORT} 2>/dev/null | sed -n '1,3p' || true
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
    install_pi_web

    clone_or_update "$PLIIK_REPO" "$PLIIK_DIR"
    clone_or_update "$VSCODE_REPO" "$VSCODE_DIR"

    create_management_scripts

    if [ -f "$PI_WEB_PID_FILE" ] && kill -0 "$(cat "$PI_WEB_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log "PI WEB already running; keeping it active."
    else
        log "Starting PI WEB directly in Termux"
        export PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
        nohup env PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent" pi-web-server > "$CONFIG_DIR/pi-web.log" 2>&1 &
        echo $! > "$PI_WEB_PID_FILE"
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
    echo "Runtime:         pi-web browser app"
    echo
    echo "PI WEB:"
    echo "  http://localhost:${PI_WEB_PORT}"
    echo
    echo "Management:"
    echo "  bin-dev-start"
    echo "  bin-dev-stop"
    echo "  bin-dev-status"
    echo
    echo "============================================"
}

main "$@"
