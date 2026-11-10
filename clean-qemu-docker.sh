#!/usr/bin/env bash

set -Eeuo pipefail

is_termux() {
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ]; then
        return 0
    fi
    return 1
}

resolve_qemu_bin() {
    local candidates=()
    candidates+=("${QEMU_BIN:-}")
    candidates+=("$(command -v termux-qemu-docker 2>/dev/null || true)")
    candidates+=("/data/data/com.termux/files/usr/bin/termux-qemu-docker")
    candidates+=("/data/data/com.termux/files/usr/local/bin/termux-qemu-docker")
    candidates+=("/usr/local/bin/termux-qemu-docker")
    candidates+=("/usr/bin/termux-qemu-docker")

    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

if is_termux; then
    QEMU_HOME="${QEMU_HOME:-$HOME/.termux-qemu-docker}"
else
    QEMU_HOME="${QEMU_HOME:-$HOME/.qemu-docker}"
fi

QEMU_BIN="${QEMU_BIN:-$(resolve_qemu_bin 2>/dev/null || true)}"
VM_PID_FILE="${VM_PID_FILE:-$QEMU_HOME/vm-default.pid}"
VM_LOG_FILE="${VM_LOG_FILE:-$QEMU_HOME/qemu-default.log}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
RETRY_COUNT="${RETRY_COUNT:-3}"

log() {
    printf '\n[PLIIK-CLEAN] %s\n' "$*"
}

warn() {
    printf '\n[PLIIK-CLEAN] WARN: %s\n' "$*" >&2
}

cleanup_qemu_state() {
    local stale_pid=""

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
}

qemu_docker_ready() {
    local output
    output="$("${QEMU_BIN}" docker info 2>&1 || true)"

    if printf '%s\n' "${output}" | grep -q 'Server Version:'; then
        return 0
    fi

    if printf '%s\n' "${output}" | grep -Eq 'timed out|timeout|failed to connect|Cannot connect|unable to authenticate'; then
        warn "Docker readiness probe reported a timeout or connection failure: ${output}"
    fi

    return 1
}

wait_for_docker() {
    local elapsed=0

    log "Waiting for Docker daemon in the guest VM"

    while [ "${elapsed}" -lt "${WAIT_TIMEOUT}" ]; do
        if qemu_docker_ready; then
            log "Docker daemon is ready."
            return 0
        fi

        printf '\r[PLIIK-CLEAN] Waiting for Docker... %s/%s seconds' "${elapsed}" "${WAIT_TIMEOUT}"
        sleep "${WAIT_INTERVAL}"
        elapsed=$((elapsed + WAIT_INTERVAL))
    done

    printf '\n'
    warn "Timed out waiting for Docker after ${WAIT_TIMEOUT}s."
    "${QEMU_BIN}" status || true
    return 1
}

start_fresh_vm() {
    local attempt=1

    while [ "${attempt}" -le "${RETRY_COUNT}" ]; do
        log "Attempt ${attempt}/${RETRY_COUNT} to start a fresh QEMU Docker VM"
        cleanup_qemu_state

        if [ -z "${QEMU_BIN}" ] || [ ! -x "${QEMU_BIN}" ]; then
            warn "termux-qemu-docker is not on PATH. Check that the package is installed before retrying."
            return 1
        fi

        if "${QEMU_BIN}" start; then
            log "QEMU start command succeeded. Checking Docker readiness..."
        else
            warn "QEMU start command exited with a non-zero status."
        fi

        if wait_for_docker; then
            return 0
        fi

        warn "The guest did not become ready; removing stale state and retrying."
        attempt=$((attempt + 1))
    done

    warn "The QEMU Docker VM never became ready after ${RETRY_COUNT} attempts."
    warn "Check the guest boot log and consider running this on a host with working nested virtualization support."
    return 1
}

if [ -n "${QEMU_BIN}" ] && [ -x "${QEMU_BIN}" ]; then
    start_fresh_vm
    exit $?
fi

if command -v docker >/dev/null 2>&1; then
    log "Docker is available in this environment; no QEMU reset is needed."
    log "If this is a local workstation, run Docker directly instead of the Termux QEMU workaround."
    exit 0
fi

warn "No supported QEMU Docker wrapper was found and Docker is not installed."
warn "This script is intended for either a Termux QEMU environment or a local Docker-capable machine."
warn "Install Docker or termux-qemu-docker and rerun."
exit 1
