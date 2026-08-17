#!/bin/bash
#
# Removes the per-user BatteryScope agents, binary, and app.
#
# The collected database is kept by default — it is the only copy of your
# machine's history and there is no way to regenerate it. Pass --purge to delete
# it too.
#
# Usage: ./Scripts/uninstall-agent.sh [--purge]

set -euo pipefail

SAMPLER_LABEL="com.batteryscope.sampler"
MENUBAR_LABEL="com.batteryscope.menubar"
INSTALL_ROOT="${HOME}/.batteryscope"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/BatteryScope"
DATA_DIR="${HOME}/Library/Application Support/BatteryScope"
DOMAIN="gui/$(id -u)"

PURGE=0
for argument in "$@"; do
    case "${argument}" in
        --purge) PURGE=1 ;;
        *) echo "error: unknown option '${argument}'" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as yourself, not with sudo." >&2
    echo "       (for the root sampler, use: sudo ./Scripts/uninstall-daemon.sh)" >&2
    exit 1
fi

echo "==> Unloading agents"
for label in "${SAMPLER_LABEL}" "${MENUBAR_LABEL}"; do
    launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
    rm -f "${AGENTS_DIR}/${label}.plist"
    echo "    ${label}"
done

# The menu bar app is bootstrapped by launchd but a user may also have opened it
# by hand, in which case that copy is not launchd's to stop.
pkill -f "${INSTALL_ROOT}/BatteryScope.app/Contents/MacOS/BatteryScope" 2>/dev/null || true

echo "==> Removing ${INSTALL_ROOT}"
rm -rf "${INSTALL_ROOT}"

echo "==> Removing logs"
rm -rf "${LOG_DIR}"

if [ "${PURGE}" -eq 1 ]; then
    echo "==> Purging collected data in ${DATA_DIR}"
    rm -rf "${DATA_DIR}"
else
    if [ -d "${DATA_DIR}" ]; then
        echo "==> Keeping collected data in ${DATA_DIR}"
        echo "    (re-run with --purge to delete it)"
    fi
fi

echo
echo "==> Done."
