#!/bin/bash
#
# Removes the BatteryScope sampling daemon.
#
# The collected database is deliberately left in place — uninstalling the
# sampler should not throw away weeks of history. Pass --purge to delete it too.
#
# Usage: sudo ./Scripts/uninstall-daemon.sh [--purge]

set -euo pipefail

LABEL="com.batteryscope.daemon"
INSTALL_PATH="/usr/local/libexec/batteryscoped"
DATA_DIR="/Library/Application Support/BatteryScope"
LOG_DIR="/Library/Logs/BatteryScope"
INSTALLED_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALLED_NEWSYSLOG_CONF="/etc/newsyslog.d/batteryscope.conf"
PURGE=0

for argument in "$@"; do
    case "${argument}" in
        --purge)
            PURGE=1
            ;;
        *)
            echo "error: unknown option '${argument}' (expected --purge)" >&2
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo $0" >&2
    exit 1
fi

echo "==> Unloading ${LABEL}"
launchctl bootout "system/${LABEL}" 2>/dev/null || true

echo "==> Removing ${INSTALLED_PLIST}"
rm -f "${INSTALLED_PLIST}"

echo "==> Removing ${INSTALL_PATH}"
rm -f "${INSTALL_PATH}"

echo "==> Removing ${INSTALLED_NEWSYSLOG_CONF}"
rm -f "${INSTALLED_NEWSYSLOG_CONF}"

if [ "${PURGE}" -eq 1 ]; then
    echo "==> Purging ${DATA_DIR}"
    rm -rf "${DATA_DIR}"
    echo "==> Purging ${LOG_DIR}"
    rm -rf "${LOG_DIR}"
else
    echo "==> Keeping collected data in ${DATA_DIR} (re-run with --purge to delete)"
    echo "==> Keeping logs in ${LOG_DIR}"
fi

echo "==> Done. BatteryScope is uninstalled."
