#!/bin/bash
#
# Installs BatteryScope for the current user. No root, no password.
#
# The sampler runs as a LaunchAgent in your own login session and the menu bar
# app is added as a login item, so both survive reboots without anything living
# in a system directory.
#
# What you give up by not being root: per-process *energy* attribution, which
# comes from `powermetrics` and is root-only. Everything else — memory pressure,
# swap, disk I/O, CPU saturation, thermal throttling, coding-agent sessions, and
# the stall episodes built from all of it — comes from the process table and VM
# statistics, which any user can read. So the "why did my Mac hang" half works
# fully here; only the "where did my battery go, per app" half wants root.
#
# Run `sudo ./Scripts/install-daemon.sh` later if you want that too; the two
# coexist, and the app prefers the system database when both exist.
#
# Re-running this is safe: every step is idempotent and an already-loaded agent
# is booted out first.
#
# Usage: ./Scripts/install-agent.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLER_LABEL="com.batteryscope.sampler"
MENUBAR_LABEL="com.batteryscope.menubar"
APP_BUNDLE_ID="com.batteryscope.app"
BINARY_NAME="batteryscoped"

INSTALL_ROOT="${HOME}/.batteryscope"
INSTALL_BIN="${INSTALL_ROOT}/${BINARY_NAME}"
INSTALL_APP="${INSTALL_ROOT}/BatteryScope.app"
AGENTS_DIR="${HOME}/Library/LaunchAgents"
SAMPLER_PLIST="${AGENTS_DIR}/${SAMPLER_LABEL}.plist"
MENUBAR_PLIST="${AGENTS_DIR}/${MENUBAR_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/BatteryScope"
LOG_FILE="${LOG_DIR}/sampler.log"
DATA_DIR="${HOME}/Library/Application Support/BatteryScope"
SCRATCH_PATH="${REPO_ROOT}/.build-release"
DOMAIN="gui/$(id -u)"

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as yourself, not with sudo." >&2
    echo "       (for the root sampler, use: sudo ./Scripts/install-daemon.sh)" >&2
    exit 1
fi

echo "==> Building ${BINARY_NAME} (release)"
(cd "${REPO_ROOT}" && swift build -c release --scratch-path "${SCRATCH_PATH}" --product "${BINARY_NAME}")

BUILT_BINARY="${SCRATCH_PATH}/release/${BINARY_NAME}"
if [ ! -x "${BUILT_BINARY}" ]; then
    echo "error: build did not produce ${BUILT_BINARY}" >&2
    exit 1
fi

echo "==> Building BatteryScope.app"
(cd "${REPO_ROOT}" && ./Scripts/bundle-app.sh > /dev/null)

BUILT_APP="${REPO_ROOT}/dist/BatteryScope.app"
if [ ! -d "${BUILT_APP}" ]; then
    echo "error: build did not produce ${BUILT_APP}" >&2
    exit 1
fi

echo "==> Installing to ${INSTALL_ROOT}"
mkdir -p "${INSTALL_ROOT}" "${AGENTS_DIR}" "${LOG_DIR}" "${DATA_DIR}"
install -m 755 "${BUILT_BINARY}" "${INSTALL_BIN}"
# Replace wholesale rather than copying over the top: a stale file left inside
# an app bundle from a previous version is how signatures start failing.
rm -rf "${INSTALL_APP}"
cp -R "${BUILT_APP}" "${INSTALL_APP}"

echo "==> Writing LaunchAgents"

cat > "${SAMPLER_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SAMPLER_LABEL}</string>

    <!-- Ties this agent to the app so System Settings > General > Login Items
         shows it as BatteryScope with its icon, rather than a bare executable
         path labelled "Item from unidentified developer". -->
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>${APP_BUNDLE_ID}</string>
    </array>

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_BIN}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <!-- Background subjects the process to launchd's aggressive idle throttling,
         which coalesces and defers timers. Wrong for a sampler whose entire job
         is a metronomic cadence — and doubly wrong here, because a deferred tick
         is indistinguishable from the machine being too wedged to schedule us,
         which is a signal this tool reports on. -->
    <key>ProcessType</key>
    <string>Adaptive</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>LowPriorityIO</key>
    <false/>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>

    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

cat > "${MENUBAR_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${MENUBAR_LABEL}</string>

    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>${APP_BUNDLE_ID}</string>
    </array>

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_APP}/Contents/MacOS/BatteryScope</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Restarted if it exits, but not if the user quits it from the menu: that
         is what SuccessfulExit=false distinguishes. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

plutil -lint "${SAMPLER_PLIST}" > /dev/null
plutil -lint "${MENUBAR_PLIST}" > /dev/null

# The root daemon supersedes this sampler: it reads every process, including
# the root-owned ones an unprivileged agent is denied, and it alone can run
# powermetrics. Installing both would mean two samplers writing two databases,
# and re-running this script would silently undo the handover the daemon
# installer performed.
AGENT_PLISTS=("${SAMPLER_PLIST}" "${MENUBAR_PLIST}")
if [ -f "/Library/LaunchDaemons/com.batteryscope.daemon.plist" ]; then
    echo "==> Root daemon is installed; it supersedes the unprivileged sampler"
    echo "    installing the menu bar app only"
    AGENT_PLISTS=("${MENUBAR_PLIST}")
    rm -f "${SAMPLER_PLIST}"
fi

echo "==> Loading agents into ${DOMAIN}"
for plist in "${AGENT_PLISTS[@]}"; do
    label="$(basename "${plist}" .plist)"

    # `bootout` returns before the service is actually gone, and bootstrapping
    # into a domain that still holds the old one fails with a bare "Input/output
    # error" — which is what a re-install hit. Wait for it to disappear.
    launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
    for _ in $(seq 1 50); do
        launchctl print "${DOMAIN}/${label}" > /dev/null 2>&1 || break
        sleep 0.2
    done

    if ! launchctl bootstrap "${DOMAIN}" "${plist}"; then
        echo "error: could not load ${label}." >&2
        echo "       Try: launchctl bootout ${DOMAIN}/${label} && $0" >&2
        exit 1
    fi
    launchctl enable "${DOMAIN}/${label}" 2>/dev/null || true
done

echo "==> Waiting for fresh samples"
DB="${DATA_DIR}/batteryscope.db"
if [ -f "/Library/Application Support/BatteryScope/batteryscope.db" ]; then
    DB="/Library/Application Support/BatteryScope/batteryscope.db"
fi
# Only rows written *after* this point count. Counting every row would report
# success from a previous install's data while this one silently failed to
# start, which is exactly the case this check exists to catch.
SINCE_MS=$(( $(date +%s) * 1000 ))
deadline=$((SECONDS + 30))
rows=0
while [ ${SECONDS} -lt ${deadline} ]; do
    if [ -f "${DB}" ]; then
        rows="$(sqlite3 "${DB}" \
            "select count(*) from pressure_samples where timestamp_ms >= ${SINCE_MS};" \
            2>/dev/null || echo 0)"
        if [ "${rows}" -ge 2 ] 2>/dev/null; then
            break
        fi
    fi
    sleep 2
done

if [ "${rows}" -ge 2 ] 2>/dev/null; then
    echo "    sampler is running — ${rows} fresh samples written"
else
    echo "warning: the sampler has not written samples yet." >&2
    echo "         Check the log: ${LOG_FILE}" >&2
    if [ -f "${LOG_FILE}" ]; then
        echo "--- last 20 lines ---" >&2
        tail -20 "${LOG_FILE}" >&2
    fi
fi

echo
echo "==> Done. BatteryScope is in your menu bar and will start at login."
echo "    Data:      ${DATA_DIR}"
echo "    Log:       ${LOG_FILE}"
echo "    Status:    launchctl print ${DOMAIN}/${SAMPLER_LABEL}"
echo "    Uninstall: ./Scripts/uninstall-agent.sh"
echo
echo "    Per-app battery attribution needs powermetrics, which needs root."
echo "    Optional: sudo ./Scripts/install-daemon.sh"
