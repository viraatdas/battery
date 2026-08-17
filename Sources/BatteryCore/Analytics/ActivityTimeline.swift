import Foundation

/// The machine's workload over the day, in fixed slices you can point at.
///
/// The drain chart this sits above answers "what happened to the battery",
/// which is a summary. This answers a different question — "what was my Mac
/// doing at 3:15, and what was responsible" — and the difference that matters
/// is that every slice can be opened.
///
/// Slices are aligned to wall-clock boundaries rather than to the window's
/// start, so 3:15 means 3:15 whatever range is selected and the same slice
/// carries the same numbers between refreshes.
public enum ActivityTimeline {

    /// The default slice width. Five minutes is short enough to isolate a
    /// build or a runaway process, and long enough that a day fits in a few
    /// hundred bars.
    public static let defaultSliceSeconds: TimeInterval = 300

    /// Builds the timeline for `window`.
    ///
    /// - Parameters:
    ///   - pressure: machine-wide samples; supplies CPU, memory, and disk.
    ///   - battery: battery samples; supply watts and energy, and only while
    ///     discharging — there is nothing to measure on AC.
    ///   - stalls: episodes to mark, so a bar can be flagged without the caller
    ///     re-deriving them.
    public static func build(
        window: TimeWindow,
        pressure: [PressureSample],
        battery: [BatterySample] = [],
        stalls: [StallEpisode] = [],
        sliceSeconds: TimeInterval = defaultSliceSeconds
    ) -> [ActivitySlice] {
        guard sliceSeconds > 0 else { return [] }
        let sorted = pressure.sorted { $0.timestampMs < $1.timestampMs }
        guard !sorted.isEmpty else { return [] }

        // Rates need a predecessor, so each sample is paired with the one
        // before it and the pair is filed under the *later* sample's slice.
        var accumulators: [Date: Accumulator] = [:]
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            let seconds = Double(current.timestampMs - previous.timestampMs) / 1000
            // A gap this wide spans sleep, a stopped sampler, or a stall; the
            // counters either side of it do not describe a rate.
            guard seconds > 0, seconds <= 180, current.isSameSamplerRun(as: previous) else { continue }

            let date = Date(timeIntervalSince1970: Double(current.timestampMs) / 1000)
            let sliceStart = align(date, to: sliceSeconds)
            var accumulator = accumulators[sliceStart] ?? Accumulator()
            accumulator.add(current: current, previous: previous, seconds: seconds)
            accumulators[sliceStart] = accumulator
        }

        // Battery goes in by interval too, and only the discharging ones: watts
        // while plugged in describe the charger, not the workload.
        let sortedBattery = battery.sorted { $0.timestampMs < $1.timestampMs }
        if sortedBattery.count > 1 {
            for index in 1..<sortedBattery.count {
                let previous = sortedBattery[index - 1]
                let current = sortedBattery[index]
                let seconds = Double(current.timestampMs - previous.timestampMs) / 1000
                guard seconds > 0, seconds <= 180 else { continue }
                let date = Date(timeIntervalSince1970: Double(current.timestampMs) / 1000)
                let sliceStart = align(date, to: sliceSeconds)
                var accumulator = accumulators[sliceStart] ?? Accumulator()
                accumulator.add(battery: current, seconds: seconds)
                accumulators[sliceStart] = accumulator
            }
        }

        let windowStart = align(window.start, to: sliceSeconds)
        return accumulators
            .filter { $0.key >= windowStart && $0.key < window.end }
            .map { start, accumulator in
                accumulator.slice(
                    start: start,
                    end: start.addingTimeInterval(sliceSeconds),
                    stalls: stalls
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Rounds `date` down to a multiple of `seconds` since the epoch, which for
    /// any divisor of an hour lands on a clean wall-clock boundary.
    ///
    /// Public because a caller building a window to match the timeline needs
    /// the same boundaries the timeline itself uses.
    public static func align(_ date: Date, to seconds: TimeInterval) -> Date {
        let interval = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (interval / seconds).rounded(.down) * seconds)
    }

    /// Running totals for one slice, kept time-weighted so an irregular sample
    /// cadence does not bias the mean toward whichever stretch was sampled most.
    struct Accumulator {
        var cpuCoreSeconds: Double = 0
        var cpuSeconds: Double = 0
        var peakCPUCores: Double = 0
        var memoryFractionSeconds: Double = 0
        var memorySeconds: Double = 0
        var peakMemoryFraction: Double = 0
        var diskByteTotal: Double = 0
        var diskSeconds: Double = 0
        var peakDiskBytesPerS: Double = 0
        var wattSeconds: Double = 0
        var dischargingSeconds: Double = 0
        var externalPowerSeconds: Double = 0
        var worstMemoryLevel: PressureLevel = .nominal
        var worstThermalLevel: PressureLevel = .nominal
        var peakSwapUsedBytes: Int64 = 0
        var sampleCount = 0

        mutating func add(current: PressureSample, previous: PressureSample, seconds: Double) {
            sampleCount += 1

            if let cores = current.cpuCoresBusy(since: previous) {
                cpuCoreSeconds += cores * seconds
                cpuSeconds += seconds
                peakCPUCores = max(peakCPUCores, cores)
            }
            if let fraction = current.memoryUsedFraction {
                memoryFractionSeconds += fraction * seconds
                memorySeconds += seconds
                peakMemoryFraction = max(peakMemoryFraction, fraction)
            }
            let diskDelta = max(0, current.diskReadBytes - previous.diskReadBytes)
                + max(0, current.diskWriteBytes - previous.diskWriteBytes)
            if current.diskReadBytes > 0 || current.diskWriteBytes > 0 {
                diskByteTotal += Double(diskDelta)
                diskSeconds += seconds
                peakDiskBytesPerS = max(peakDiskBytesPerS, Double(diskDelta) / seconds)
            }
            worstMemoryLevel = max(worstMemoryLevel, current.memoryLevel)
            worstThermalLevel = max(worstThermalLevel, current.thermalLevel)
            peakSwapUsedBytes = max(peakSwapUsedBytes, current.swapUsedBytes)
        }

        mutating func add(battery: BatterySample, seconds: Double) {
            if battery.externalPower {
                externalPowerSeconds += seconds
                return
            }
            // Negative watts are the discharge; charging is not workload.
            guard battery.wattsDrawn < 0 else { return }
            wattSeconds += abs(battery.wattsDrawn) * seconds
            dischargingSeconds += seconds
        }

        func slice(start: Date, end: Date, stalls: [StallEpisode]) -> ActivitySlice {
            let overlapping = stalls.filter { $0.start < end && $0.end > start }
            return ActivitySlice(
                start: start,
                end: end,
                meanCPUCores: cpuSeconds > 0 ? cpuCoreSeconds / cpuSeconds : nil,
                peakCPUCores: cpuSeconds > 0 ? peakCPUCores : nil,
                meanMemoryUsedFraction: memorySeconds > 0 ? memoryFractionSeconds / memorySeconds : nil,
                peakMemoryUsedFraction: memorySeconds > 0 ? peakMemoryFraction : nil,
                meanDiskBytesPerS: diskSeconds > 0 ? diskByteTotal / diskSeconds : nil,
                peakDiskBytesPerS: diskSeconds > 0 ? peakDiskBytesPerS : nil,
                meanWatts: dischargingSeconds > 0 ? wattSeconds / dischargingSeconds : nil,
                energyWh: dischargingSeconds > 0 ? wattSeconds / 3600 : nil,
                dischargingSeconds: dischargingSeconds,
                externalPowerSeconds: externalPowerSeconds,
                worstMemoryLevel: worstMemoryLevel,
                worstThermalLevel: worstThermalLevel,
                peakSwapUsedBytes: peakSwapUsedBytes,
                stallSeverity: overlapping.map(\.severity).max(),
                sampleCount: sampleCount
            )
        }
    }

    // MARK: - Drill-down

    /// What was running during `slice`, ranked.
    ///
    /// Two sources, in order of preference:
    ///
    /// 1. `process_samples` — powermetrics energy impact for *every* process,
    ///    which is a true share of the machine's energy. Root only.
    /// 2. `tracked_samples` — the heaviest few processes plus every agent
    ///    session member, sampled from the process table with no privilege.
    ///
    /// The second is a top-N list, not a complete accounting, and says so via
    /// `isComplete`. It is still the answer to "what was that spike", which is
    /// what someone clicking a bar is asking.
    public static func breakdown(
        slice: ActivitySlice,
        tracked: [ProcessSample],
        processSamples: [ProcessSample] = [],
        machine: MachineProfile? = nil,
        limit: Int = 8
    ) -> ActivityBreakdown {
        let startMs = Int64(slice.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(slice.end.timeIntervalSince1970 * 1000)
        func inSlice(_ samples: [ProcessSample]) -> [ProcessSample] {
            samples.filter { $0.timestampMs >= startMs && $0.timestampMs < endMs }
        }

        let energyRows = inSlice(processSamples)
        if !energyRows.isEmpty {
            return ActivityBreakdown(
                slice: slice,
                basis: .energyImpact,
                isComplete: true,
                rows: energyRanked(energyRows, machine: machine, limit: limit),
                sessions: AgentSessions.sessions(samples: inSlice(tracked))
            )
        }

        let trackedRows = inSlice(tracked)
        return ActivityBreakdown(
            slice: slice,
            basis: .cpuAndMemory,
            isComplete: false,
            rows: resourceRanked(trackedRows, machine: machine, limit: limit),
            sessions: AgentSessions.sessions(samples: trackedRows)
        )
    }

    /// Ranked by share of the slice's total energy impact, helper processes
    /// merged into their app the same way the battery attribution does it.
    private static func energyRanked(
        _ samples: [ProcessSample],
        machine: MachineProfile?,
        limit: Int
    ) -> [ActivityBreakdownRow] {
        var totals: [String: ActivityBreakdownRow] = [:]
        for sample in samples {
            let name = AppNameNormalizer.canonicalName(for: sample.name, bundlePathHint: sample.bundlePathHint)
            var row = totals[name] ?? ActivityBreakdownRow(
                name: name,
                category: sample.category,
                energyImpact: 0,
                peakCPUCores: 0,
                peakResidentBytes: nil,
                peakDiskBytesPerS: nil,
                sharePct: nil
            )
            row.energyImpact += sample.energyImpact
            row.peakCPUCores = max(row.peakCPUCores, sample.cpuCores)
            if let resident = sample.residentBytes {
                row.peakResidentBytes = max(row.peakResidentBytes ?? 0, resident)
            }
            totals[name] = row
        }

        let total = totals.values.reduce(0) { $0 + $1.energyImpact }
        return totals.values
            .map { row -> ActivityBreakdownRow in
                var updated = row
                updated.sharePct = total > 0 ? row.energyImpact / total * 100 : nil
                return updated
            }
            .sorted { ($0.energyImpact, $1.name) > ($1.energyImpact, $0.name) }
            .prefix(limit)
            .map { $0 }
    }

    /// Ranked by CPU, then memory — the best available ordering when there is
    /// no energy signal to rank by.
    private static func resourceRanked(
        _ samples: [ProcessSample],
        machine: MachineProfile?,
        limit: Int
    ) -> [ActivityBreakdownRow] {
        struct Key: Hashable {
            var pid: Int32
            var name: String
        }
        var peaks: [Key: ActivityBreakdownRow] = [:]
        for sample in samples {
            let key = Key(pid: sample.pid, name: sample.name)
            var row = peaks[key] ?? ActivityBreakdownRow(
                name: sample.name,
                category: sample.category,
                energyImpact: 0,
                peakCPUCores: 0,
                peakResidentBytes: nil,
                peakDiskBytesPerS: nil,
                sharePct: nil
            )
            row.peakCPUCores = max(row.peakCPUCores, sample.cpuCores)
            if let resident = sample.residentBytes {
                row.peakResidentBytes = max(row.peakResidentBytes ?? 0, resident)
            }
            if let disk = sample.diskBytesPerS {
                row.peakDiskBytesPerS = max(row.peakDiskBytesPerS ?? 0, disk)
            }
            peaks[key] = row
        }

        // Share of the machine's cores, which is the honest denominator here —
        // not a share of the listed rows, since the list is deliberately partial.
        let cores = Double(machine?.cpuCount ?? 0)
        return peaks.values
            .map { row -> ActivityBreakdownRow in
                var updated = row
                updated.sharePct = cores > 0 ? row.peakCPUCores / cores * 100 : nil
                return updated
            }
            .sorted { lhs, rhs in
                if lhs.peakCPUCores != rhs.peakCPUCores { return lhs.peakCPUCores > rhs.peakCPUCores }
                if (lhs.peakResidentBytes ?? 0) != (rhs.peakResidentBytes ?? 0) {
                    return (lhs.peakResidentBytes ?? 0) > (rhs.peakResidentBytes ?? 0)
                }
                return lhs.name < rhs.name
            }
            .prefix(limit)
            .map { $0 }
    }
}

/// One slice of the day.
public struct ActivitySlice: Sendable, Hashable, Identifiable {
    public var id: Date { start }

    public var start: Date
    public var end: Date
    /// Cores' worth of CPU actually consumed, averaged over the slice. This is
    /// real utilisation from the kernel's tick counters, not a load average.
    public var meanCPUCores: Double?
    public var peakCPUCores: Double?
    public var meanMemoryUsedFraction: Double?
    public var peakMemoryUsedFraction: Double?
    public var meanDiskBytesPerS: Double?
    public var peakDiskBytesPerS: Double?
    /// Mean watts leaving the battery, over the discharging part of the slice
    /// only. `nil` whenever the Mac was on AC for all of it.
    public var meanWatts: Double?
    /// Watt-hours actually taken from the battery during the slice.
    public var energyWh: Double?
    public var dischargingSeconds: TimeInterval
    public var externalPowerSeconds: TimeInterval
    public var worstMemoryLevel: PressureLevel
    public var worstThermalLevel: PressureLevel
    public var peakSwapUsedBytes: Int64
    /// Set when a stall episode overlapped this slice.
    public var stallSeverity: PressureLevel?
    public var sampleCount: Int

    public init(
        start: Date,
        end: Date,
        meanCPUCores: Double?,
        peakCPUCores: Double?,
        meanMemoryUsedFraction: Double?,
        peakMemoryUsedFraction: Double?,
        meanDiskBytesPerS: Double?,
        peakDiskBytesPerS: Double?,
        meanWatts: Double?,
        energyWh: Double?,
        dischargingSeconds: TimeInterval,
        externalPowerSeconds: TimeInterval,
        worstMemoryLevel: PressureLevel,
        worstThermalLevel: PressureLevel,
        peakSwapUsedBytes: Int64,
        stallSeverity: PressureLevel?,
        sampleCount: Int
    ) {
        self.start = start
        self.end = end
        self.meanCPUCores = meanCPUCores
        self.peakCPUCores = peakCPUCores
        self.meanMemoryUsedFraction = meanMemoryUsedFraction
        self.peakMemoryUsedFraction = peakMemoryUsedFraction
        self.meanDiskBytesPerS = meanDiskBytesPerS
        self.peakDiskBytesPerS = peakDiskBytesPerS
        self.meanWatts = meanWatts
        self.energyWh = energyWh
        self.dischargingSeconds = dischargingSeconds
        self.externalPowerSeconds = externalPowerSeconds
        self.worstMemoryLevel = worstMemoryLevel
        self.worstThermalLevel = worstThermalLevel
        self.peakSwapUsedBytes = peakSwapUsedBytes
        self.stallSeverity = stallSeverity
        self.sampleCount = sampleCount
    }

    /// True when the Mac was on battery for any of this slice, so the watt and
    /// watt-hour figures mean something.
    public var hasBatteryData: Bool { dischargingSeconds > 0 }
}

/// What a breakdown was ranked by, which governs how it should be read.
public enum ActivityBasis: String, Sendable, Hashable {
    /// powermetrics energy impact: a true share of the machine's energy, and a
    /// complete accounting of every process.
    case energyImpact
    /// CPU and memory from the process table: honest measurements, but only of
    /// the heaviest processes rather than all of them.
    case cpuAndMemory

    public var label: String {
        switch self {
        case .energyImpact: return "by energy"
        case .cpuAndMemory: return "by CPU"
        }
    }
}

/// One process (or app) inside a slice's breakdown.
public struct ActivityBreakdownRow: Sendable, Hashable, Identifiable {
    public var id: String { name }

    public var name: String
    public var category: ProcessCategory
    public var energyImpact: Double
    public var peakCPUCores: Double
    public var peakResidentBytes: Int64?
    public var peakDiskBytesPerS: Double?
    /// Share of the slice's energy (energy basis) or of the machine's cores
    /// (CPU basis). `nil` when there is no sensible denominator.
    public var sharePct: Double?

    public init(
        name: String,
        category: ProcessCategory,
        energyImpact: Double,
        peakCPUCores: Double,
        peakResidentBytes: Int64?,
        peakDiskBytesPerS: Double?,
        sharePct: Double?
    ) {
        self.name = name
        self.category = category
        self.energyImpact = energyImpact
        self.peakCPUCores = peakCPUCores
        self.peakResidentBytes = peakResidentBytes
        self.peakDiskBytesPerS = peakDiskBytesPerS
        self.sharePct = sharePct
    }
}

/// Everything behind one slice.
public struct ActivityBreakdown: Sendable, Hashable {
    public var slice: ActivitySlice
    public var basis: ActivityBasis
    /// False when the rows are a top-N rather than every process.
    public var isComplete: Bool
    public var rows: [ActivityBreakdownRow]
    /// Agent sessions alive during the slice, so a spike caused by six agents
    /// reads as one thing rather than six rows.
    public var sessions: [AgentSession]

    public init(
        slice: ActivitySlice,
        basis: ActivityBasis,
        isComplete: Bool,
        rows: [ActivityBreakdownRow],
        sessions: [AgentSession]
    ) {
        self.slice = slice
        self.basis = basis
        self.isComplete = isComplete
        self.rows = rows
        self.sessions = sessions
    }
}
