#!/bin/bash
#
# Installs the BatteryScope sampling daemon as a system LaunchDaemon.
#
# Per-process energy comes from powermetrics, which only runs as root, so the
# sampler has to live in system launchd context. Re-running this script is safe:
# every step is idempotent and an already-loaded daemon is booted out first.
#
# Usage: sudo ./Scripts/install-daemon.sh

set -euo pipefail

LABEL="com.batteryscope.daemon"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY_NAME="batteryscoped"
INSTALL_DIR="/usr/local/libexec"
INSTALL_PATH="${INSTALL_DIR}/${BINARY_NAME}"
DATA_DIR="/Library/Application Support/BatteryScope"
LOG_DIR="/Library/Logs/BatteryScope"
SOURCE_PLIST="${REPO_ROOT}/Resources/${LABEL}.plist"
INSTALLED_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SCRATCH_PATH="${REPO_ROOT}/.build-release"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo $0" >&2
    exit 1
fi

if [ ! -f "${SOURCE_PLIST}" ]; then
    echo "error: missing ${SOURCE_PLIST}" >&2
    exit 1
fi

echo "==> Building ${BINARY_NAME} (release)"
# Build as the invoking user, not root, so the build directory in the repo does
# not end up root-owned and unwritable for later non-sudo builds.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    sudo -u "${SUDO_USER}" -- bash -c \
        "cd '${REPO_ROOT}' && swift build -c release --scratch-path '${SCRATCH_PATH}' --product '${BINARY_NAME}'"
else
    (cd "${REPO_ROOT}" && swift build -c release --scratch-path "${SCRATCH_PATH}" --product "${BINARY_NAME}")
fi

BUILT_BINARY="${SCRATCH_PATH}/release/${BINARY_NAME}"
if [ ! -x "${BUILT_BINARY}" ]; then
    echo "error: build did not produce ${BUILT_BINARY}" >&2
    exit 1
fi

echo "==> Installing binary to ${INSTALL_PATH}"
install -d -m 755 "${INSTALL_DIR}"
install -m 755 -o root -g wheel "${BUILT_BINARY}" "${INSTALL_PATH}"

echo "==> Creating ${DATA_DIR}"
install -d -m 755 -o root -g wheel "${DATA_DIR}"

echo "==> Creating ${LOG_DIR}"
install -d -m 755 -o root -g wheel "${LOG_DIR}"

echo "==> Installing LaunchDaemon plist to ${INSTALLED_PLIST}"
install -m 644 -o root -g wheel "${SOURCE_PLIST}" "${INSTALLED_PLIST}"

echo "==> Unloading any previous ${LABEL}"
launchctl bootout "system/${LABEL}" 2>/dev/null || true

echo "==> Bootstrapping ${LABEL}"
launchctl bootstrap system "${INSTALLED_PLIST}"

echo "==> Done. BatteryScope is sampling."
echo "    Database: ${DATA_DIR}/batteryscope.db"
echo "    Log:      ${LOG_DIR}/daemon.log"
echo "    Status:   sudo launchctl print system/${LABEL}"
