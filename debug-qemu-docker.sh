#!/usr/bin/env bash

set -u

QEMU_BIN="${QEMU_BIN:-$(command -v termux-qemu-docker 2>/dev/null || true)}"
QEMU_HOME="${QEMU_HOME:-$HOME/.termux-qemu-docker}"
VM_PID_FILE="${VM_PID_FILE:-$QEMU_HOME/vm-default.pid}"
VM_LOG_FILE="${VM_LOG_FILE:-$QEMU_HOME/qemu-default.log}"

log() {
    printf '\n[PLIIK-DEBUG] %s\n' "$*"
}

warn() {
    printf '\n[PLIIK-DEBUG] WARN: %s\n' "$*" >&2
}

fail() {
    warn "$*"
    exit 1
}

if [ -z "$QEMU_BIN" ] || [ ! -x "$QEMU_BIN" ]; then
    if command -v termux-qemu-docker >/dev/null 2>&1; then
        QEMU_BIN="$(command -v termux-qemu-docker)"
    else
        fail "termux-qemu-docker is not installed or not on PATH. Try: export PATH=/data/data/com.termux/files/usr/bin:\$PATH"
    fi
fi

log "QEMU binary: $QEMU_BIN"
log "QEMU home: $QEMU_HOME"

if [ -f "$VM_PID_FILE" ]; then
    PID_VALUE="$(cat "$VM_PID_FILE" 2>/dev/null || echo '')"
    log "PID file: $VM_PID_FILE"
    log "PID value: ${PID_VALUE:-missing}"
    if [ -n "$PID_VALUE" ] && kill -0 "$PID_VALUE" 2>/dev/null; then
        log "PID process status: running"
        ps -p "$PID_VALUE" -o pid,comm,args || true
    else
        log "PID process status: not running or stale"
    fi
else
    log "PID file is missing: $VM_PID_FILE"
fi

log "=== termux-qemu-docker status ==="
"$QEMU_BIN" status || true

log "=== QEMU process scan ==="
pgrep -af 'qemu-system|termux-qemu-docker|dockerd|alpine' || true

log "=== QEMU home listing ==="
ls -la "$QEMU_HOME" 2>&1 || true

log "=== recent QEMU log ==="
if [ -f "$VM_LOG_FILE" ]; then
    tail -n 80 "$VM_LOG_FILE" || true
else
    warn "QEMU log not found: $VM_LOG_FILE"
fi

log "=== docker info inside VM ==="
"$QEMU_BIN" docker info || true

log "=== docker ps -a inside VM ==="
"$QEMU_BIN" docker ps -a || true

log "=== docker version inside VM ==="
"$QEMU_BIN" docker version || true

if printf '%s\n' "$($QEMU_BIN status 2>/dev/null || true)" | grep -qi 'STALE'; then
    warn "The VM status reports STALE. You can clean it with: rm -f \"$VM_PID_FILE\" && \"$QEMU_BIN\" start"
fi

if printf '%s\n' "$($QEMU_BIN status 2>/dev/null || true)" | grep -qi 'RUNNING'; then
    log "VM reports RUNNING, but Docker may still not be ready. Check the guest boot log and container state above."
fi

log "Debug output complete."
