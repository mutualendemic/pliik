#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Pliik Workstation"
BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"
ENV_FILE="$CONFIG_DIR/.env"
PREFIX_PATH="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="${PREFIX_PATH}/bin"
PI_WEB_PORT=8504
PI_WEB_PID_FILE="$CONFIG_DIR/pi-web.pid"
PI_WEB_SESSIOND_PID_FILE="$CONFIG_DIR/pi-web-sessiond.pid"
PI_WEB_SESSIOND_SOCKET="$HOME/.pi-web/sessiond.sock"
PORTAL_ADDR="127.0.0.1:8080"
PORTAL_PID_FILE="$CONFIG_DIR/portal.pid"
PORTAL_BINARY="$BIN_DIR/pliik-portal"
PLIIK_REPO="https://github.com/mutualendemic/pliik.git"
PLIIK_SOURCE_DIR="${PLIIK_SOURCE_DIR:-}"

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

remove_legacy_code_server() {
    local pid_file="$CONFIG_DIR/code-server.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid="$(<"$pid_file")"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            log "Stopping the previous Code Server process (PID $pid)"
            kill "$pid" 2>/dev/null || true
            for _ in {1..5}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    rm -f "$CONFIG_DIR/code-server-termux-platform.cjs"
    if command -v npm >/dev/null 2>&1; then
        log "Removing the global Code Server npm package, if installed"
        npm uninstall -g code-server || fail "Could not uninstall the global Code Server npm package."
    fi
}

install_pi_web() {
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        pkg install -y nodejs-lts npm || fail "Node.js LTS/npm could not be installed in Termux."
    fi

    export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path=$PREFIX_PATH"

    if ! command -v go >/dev/null 2>&1; then
        log "Installing Go runtime required by the Pliik portal"
        pkg install -y golang || fail "Go could not be installed in Termux."
    fi

    log "Installing Python and native build tools required by node-pty"
    pkg install -y python make clang || fail "Python and native build tools could not be installed in Termux."

    PYTHON_BIN="$(command -v python3 || command -v python || true)"
    if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
        fail "Python is not executable after installing the Termux package."
    fi
    "$PYTHON_BIN" --version || fail "Python could not be started."
    export PYTHON="$PYTHON_BIN"
    export NODE_GYP_FORCE_PYTHON="$PYTHON_BIN"

    if [ ! -f "$PREFIX_PATH/include/node/common.gypi" ]; then
        fail "Termux Node headers are missing at $PREFIX_PATH/include/node; reinstall the nodejs package."
    fi

    if ! command -v pi-web >/dev/null 2>&1; then
        log "Installing pi-web"
        npm install -g @jmfederico/pi-web --omit=optional || fail "pi-web could not be installed globally."
    fi

    local npm_global_root
    npm_global_root="$(npm root -g 2>/dev/null)" || fail "Could not determine the global npm package directory."
    if [ ! -d "$npm_global_root/@earendil-works/pi-coding-agent" ]; then
        log "Installing the Pi SDK required by the browser app"
        npm install -g @earendil-works/pi-coding-agent || fail "The Pi SDK package could not be installed."
    fi

    if ! command -v pi >/dev/null 2>&1; then
        fail "The PI CLI is not available after installing the Pi SDK."
    fi

    log "Installing GitHub Copilot auto package"
    pi install git:github.com/jgrumboe/pi-github-copilot-auto || fail "The GitHub Copilot auto package could not be installed."

    if ! (cd "$npm_global_root/@jmfederico/pi-web" && node -e "require('node-pty')") >/dev/null 2>&1; then
        log "Installing node-pty for terminal support"
        npm install -g node-pty --ignore-scripts || fail "node-pty could not be installed globally."

        local node_gyp="$npm_global_root/npm/node_modules/node-gyp/bin/node-gyp.js"
        if [ ! -f "$node_gyp" ]; then
            fail "node-gyp was not found at $node_gyp."
        fi
        log "Building node-pty against Termux Node headers"
        (cd "$npm_global_root/node-pty" && node "$node_gyp" rebuild --nodedir="$PREFIX_PATH") || fail "node-pty could not be built against Termux Node headers."
    fi

    if ! (cd "$npm_global_root/@jmfederico/pi-web" && node -e "require('node-pty')") >/dev/null 2>&1; then
        fail "node-pty is installed but cannot be loaded by pi-web."
    fi

    command -v pi-web >/dev/null 2>&1 || fail "pi-web is still unavailable after install."
}

install_portal() {
    local source_dir="${1:-$PLIIK_DIR}"
    if ! command -v go >/dev/null 2>&1; then
        pkg install -y golang || fail "Go could not be installed in Termux."
    fi

    log "Building and installing the Pliik management portal"
    mkdir -p "$BIN_DIR"
    local temporary_binary="${PORTAL_BINARY}.new"
    rm -f "$temporary_binary"
    (cd "$source_dir/portal" && go build -o "$temporary_binary" .) || {
        rm -f "$temporary_binary"
        fail "The Pliik portal could not be built. Check that the Termux Go package supports this device."
    }
    chmod 755 "$temporary_binary"
    mv -f "$temporary_binary" "$PORTAL_BINARY"
    [ -x "$PORTAL_BINARY" ] || fail "The Pliik portal binary was not installed at $PORTAL_BINARY."
}

create_management_scripts() {
    cat > "$BIN_DIR/bin-dev-start" <<EOF_START
#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
export PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"

if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || echo "[bin-dev-start] Could not acquire Termux wakelock." >&2
else
    echo "[bin-dev-start] termux-wake-lock is unavailable; Android may suspend Termux in the background." >&2
fi

if [ -f "$PI_WEB_SESSIOND_PID_FILE" ] && kill -0 "\$(cat "$PI_WEB_SESSIOND_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "[bin-dev-start] Session daemon is already running."
else
    rm -f "$PI_WEB_SESSIOND_PID_FILE"
    echo "[bin-dev-start] Starting pi-web session daemon"
    nohup env PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent" pi-web-sessiond > "$CONFIG_DIR/pi-web-sessiond.log" 2>&1 &
    SESSIOND_PID=\$!
    echo "\$SESSIOND_PID" > "$PI_WEB_SESSIOND_PID_FILE"
fi

for attempt in {1..20}; do
    if [ -S "$PI_WEB_SESSIOND_SOCKET" ]; then
        break
    fi
    if ! kill -0 "\$(cat "$PI_WEB_SESSIOND_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ ! -S "$PI_WEB_SESSIOND_SOCKET" ]; then
    echo "[bin-dev-start] Session daemon did not create its socket: $PI_WEB_SESSIOND_SOCKET" >&2
    tail -n 50 "$CONFIG_DIR/pi-web-sessiond.log" >&2 || true
    SESSIOND_PID=\$(cat "$PI_WEB_SESSIOND_PID_FILE" 2>/dev/null || true)
    if [ -n "\${SESSIOND_PID:-}" ]; then
        kill "\$SESSIOND_PID" 2>/dev/null || true
    fi
    rm -f "$PI_WEB_SESSIOND_PID_FILE"
    if command -v termux-wake-unlock >/dev/null 2>&1; then
        termux-wake-unlock || true
    fi
    exit 1
fi

if [ -f "$PI_WEB_PID_FILE" ] && kill -0 "\$(cat "$PI_WEB_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "PI WEB already running at http://localhost:${PI_WEB_PORT}"
else
    echo "[bin-dev-start] Starting pi-web on port ${PI_WEB_PORT}"
    nohup env PI_WEB_PORT="${PI_WEB_PORT}" PI_WEB_PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent" pi-web-server > "$CONFIG_DIR/pi-web.log" 2>&1 &
    PID=\$!
    echo \$PID > "$PI_WEB_PID_FILE"
    echo "[bin-dev-start] PID=\${PID} written to $PI_WEB_PID_FILE"
    sleep 2
    if ! kill -0 "\${PID}" 2>/dev/null; then
        echo "[bin-dev-start] pi-web exited immediately. See log: $CONFIG_DIR/pi-web.log" >&2
        tail -n 50 "$CONFIG_DIR/pi-web.log" >&2 || true
        rm -f "$PI_WEB_PID_FILE"
        if command -v termux-wake-unlock >/dev/null 2>&1; then
            termux-wake-unlock || true
        fi
        exit 1
    fi
    echo "PI WEB: http://localhost:${PI_WEB_PORT}"
fi

if [ -f "$PORTAL_PID_FILE" ] && kill -0 "\$(cat "$PORTAL_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "Pliik portal already running at http://${PORTAL_ADDR}/admin"
else
    echo "[bin-dev-start] Starting Pliik portal on http://${PORTAL_ADDR}/admin"
    nohup "$PORTAL_BINARY" > "$CONFIG_DIR/portal.log" 2>&1 &
    PORTAL_PID=\$!
    echo \$PORTAL_PID > "$PORTAL_PID_FILE"
    sleep 2
    if ! kill -0 "\${PORTAL_PID}" 2>/dev/null; then
        echo "[bin-dev-start] Pliik portal exited immediately. See log: $CONFIG_DIR/portal.log" >&2
        tail -n 50 "$CONFIG_DIR/portal.log" >&2 || true
        rm -f "$PORTAL_PID_FILE"
        if command -v termux-wake-unlock >/dev/null 2>&1; then
            termux-wake-unlock || true
        fi
        exit 1
    fi
    echo "Pliik Portal: http://${PORTAL_ADDR}/admin"
fi
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
if [ -f "$PI_WEB_SESSIOND_PID_FILE" ]; then
    SESSIOND_PID="\$(cat "$PI_WEB_SESSIOND_PID_FILE" 2>/dev/null || true)"
    if [ -n "\${SESSIOND_PID:-}" ] && kill -0 "\$SESSIOND_PID" 2>/dev/null; then
        kill "\$SESSIOND_PID" || true
    fi
    rm -f "$PI_WEB_SESSIOND_PID_FILE"
fi
if [ -f "$PORTAL_PID_FILE" ]; then
    PORTAL_PID="\$(cat "$PORTAL_PID_FILE" 2>/dev/null || true)"
    if [ -n "\${PORTAL_PID:-}" ] && kill -0 "\${PORTAL_PID}" 2>/dev/null; then
        kill "\${PORTAL_PID}" || true
    fi
    rm -f "$PORTAL_PID_FILE"
fi
if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock || true
fi
echo "PI WEB and Pliik portal stopped."
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
if [ -f "$PORTAL_PID_FILE" ]; then
    PORTAL_PID="\$(cat "$PORTAL_PID_FILE" 2>/dev/null || true)"
    echo "[bin-dev-status] Portal PID file: $PORTAL_PID_FILE"
    echo "[bin-dev-status] Portal PID value: \${PORTAL_PID:-<missing>}"
    if [ -n "\${PORTAL_PID:-}" ] && kill -0 "\${PORTAL_PID}" 2>/dev/null; then
        echo "Pliik Portal is running at http://${PORTAL_ADDR}/admin"
    else
        echo "Pliik Portal is not running."
        if [ -f "$CONFIG_DIR/portal.log" ]; then
            echo "[bin-dev-status] Recent portal log:"
            tail -n 50 "$CONFIG_DIR/portal.log" || true
        fi
    fi
else
    echo "Pliik Portal is not running."
    echo "[bin-dev-status] Portal PID file missing at $PORTAL_PID_FILE"
fi
if [ -f "$PI_WEB_SESSIOND_PID_FILE" ]; then
    SESSIOND_PID="\$(cat "$PI_WEB_SESSIOND_PID_FILE" 2>/dev/null || true)"
    if [ -n "\${SESSIOND_PID:-}" ] && kill -0 "\$SESSIOND_PID" 2>/dev/null; then
        echo "PI WEB session daemon is running (PID \$SESSIOND_PID)."
    else
        echo "PI WEB session daemon is not running."
    fi
else
    echo "PI WEB session daemon PID file missing."
fi
if [ -S "$PI_WEB_SESSIOND_SOCKET" ]; then
    echo "PI WEB session daemon socket is present."
else
    echo "PI WEB session daemon socket is missing at $PI_WEB_SESSIOND_SOCKET"
fi
if command -v curl >/dev/null 2>&1; then
    curl -I --max-time 5 http://127.0.0.1:${PI_WEB_PORT} 2>/dev/null | sed -n '1,3p' || true
    curl -I --max-time 5 http://${PORTAL_ADDR}/admin 2>/dev/null | sed -n '1,3p' || true
fi
EOF_STATUS

    chmod +x "$BIN_DIR/bin-dev-start" "$BIN_DIR/bin-dev-stop" "$BIN_DIR/bin-dev-status"
}

stop_managed_app_process() {
    local pid_file="$1"
    local service_name="$2"
    local pid=""

    [ -f "$pid_file" ] || return 0
    pid="$(<"$pid_file")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        log "Stopping $service_name (PID $pid) for reinstall"
        kill "$pid" 2>/dev/null || true
        for _ in {1..10}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "$service_name did not stop gracefully; forcing it to exit"
            kill -9 "$pid" 2>/dev/null || true
            for _ in {1..3}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
        fi
        kill -0 "$pid" 2>/dev/null && fail "Could not stop $service_name (PID $pid)."
    fi
    rm -f "$pid_file"
}

restart_portal_services() {
    log "Restarting Pi Web and the Pliik admin portal (leaving the session daemon running)"
    stop_managed_app_process "$PI_WEB_PID_FILE" "Pi Web"
    stop_managed_app_process "$PORTAL_PID_FILE" "Pliik admin portal"
}

main() {
    log "Checking Termux environment"
    pkg install -y git curl wget openssl openssl-tool termux-api || {
        pkg update -y || true
        pkg install -y git curl wget openssl openssl-tool termux-api || fail "Required Termux packages could not be installed."
    }

    ensure_openssl
    remove_legacy_code_server
    install_pi_web

    local portal_source_dir="$PLIIK_DIR"
    if [ -n "$PLIIK_SOURCE_DIR" ]; then
        portal_source_dir="$(cd "$PLIIK_SOURCE_DIR" && pwd)" || fail "PLIIK_SOURCE_DIR does not exist."
        [ -d "$portal_source_dir/portal" ] || fail "PLIIK_SOURCE_DIR must contain the portal/ directory."
        log "Using local Pliik source: $portal_source_dir"
    else
        clone_or_update "$PLIIK_REPO" "$PLIIK_DIR"
    fi
    install_portal "$portal_source_dir"

    create_management_scripts

    restart_portal_services
    log "Ensuring PI WEB and portal services are running"
    "$BIN_DIR/bin-dev-start"

    log "Installation completed successfully"
    echo
    echo "============================================"
    echo "       Pliik Workstation installed"
    echo "============================================"
    echo
    echo "Home:            $BASE_DIR"
    echo "Pliik:           $PLIIK_DIR"
    echo "Projects:        $PROJECTS_DIR"
    echo "Runtime:         pi-web and Pliik administration portal"
    echo
    echo "PI WEB:"
    echo "  http://localhost:${PI_WEB_PORT}"
    echo
    echo "Portal:"
    echo "  http://${PORTAL_ADDR}/admin"
    echo
    echo "Management:"
    echo "  bin-dev-start"
    echo "  bin-dev-stop"
    echo "  bin-dev-status"
    echo
    echo "============================================"
}

main "$@"
