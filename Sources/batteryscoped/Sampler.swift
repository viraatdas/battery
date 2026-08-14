import BatteryCore
import Foundation
import os

/// The sampling loop.
///
/// One tick writes a battery sample (always) and a batch of process samples
/// (only when powermetrics is usable and the machine is actually on battery or
/// charging). Every failure below the battery read is logged and swallowed:
/// a daemon that exits on a transient powermetrics hiccup collects nothing.
public final class Sampler {

    private let configuration: Configuration
    private let store: SQLiteStore
    private let log = Logger(subsystem: "com.batteryscope.daemon", category: "sampler")
    private let processLog = Logger(subsystem: "com.batteryscope.daemon", category: "powermetrics")

    /// Timestamp of the last retention sweep; sweeps run at most hourly.
    private var lastPruneAt: Date?
    /// Set once so the degraded-mode explanation is printed a single time.
    private var warnedAboutPrivileges = false

    public init(configuration: Configuration, store: SQLiteStore) {
        self.configuration = configuration
        self.store = store
    }

    /// Runs one tick. Never throws: the caller is a `while true`.
    public func tick(now: Date = Date()) {
        let timestampMs = Int64((now.timeIntervalSince1970 * 1000).rounded())

        let battery: BatterySample?
        do {
            let sample = try BatteryReader.read(timestampMs: timestampMs)
            try store.insert(batterySample: sample)
            battery = sample
            log.debug("""
                battery \(sample.percent, format: .fixed(precision: 1))% \
                \(sample.wattsDrawn, format: .fixed(precision: 2))W \
                charging=\(sample.isCharging) ac=\(sample.externalPower)
                """)
        } catch {
            battery = nil
            log.error("battery sample failed: \(String(describing: error), privacy: .public)")
        }

        sampleProcesses(timestampMs: timestampMs, battery: battery)
        pruneIfDue(now: now)
    }

    // MARK: - Process sampling

    /// A machine parked on AC at a full charge is not draining anything
    /// interesting, so the (expensive) powermetrics call is skipped. When the
    /// battery read failed we have no idea what the state is, so we sample.
    public static func shouldSkipProcessSampling(battery: BatterySample?) -> Bool {
        guard let battery else { return false }
        return battery.externalPower && !battery.isCharging && battery.percent >= 99.5
    }

    private func sampleProcesses(timestampMs: Int64, battery: BatterySample?) {
        if Sampler.shouldSkipProcessSampling(battery: battery) {
            processLog.debug("skipping process sample: on AC at full charge")
            return
        }
        guard PowermetricsRunner.isAvailable() else {
            warnAboutPrivilegesOnce()
            return
        }

        switch PowermetricsRunner.sampleTasks() {
        case .failure(let failure):
            processLog.error("powermetrics failed: \(failure.description, privacy: .public)")
        case .success(let data):
            do {
                let samples = try PowermetricsParser.parse(data, timestampMs: timestampMs)
                guard !samples.isEmpty else {
                    processLog.notice("powermetrics returned no tasks")
                    return
                }
                try store.insert(processSamples: samples)
                processLog.debug("wrote \(samples.count) process samples")
            } catch {
                processLog.error("powermetrics parse/write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Running unprivileged is a supported, documented mode — not an error —
    /// so it is explained once on stdout and never repeated.
    private func warnAboutPrivilegesOnce() {
        guard !warnedAboutPrivileges else { return }
        warnedAboutPrivileges = true
        processLog.notice("per-process energy unavailable: powermetrics requires root")
        print(Sampler.degradedModeMessage)
    }

    public static let degradedModeMessage =
        "note: battery samples only — per-process energy needs root; "
        + "install the daemon with `sudo ./Scripts/install-daemon.sh`."

    // MARK: - Retention

    private func pruneIfDue(now: Date) {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < 3600 { return }
        lastPruneAt = now
        do {
            try store.prune(olderThanDays: Configuration.retentionDays, now: now)
            log.debug("pruned samples older than \(Configuration.retentionDays) days")
        } catch {
            log.error("prune failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Loop

    /// Samples forever at the configured interval. The sleep is measured from
    /// the tick's start so a slow powermetrics call does not shift the cadence.
    public func run() {
        log.notice("""
            batteryscoped started: interval=\(self.configuration.intervalSeconds)s \
            db=\(self.configuration.databasePath, privacy: .public)
            """)
        while true {
            let startedAt = Date()
            tick(now: startedAt)
            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = configuration.intervalSeconds - elapsed
            if remaining > 0 {
                Thread.sleep(forTimeInterval: remaining)
            }
        }
    }
}
