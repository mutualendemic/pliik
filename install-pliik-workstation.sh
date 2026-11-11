
#!/usr/bin/env bash

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
#   - Uses Go 1.27.4 inside Ubuntu proot
#   - Disables automatic toolchain downloads
#   - Pins dependencies to Go 1.27-compatible versions
# ============================================================

APP_NAME="Pliik Workstation"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
PROOT_DISTRO_TAG="${PROOT_DISTRO_TAG:-24.04}"

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    export PREFIX="/usr"
    export TERMUX__PREFIX="/usr"
fi

is_termux() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        return 1
    fi

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
    printf 'PLIIK_PROOT_BOOTSTRAP=%s\n' "${PLIIK_PROOT_BOOTSTRAP:-0}"
    printf 'PREFIX=%s\n' "${PREFIX:-unset}"
    printf 'USER=%s\n' "${USER:-$(id -un 2>/dev/null || echo unknown)}"
    printf 'UID=%s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf 'PATH=%s\n' "$PATH"
    printf 'OS_RELEASE=%s\n' "$(grep -E '^NAME=' /etc/os-release 2>/dev/null | head -n 1 || echo 'not-found')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || echo 'unknown')"
    printf 'termux_dir_exists=%s\n' "$(if [ -d /data/data/com.termux/files/usr ]; then echo yes; else echo no; fi)"
    printf 'pkg_path=%s\n' "$(command -v pkg 2>/dev/null || echo not-found)"
    printf 'proot_distro_path=%s\n' "$(command -v proot-distro 2>/dev/null || echo not-found)"
    printf 'is_termux=%s\n' "$(if is_termux; then echo yes; else echo no; fi)"
    printf 'is_alpine=%s\n' "$(if is_alpine; then echo yes; else echo no; fi)"
}

is_alpine() {
    if [ -f "/etc/alpine-release" ] || command -v apk >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ensure_regular_termux_user() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        return 0
    fi

    if is_termux && [ "$(id -u)" -eq 0 ]; then
        debug_environment
        fail "This installer must run as the regular Termux user. Exit the root shell and re-run it without sudo."
    fi
}

proot_distro_exists() {
    local name="${1:-${PROOT_DISTRO}}"
    local list_output
    local installed_output
    local list_status
    local escape_sequence=$'\033'

    if list_output="$(proot-distro list 2>&1)"; then
        list_status=0
    else
        list_status=$?
    fi

    list_output="$(printf '%s\n' "$list_output" | tr -d '\r' | sed "s/${escape_sequence}\\[[0-9;]*[[:alpha:]]//g")"
    if [ "$list_status" -ne 0 ]; then
        warn "proot-distro list failed with exit status ${list_status} while checking '${name}'. Output:"
        printf '%s\n' "${list_output:-<no output>}" >&2
        return 1
    fi

    if [ -z "$list_output" ]; then
        warn "proot-distro list returned no output while checking '${name}'."
        return 1
    fi

    installed_output="$(printf '%s\n' "$list_output" | sed -n \
        -e '/^[[:space:]]*Installed containers:/,/^[[:space:]]*Supported distributions:/p' \
        -e '/^[[:space:]]*Installed distributions:/,/^[[:space:]]*Supported distributions:/p')"
    if [ -z "$installed_output" ]; then
        warn "No installed-container section was recognized while checking '${name}'. Normalized proot-distro list output:"
        printf '%s\n' "$list_output" >&2
        return 1
    fi

    if printf '%s\n' "$installed_output" | tr -cs '[:alnum:]_-' '\n' | grep -Fixq -- "$name"; then
        return 0
    fi

    warn "Container '${name}' was not found in the installed section. Normalized proot-distro list output:"
    printf '%s\n' "$list_output" >&2
    return 1
}

validate_proot_distro_container() {
    local name="${1:-${PROOT_DISTRO}}"

    if ! proot_distro_exists "$name"; then
        return 1
    fi

    if proot-distro login "$name" -- bash -lc 'test -f /etc/os-release && test -d /root'; then
        return 0
    fi

    warn "Existing proot container '${name}' failed validation. It will not be reset or removed automatically."
    return 1
}

bootstrap_proot_distro() {
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        log "Already running inside the ${PROOT_DISTRO} proot bootstrap; skipping the obsolete QEMU path."
        return 0
    fi

    if ! is_termux; then
        return 0
    fi

    if [ "$(id -u)" -eq 0 ]; then
        fail "Do not run proot-distro as root. Exit the root shell and run this installer as the regular Termux user."
    fi

    if command -v proot-distro >/dev/null 2>&1; then
        log "proot-distro detected. Ensuring ${PROOT_DISTRO} is present..."
    else
        log "Installing proot-distro in Termux..."
        pkg install -y proot-distro tar || fail "Failed to install proot-distro."
    fi

    if proot-distro list 2>/dev/null | grep -q 'alpine'; then
        log "Removing stale Alpine container before installing ${PROOT_DISTRO}."
        proot-distro remove alpine || true
    fi

    if proot_distro_exists "${PROOT_DISTRO}"; then
        if validate_proot_distro_container "${PROOT_DISTRO}"; then
            log "${PROOT_DISTRO} container is already present and valid; reusing it."
        else
            if [ -n "${PROOT_DISTRO_TAG}" ] && [ "${PROOT_DISTRO_TAG}" != "latest" ]; then
                fail "Existing '${PROOT_DISTRO}' cannot be entered. Close active proot sessions, then as the regular Termux user run: proot-distro remove ${PROOT_DISTRO} && proot-distro install ${PROOT_DISTRO}:${PROOT_DISTRO_TAG}"
            else
                fail "Existing '${PROOT_DISTRO}' cannot be entered. Close active proot sessions, then as the regular Termux user run: proot-distro remove ${PROOT_DISTRO} && proot-distro install ${PROOT_DISTRO}"
            fi
        fi
    else
        if [ -n "${PROOT_DISTRO_TAG}" ] && [ "${PROOT_DISTRO_TAG}" != "latest" ]; then
            log "Installing ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro..."
            if ! proot-distro install "${PROOT_DISTRO}:${PROOT_DISTRO_TAG}"; then
                if proot_distro_exists "${PROOT_DISTRO}"; then
                    log "The container became available after the failed install attempt; continuing."
                else
                    fail "Failed to install ${PROOT_DISTRO}:${PROOT_DISTRO_TAG} via proot-distro."
                fi
            fi
        else
            log "Installing ${PROOT_DISTRO} via proot-distro..."
            if ! proot-distro install "${PROOT_DISTRO}"; then
                if proot_distro_exists "${PROOT_DISTRO}"; then
                    log "The container became available after the failed install attempt; continuing."
                else
                    fail "Failed to install ${PROOT_DISTRO} via proot-distro."
                fi
            fi
        fi
    fi

    export PLIIK_PROOT_BOOTSTRAP=1

    log "Re-entering installer inside ${PROOT_DISTRO} proot..."
    exec env PLIIK_PROOT_BOOTSTRAP=1 PROOT_DISTRO="${PROOT_DISTRO}" proot-distro login "${PROOT_DISTRO}" -- bash -lc '
        export PLIIK_PROOT_BOOTSTRAP=1
        export PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
        if [ ! -d /root/pliik ]; then
            git clone https://github.com/mutualendemic/pliik.git /root/pliik || exit 1
        else
            git -C /root/pliik pull --ff-only origin main || {
                printf "[ERROR] Could not update /root/pliik to the latest installer.\n" >&2
                exit 1
            }
        fi
        cd /root/pliik || exit 1
        exec env PLIIK_PROOT_BOOTSTRAP=1 PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}" bash install-pliik-workstation.sh "$@"
    ' -- "$@"
}

BASE_DIR="$HOME/pliik-workstation"
PLIIK_DIR="$BASE_DIR/pliik"
VSCODE_DIR="$BASE_DIR/VS-CODE-IN-TERMUX"
QEMU_DIR="$BASE_DIR/termux-qemu-docker"

CONFIG_DIR="$HOME/.config/pliik-workstation"
PROJECTS_DIR="$BASE_DIR/projects"

BIN_DIR="${PREFIX:-/usr/local}/bin"
QEMU_BIN="$BIN_DIR/termux-qemu-docker"
QEMU_BUILD_MARKER="$CONFIG_DIR/qemu-build-key"

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

if is_alpine; then
    if command -v docker >/dev/null 2>&1; then
        log "Detected Alpine proot environment with Docker available."
        log "Skipping the QEMU-based Termux workflow and using the native Alpine Docker path instead."
        log "Run the project inside this Alpine environment directly; do not invoke the Termux QEMU installer here."
        exit 0
    fi

    log "Detected Alpine environment without Docker."
    log "Install Docker within Alpine and rerun the installer: apk add docker openrc && rc-service docker start"
    exit 1
fi

if is_termux; then
    ensure_regular_termux_user
    bootstrap_proot_distro
fi

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    log "Running the QEMU host inside ${PROOT_DISTRO} proot with software acceleration."
    export DEBIAN_FRONTEND=noninteractive
    export PREFIX="${PREFIX:-/usr}"
    command -v apt-get >/dev/null 2>&1 || fail "Ubuntu apt-get is required inside the proot environment."
fi

if ! is_termux && [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
    if command -v docker >/dev/null 2>&1; then
        log "Native Docker detected. Skipping the Termux QEMU setup path."
        log "This installer is optimized for Termux; local Docker environments should run Docker commands directly."
        exit 0
    fi

    warn "Neither Termux nor Docker was detected. This installer expects a Termux environment or a local Docker-capable workstation."
    exit 1
fi

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
    if is_termux; then
        pkg install -y openssl openssl-tool || {
            log "First OpenSSL install attempt failed; refreshing package metadata and retrying"
            pkg update -y || true
            pkg install -y openssl openssl-tool || fail "OpenSSL packages could not be installed."
        }
    else
        apt-get update -y || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl openssl-tool || fail "OpenSSL packages could not be installed."
    fi

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

if [ -z "${PREFIX:-}" ]; then
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
        debug_environment
        fail "Run this script inside Termux."
    fi
fi

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" != "1" ]; then
    case "$PREFIX" in
        /data/data/com.termux/files/usr) ;;
        *)
            debug_environment
            fail "Unsupported Termux installation."
            ;;
    esac
fi

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

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    log "Skipping Termux package-manager setup because the installer is already running inside the ${PROOT_DISTRO} proot bootstrap."
elif is_termux; then
    log "Enabling required Termux repositories"
    pkg install -y root-repo

    log "Updating Termux"
    pkg update -y

    log "Upgrading installed packages"
    pkg upgrade -y
fi

log "Installing required packages"

if is_termux; then
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
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        git curl wget ca-certificates openssl openssh-client build-essential \
        qemu-system-arm qemu-utils qemu-efi-aarch64 xorriso dosfstools \
        coreutils findutils grep sed tar
fi

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    [ -r /usr/share/AAVMF/AAVMF_CODE.fd ] || fail "Ubuntu ARM64 QEMU firmware is missing: /usr/share/AAVMF/AAVMF_CODE.fd"
    [ -r /usr/share/AAVMF/AAVMF_VARS.fd ] || fail "Ubuntu ARM64 QEMU variables firmware is missing: /usr/share/AAVMF/AAVMF_VARS.fd"
    mkdir -p /usr/share/qemu
    ln -sf /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu/edk2-aarch64-code.fd
    ln -sf /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/qemu/edk2-arm-vars.fd
    mkdir -p /share/qemu
    ln -sf /usr/share/AAVMF/AAVMF_CODE.fd /share/qemu/edk2-aarch64-code.fd
    ln -sf /usr/share/AAVMF/AAVMF_VARS.fd /share/qemu/edk2-arm-vars.fd
fi

# ------------------------------------------------------------
# Go configuration
# ------------------------------------------------------------

install_ubuntu_go() {
    local version="1.27.4"
    local architecture
    local checksum
    local archive
    local temporary_directory
    local install_directory="/opt/pliik-toolchains/go-${version}"

    case "$(uname -m)" in
        aarch64|arm64)
            architecture="arm64"
            checksum="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"
            ;;
        x86_64|amd64)
            architecture="amd64"
            checksum="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
            ;;
        *)
            fail "Go ${version} bootstrap does not support host architecture $(uname -m)."
            ;;
    esac

    mkdir -p /opt/pliik-toolchains
    if [ ! -x "${install_directory}/bin/go" ]; then
        [ ! -e "$install_directory" ] || fail "Incomplete Go toolchain directory exists: $install_directory"
        archive="$(mktemp)"
        temporary_directory="$(mktemp -d /opt/pliik-toolchains/.go-${version}.XXXXXX)"
        if ! curl -fsSL "https://go.dev/dl/go${version}.linux-${architecture}.tar.gz" -o "$archive"; then
            rm -f "$archive"
            rmdir "$temporary_directory" 2>/dev/null || true
            fail "Could not download Go ${version}."
        fi
        if ! printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null; then
            rm -f "$archive"
            rmdir "$temporary_directory" 2>/dev/null || true
            fail "Go ${version} archive checksum validation failed."
        fi
        if ! tar -xzf "$archive" -C "$temporary_directory" || ! mv "${temporary_directory}/go" "$install_directory"; then
            rm -f "$archive"
            rm -rf "$temporary_directory"
            fail "Could not install Go ${version} into $install_directory."
        fi
        rm -f "$archive"
        rmdir "$temporary_directory"
    fi

    export PATH="${install_directory}/bin:${PATH}"
    hash -r 2>/dev/null || true
}

if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
    log "Installing the pinned Go toolchain for Ubuntu QEMU builds"
    install_ubuntu_go
fi

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
    { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 27 ]; }; then
    fail "Go 1.27 or newer is required. Installed: $GO_VERSION"
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

# ------------------------------------------------------------
# Patch QEMU Go dependencies
# ------------------------------------------------------------

log "Preparing QEMU Docker Go compatibility"

cd "$QEMU_DIR"

if [ ! -f go.mod ]; then
    fail "QEMU repository does not contain go.mod."
fi

# Docker runs inside the VM, so a Docker host package is not needed.
if [ -f "pkg/setup/setup.go" ]; then
    if [ "${PLIIK_PROOT_BOOTSTRAP:-0}" = "1" ]; then
        sed -i \
            -e 's@exec.Command("pkg", args\.\.\.)@exec.Command("apt-get", args...)@' \
            -e 's@packages := \[\]string{.*}@packages := []string{"qemu-utils", "qemu-system-arm", "qemu-efi-aarch64", "openssh-client", "xorriso", "dosfstools"}@' \
            pkg/setup/setup.go
        if ! grep -Fq 'exec.Command("apt-get", args...)' pkg/setup/setup.go || \
           ! grep -Fq 'packages := []string{"qemu-utils", "qemu-system-arm", "qemu-efi-aarch64", "openssh-client", "xorriso", "dosfstools"}' pkg/setup/setup.go || \
           grep -Fq 'exec.Command("pkg"' pkg/setup/setup.go; then
            fail "Could not adapt QEMU setup requirements for Ubuntu apt."
        fi
    else
        sed -i '/packages := \[\]string{/,/}/ s/, "docker"//' pkg/setup/setup.go
        if sed -n '/packages := \[\]string{/,/}/p' pkg/setup/setup.go | grep -q '"docker"'; then
            fail "Could not remove the Docker host package from QEMU setup requirements."
        fi
    fi
fi

# The upstream go.mod requests Go 1.27.0 and uses standard-library APIs added
# after Go 1.24.
#
# Use the pinned local Go compiler and compatible dependency versions instead.

go mod edit -go=1.27.0 -toolchain=none

go mod edit \
    -require=github.com/GehirnInc/crypt@v0.0.0-20230320061759-8cc1b52080c5 \
    -require=github.com/spf13/cobra@v1.9.1 \
    -require=github.com/spf13/pflag@v1.0.6 \
    -require=github.com/inconshreveable/mousetrap@v1.1.0 \
    -require=golang.org/x/crypto@v0.38.0 \
    -require=golang.org/x/term@v0.32.0 \
    -require=golang.org/x/sys@v0.33.0 \
    -require=gopkg.in/yaml.v3@v3.0.1

# ------------------------------------------------------------
# Build QEMU Docker
# ------------------------------------------------------------

qemu_build_fingerprint() {
    (
        cd "$QEMU_DIR"
        git rev-parse HEAD
        git ls-files --cached --modified --others --exclude-standard -z | sort -z | xargs -0 sha256sum
        printf 'go=%s\n' "$GO_VERSION"
    ) | sha256sum | awk '{print $1}'
}

BUILD_KEY="$(qemu_build_fingerprint)"
if [ -x "$QEMU_BIN" ] && [ -f "$QEMU_BUILD_MARKER" ] && [ "$(cat "$QEMU_BUILD_MARKER")" = "$BUILD_KEY" ]; then
    log "QEMU manager is already built for the current sources and Go version; skipping build."
else
    log "Building termux-qemu-docker and resolving build dependencies"
    GOTOOLCHAIN=local go build \
        -mod=mod \
        -o "$QEMU_BIN" \
        main.go

    if [ ! -x "$QEMU_BIN" ]; then
        fail "QEMU Docker binary was not generated."
    fi

    BUILD_KEY="$(qemu_build_fingerprint)"
    printf '%s\n' "$BUILD_KEY" > "${QEMU_BUILD_MARKER}.tmp"
    mv -f "${QEMU_BUILD_MARKER}.tmp" "$QEMU_BUILD_MARKER"
fi

log "QEMU Docker helper is ready"

# ------------------------------------------------------------
# Configure QEMU Docker
# ------------------------------------------------------------

log "Running QEMU Docker setup"

if is_termux; then
    # Some Termux packages, including docker, live in the root-repo repository.
    # Ensure the repo is enabled before the upstream setup script invokes pkg.
    pkg install -y root-repo
    pkg update -y
fi

"$QEMU_BIN" setup

# ------------------------------------------------------------
# Start virtual machine
# ------------------------------------------------------------

QEMU_HOME="$HOME/.termux-qemu-docker"
VM_PID_FILE="$QEMU_HOME/vm-default.pid"
VM_LOG_FILE="$QEMU_HOME/qemu-default.log"
QEMU_CMD_TIMEOUT="30"
QEMU_START_TIMEOUT="300"
DOCKER_CMD_TIMEOUT="180"
DOCKER_PROBE_TIMEOUT="15"
DOCKER_PULL_TIMEOUT="600"

run_qemu_cmd() {
    local timeout_seconds="${1:-$QEMU_CMD_TIMEOUT}"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$QEMU_BIN" "$@"
    else
        "$QEMU_BIN" "$@"
    fi
}

qemu_docker_cmd() {
    local timeout_seconds="${1:-$DOCKER_CMD_TIMEOUT}"
    shift

    run_qemu_cmd "$timeout_seconds" docker "$@"
}

qemu_diagnostics() {
    local stage="${1:-unknown}"

    warn "QEMU diagnostic snapshot (stage: $stage)"
    warn "QEMU binary: $QEMU_BIN"
    warn "QEMU home: $QEMU_HOME"
    warn "Profile status: ${VM_STATUS:-unknown}"

    if [ -f "$VM_PID_FILE" ]; then
        local pid
        pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
        warn "PID file present: ${pid:-missing}"
        if [ -n "$pid" ]; then
            warn "PID process detail: $(ps -p "$pid" -o pid=,comm=,args= 2>/dev/null || echo 'not running')"
        fi
    else
        warn "PID file not present: $VM_PID_FILE"
    fi

    if [ -f "$VM_LOG_FILE" ]; then
        warn "Recent QEMU log entries:"
        tail -n 50 "$VM_LOG_FILE" >&2 || true
    else
        warn "QEMU log file not found: $VM_LOG_FILE"
    fi

    warn "QEMU home listing:"
    ls -la "$QEMU_HOME" 2>&1 || true

    warn "Process scan:"
    pgrep -af 'qemu-system|termux-qemu-docker|dockerd|alpine' || true
}

qemu_docker_ready() {
    local output
    output="$(qemu_docker_cmd "$DOCKER_PROBE_TIMEOUT" info 2>&1 || true)"

    if printf '%s\n' "$output" | grep -q 'Server Version:'; then
        return 0
    fi

    if printf '%s\n' "$output" | grep -Eq 'timed out|timeout|failed to connect|Cannot connect'; then
        warn "Docker readiness probe reported a timeout or connection failure: $output"
    fi

    return 1
}

log "Checking QEMU Docker VM status"

VM_STATUS="$(run_qemu_cmd "$QEMU_CMD_TIMEOUT" status 2>&1 || true)"
printf '%s\n' "$VM_STATUS"

if [ -f "$VM_PID_FILE" ]; then
    pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        warn "PID file references a stale process; clearing it before restart"
        rm -f "$VM_PID_FILE"
    else
        log "Default profile PID file present: ${pid:-unknown}"
    fi
fi

if printf '%s\n' "$VM_STATUS" | grep -q 'is RUNNING'; then
    log "QEMU Docker VM is already running; reusing it"
elif printf '%s\n' "$VM_STATUS" | grep -q 'is STALE'; then
    log "QEMU Docker VM PID is stale; clearing it and restarting"
    if [ -f "$VM_PID_FILE" ]; then
        stale_pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
        if [ -n "$stale_pid" ] && kill -0 "$stale_pid" 2>/dev/null; then
            warn "Killing stale QEMU process $stale_pid before restart"
            kill "$stale_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$VM_PID_FILE"
    run_qemu_cmd "$QEMU_START_TIMEOUT" start
elif printf '%s\n' "$VM_STATUS" | grep -q 'OFFLINE'; then
    log "QEMU Docker VM is offline; starting it"
    if ! run_qemu_cmd "$QEMU_START_TIMEOUT" start; then
        qemu_diagnostics "start-failed"
        fail "QEMU Docker VM failed to start within ${QEMU_START_TIMEOUT}s. See the diagnostics above for the exact VM and log state."
    fi
elif qemu_docker_ready; then
    log "QEMU Docker VM is already healthy; reusing it"
else
    log "Starting QEMU Docker VM"
    if ! run_qemu_cmd "$QEMU_START_TIMEOUT" start; then
        qemu_diagnostics "start-failed"
        fail "QEMU Docker VM failed to start within ${QEMU_START_TIMEOUT}s. See the diagnostics above for the exact VM and log state."
    fi
fi

# ------------------------------------------------------------
# Wait for Docker daemon
# ------------------------------------------------------------

log "Waiting for Docker daemon"

ELAPSED=0
DOCKER_READY=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do

    if qemu_docker_ready; then
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
    qemu_diagnostics "docker-not-ready"

    fail "Docker daemon did not become ready."
fi

log "Docker daemon is ready"

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
# Download Code Server image
# ------------------------------------------------------------

log "Downloading Code Server image"

if ! qemu_docker_cmd "$DOCKER_PULL_TIMEOUT" pull "$CODE_SERVER_IMAGE"; then
    fail "Code Server image download timed out or failed in the QEMU Docker VM."
fi

# ------------------------------------------------------------
# Remove previous container
# ------------------------------------------------------------

log "Removing previous Code Server container if present"

if ! qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
    warn "Could not remove any existing Code Server container cleanly; continuing."
fi

# ------------------------------------------------------------
# Deploy Code Server
# ------------------------------------------------------------

log "Deploying Code Server"

if ! qemu_docker_cmd "$DOCKER_CMD_TIMEOUT" run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${CODE_SERVER_PORT}:8080" \
    -e "PASSWORD=${CODE_SERVER_PASSWORD}" \
    -v "${PROJECTS_DIR}:/home/coder/project" \
    "$CODE_SERVER_IMAGE"; then
    fail "Code Server container startup timed out or failed in the QEMU Docker VM."
fi

# ------------------------------------------------------------
# Create management commands
# ------------------------------------------------------------

log "Creating management commands"

cat > "$BIN_DIR/bin-dev-start" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

STATUS="$(timeout 30s termux-qemu-docker status 2>&1 || true)"
if printf '%s\n' "$STATUS" | grep -q 'is RUNNING'; then
    echo "QEMU VM already running; reusing it."
elif printf '%s\n' "$STATUS" | grep -q 'is STALE'; then
    echo "QEMU VM status is stale; cleaning up PID file."
    rm -f "$HOME/.termux-qemu-docker/vm-default.pid"
    timeout 30s termux-qemu-docker start || true
else
    timeout 30s termux-qemu-docker start || true
fi

for i in $(seq 1 120); do
    if timeout 30s termux-qemu-docker docker info >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

timeout 30s termux-qemu-docker docker start pliik-code-server || true

echo "Code Server: http://localhost:8080"
EOF

cat > "$BIN_DIR/bin-dev-stop" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -e

timeout 30s termux-qemu-docker docker stop pliik-code-server || true
timeout 30s termux-qemu-docker stop || true
rm -f "$HOME/.termux-qemu-docker/vm-default.pid" || true

echo "Pliik Workstation stopped."
EOF

cat > "$BIN_DIR/bin-dev-status" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

echo "=== QEMU VM ==="
timeout 30s termux-qemu-docker status || true

echo
echo "=== Docker containers ==="
timeout 30s termux-qemu-docker docker ps -a || true

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
