#!/usr/bin/env bash

set -Eeuo pipefail

QEMU_BIN="${QEMU_BIN:-$(command -v termux-qemu-docker 2>/dev/null || true)}"
QEMU_HOME="${QEMU_HOME:-$HOME/.termux-qemu-docker}"
VM_PID_FILE="${VM_PID_FILE:-$QEMU_HOME/vm-default.pid}"
VM_LOG_FILE="${VM_LOG_FILE:-$QEMU_HOME/qemu-default.log}"

log() {
    printf '\n[PLIIK-CLEAN] %s\n' "$*"
}

warn() {
    printf '\n[PLIIK-CLEAN] WARN: %s\n' "$*" >&2
}

if [ -z "${QEMU_BIN}" ] || [ ! -x "${QEMU_BIN}" ]; then
    warn "termux-qemu-docker is not on PATH. Trying to continue anyway."
    QEMU_BIN="termux-qemu-docker"
fi

log "Cleaning stale QEMU Docker VM state"
log "QEMU home: ${QEMU_HOME}"
log "PID file: ${VM_PID_FILE}"

if [ -f "${VM_PID_FILE}" ]; then
    stale_pid="$(cat "${VM_PID_FILE}" 2>/dev/null || true)"
    if [ -n "${stale_pid}" ] && kill -0 "${stale_pid}" 2>/dev/null; then
        log "Stopping stale QEMU process ${stale_pid}"
        kill "${stale_pid}" 2>/dev/null || true
    else
        log "PID file is stale or missing; skipping kill"
    fi
    rm -f "${VM_PID_FILE}"
fi

if [ -d "${QEMU_HOME}" ]; then
    log "Removing QEMU home directory: ${QEMU_HOME}"
    rm -rf "${QEMU_HOME}"
fi

if [ -f "${VM_LOG_FILE}" ]; then
    rm -f "${VM_LOG_FILE}"
fi

log "Reset complete. Starting a fresh QEMU Docker VM..."
if command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    "${QEMU_BIN}" start || true
else
    warn "termux-qemu-docker command is still unavailable on PATH. Check that the package is installed or the binary is available."
fi

log "Checking status..."
if command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    "${QEMU_BIN}" status || true
fi

log "If the VM is still not ready, run: ${QEMU_BIN} docker info"
log "Cleanup complete."
