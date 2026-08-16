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

        samplePressure(timestampMs: timestampMs)

        // One process-table read per tick, shared by both consumers below. It
        // is taken unconditionally — including on AC at a full charge, where
        // the powermetrics call is skipped — because a machine wedged while
        // plugged in is exactly the case worth recording.
        let processTable = ProcessTableReader.snapshot()
        sampleTrackedProcesses(timestampMs: timestampMs, snapshot: processTable)
        sampleProcesses(timestampMs: timestampMs, battery: battery, processTable: processTable)
        pruneIfDue(now: now)
    }

    // MARK: - Agent sampling

    /// The previous tick's process table, kept so cumulative CPU counters can
    /// be turned into a rate.
    private var previousProcessTable: ProcessTableReader.PreviousSnapshot?

    /// Records the members of every coding-agent process tree.
    ///
    /// Runs whether or not powermetrics is available: ancestry, memory, and CPU
    /// time all come from the process table, which needs no privilege. This is
    /// what lets an unprivileged sampler still answer "which session was
    /// holding the machine when it froze" — the question that does not wait for
    /// someone to install a daemon.
    private func sampleTrackedProcesses(timestampMs: Int64, snapshot: [Int32: ProcessTableReader.Entry]) {
        defer {
            previousProcessTable = ProcessTableReader.PreviousSnapshot(
                timestampMs: timestampMs,
                entries: snapshot
            )
        }
        guard !snapshot.isEmpty else { return }
        do {
            let samples = ProcessTableReader.trackedSamples(
                timestampMs: timestampMs,
                snapshot: snapshot,
                previous: previousProcessTable
            )
            guard !samples.isEmpty else { return }
            try store.insert(trackedSamples: samples)
            log.debug("wrote \(samples.count) tracked samples")
        } catch {
            log.error("tracked sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Pressure sampling

    /// Records machine-wide memory/CPU/thermal pressure.
    ///
    /// Unconditional, unlike process sampling: it needs no root and costs a
    /// few sysctls, and a stall on AC power at a full charge is exactly the
    /// case the process sampler skips — and exactly the case someone hunting a
    /// hang cares about.
    private func samplePressure(timestampMs: Int64) {
        do {
            let sample = SystemPressureReader.read(
                timestampMs: timestampMs,
                intervalSeconds: configuration.pressureIntervalSeconds
            )
            try store.insert(pressureSample: sample)
            log.debug("""
                pressure memory=\(sample.memoryLevel.rawValue, privacy: .public) \
                thermal=\(sample.thermalLevel.rawValue, privacy: .public) \
                load=\(sample.loadAverage1m, format: .fixed(precision: 2)) \
                swap=\(sample.swapUsedBytes / 1_048_576)MB
                """)
        } catch {
            log.error("pressure sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Process sampling

    /// A machine parked on AC at a full charge is not draining anything
    /// interesting, so the (expensive) powermetrics call is skipped. When the
    /// battery read failed we have no idea what the state is, so we sample.
    public static func shouldSkipProcessSampling(battery: BatterySample?) -> Bool {
        guard let battery else { return false }
        return battery.externalPower && !battery.isCharging && battery.percent >= 99.5
    }

    private func sampleProcesses(
        timestampMs: Int64,
        battery: BatterySample?,
        processTable: [Int32: ProcessTableReader.Entry]
    ) {
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
                let parsed = try PowermetricsParser.parse(data, timestampMs: timestampMs)
                guard !parsed.isEmpty else {
                    processLog.notice("powermetrics returned no tasks")
                    return
                }
                // Ancestry and resident memory come from the kernel, not from
                // powermetrics, so the tick's process-table read is folded in
                // here rather than repeated.
                let samples = ProcessTableReader.enrich(parsed, with: processTable)
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

    /// Samples forever, at two cadences.
    ///
    /// A full tick — battery, process table, powermetrics — runs every
    /// `intervalSeconds`. Between those, the much cheaper pressure read runs
    /// every `pressureIntervalSeconds`, so a stall shorter than a full tick
    /// still leaves a trace. Both sleeps are measured from their start instant,
    /// so a slow powermetrics call delays a tick without shifting the cadence.
    public func run() {
        log.notice("""
            batteryscoped started: interval=\(self.configuration.intervalSeconds)s \
            pressure=\(self.configuration.pressureIntervalSeconds)s \
            db=\(self.configuration.databasePath, privacy: .public)
            """)
        while true {
            let startedAt = Date()
            tick(now: startedAt)
            sleepUntilNextTick(after: startedAt)
        }
    }

    /// Waits out the remainder of this tick's interval, taking pressure
    /// readings on the way.
    private func sleepUntilNextTick(after startedAt: Date) {
        let nextTickAt = startedAt.addingTimeInterval(configuration.intervalSeconds)
        let pressureInterval = configuration.pressureIntervalSeconds
        guard pressureInterval > 0, pressureInterval < configuration.intervalSeconds else {
            let remaining = nextTickAt.timeIntervalSinceNow
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            return
        }

        // Sub-tick instants are computed from the tick's start rather than
        // accumulated, so a slow read cannot drift the whole schedule late.
        var nextPressureAt = startedAt.addingTimeInterval(pressureInterval)
        while nextPressureAt < nextTickAt {
            let wait = nextPressureAt.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            samplePressure(timestampMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
            nextPressureAt = nextPressureAt.addingTimeInterval(pressureInterval)
        }

        let remaining = nextTickAt.timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }
}
