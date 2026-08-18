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
SOURCE_NEWSYSLOG_CONF="${REPO_ROOT}/Resources/batteryscope.newsyslog.conf"
INSTALLED_NEWSYSLOG_CONF="/etc/newsyslog.d/batteryscope.conf"
SCRATCH_PATH="${REPO_ROOT}/.build-release"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: this script must run as root: sudo $0" >&2
    exit 1
fi

if [ ! -f "${SOURCE_PLIST}" ]; then
    echo "error: missing ${SOURCE_PLIST}" >&2
    exit 1
fi

if [ ! -f "${SOURCE_NEWSYSLOG_CONF}" ]; then
    echo "error: missing ${SOURCE_NEWSYSLOG_CONF}" >&2
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

# The daemon (root) writes batteryscope.db plus the -wal/-shm sidecars WAL mode
# requires; BatteryScope.app reads the database read-only as a normal user, and
# SQLite needs read access to the -shm file to read a WAL database at all. The
# LaunchDaemon plist sets Umask 022 so every file the daemon creates from now on
# comes out 0644, but that does not retroactively fix files from a previous
# install, so catch those up here too.
if compgen -G "${DATA_DIR}/batteryscope.db*" > /dev/null; then
    echo "==> Fixing up permissions on existing database files"
    chmod 644 "${DATA_DIR}"/batteryscope.db*
fi

# The app reads the system database in preference to the per-user one, so the
# moment this daemon creates one, whatever the unprivileged agent has already
# collected stops being visible. Carry it over rather than appearing to lose it.
# `.backup` rather than `cp`, because a WAL database is three files and copying
# only the first yields a stale or corrupt result.
USER_HOME="$(eval echo "~${SUDO_USER:-root}")"
USER_DB="${USER_HOME}/Library/Application Support/BatteryScope/batteryscope.db"
if [ ! -f "${DATA_DIR}/batteryscope.db" ] && [ -f "${USER_DB}" ]; then
    echo "==> Seeding the system database from ${USER_DB}"
    if sqlite3 "${USER_DB}" ".backup '${DATA_DIR}/batteryscope.db'" 2>/dev/null; then
        chown root:wheel "${DATA_DIR}/batteryscope.db"
        chmod 644 "${DATA_DIR}/batteryscope.db"
        echo "    carried over $(sqlite3 "${DATA_DIR}/batteryscope.db" \
            'select count(*) from pressure_samples;' 2>/dev/null || echo '?') pressure samples"
    else
        echo "    warning: could not copy it; starting fresh" >&2
        rm -f "${DATA_DIR}/batteryscope.db"
    fi
fi

echo "==> Creating ${LOG_DIR}"
install -d -m 755 -o root -g wheel "${LOG_DIR}"

echo "==> Installing LaunchDaemon plist to ${INSTALLED_PLIST}"
install -m 644 -o root -g wheel "${SOURCE_PLIST}" "${INSTALLED_PLIST}"

echo "==> Installing log rotation config to ${INSTALLED_NEWSYSLOG_CONF}"
install -d -m 755 -o root -g wheel "$(dirname "${INSTALLED_NEWSYSLOG_CONF}")"
install -m 644 -o root -g wheel "${SOURCE_NEWSYSLOG_CONF}" "${INSTALLED_NEWSYSLOG_CONF}"

echo "==> Unloading any previous ${LABEL}"
launchctl bootout "system/${LABEL}" 2>/dev/null || true

echo "==> Bootstrapping ${LABEL}"
launchctl bootstrap system "${INSTALLED_PLIST}"

# `launchctl bootstrap` returning 0 only means launchd accepted the job, not
# that it is actually running: a bad binary, a missing dependency, or a plist
# launchd silently rejects can all leave the daemon dead on arrival. Poll for
# a live PID for a few seconds before declaring success, and fail loudly with
# the log tail if it never shows up, instead of printing a claim we haven't
# checked.
echo "==> Verifying ${LABEL} came up"
UP=0
for _ in $(seq 1 10); do
    if launchctl print "system/${LABEL}" 2>/dev/null | grep -q 'state = running'; then
        UP=1
        break
    fi
    sleep 1
done

if [ "${UP}" -ne 1 ]; then
    echo "error: ${LABEL} did not come up within 10s" >&2
    echo "---- launchctl print system/${LABEL} ----" >&2
    launchctl print "system/${LABEL}" >&2 || true
    echo "---- tail ${LOG_DIR}/daemon.log ----" >&2
    tail -n 40 "${LOG_DIR}/daemon.log" >&2 2>/dev/null || echo "(no log yet)" >&2
    exit 1
fi

# Two samplers writing two databases is pointless work: this one runs as root,
# so it reads every process — including the root-owned ones the user agent is
# structurally denied — and it alone can run powermetrics. The menu bar agent
# stays; only the redundant sampler is retired.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    USER_UID="$(id -u "${SUDO_USER}")"
    if launchctl print "gui/${USER_UID}/com.batteryscope.sampler" > /dev/null 2>&1; then
        echo "==> Retiring the unprivileged sampler (this daemon supersedes it)"
        launchctl bootout "gui/${USER_UID}/com.batteryscope.sampler" 2>/dev/null || true
        sudo -u "${SUDO_USER}" launchctl disable "gui/${USER_UID}/com.batteryscope.sampler" 2>/dev/null || true
        rm -f "${USER_HOME}/Library/LaunchAgents/com.batteryscope.sampler.plist"
        echo "    the menu bar app keeps running; only the duplicate sampler is gone"
    fi
fi

echo "==> Done. BatteryScope is sampling."
echo "    Database: ${DATA_DIR}/batteryscope.db"
echo "    Log:      ${LOG_DIR}/daemon.log"
echo "    Status:   sudo launchctl print system/${LABEL}"
