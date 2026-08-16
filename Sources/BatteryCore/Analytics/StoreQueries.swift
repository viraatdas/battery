import Foundation

/// Per-process totals over a window, already collapsed across samples.
public struct ProcessTotals: Sendable, Hashable {
    /// Raw process name as recorded by the sampler.
    public var name: String
    public var category: ProcessCategory
    /// Sum of `energyImpact` across every sample of this process.
    public var energyImpact: Double
    /// Largest single-sample energy impact.
    public var peakEnergyImpact: Double
    /// Sum of `cpuMsPerS` across every sample.
    public var cpuMsPerSSum: Double
    public var sampleCount: Int

    public init(
        name: String,
        category: ProcessCategory,
        energyImpact: Double,
        peakEnergyImpact: Double,
        cpuMsPerSSum: Double,
        sampleCount: Int
    ) {
        self.name = name
        self.category = category
        self.energyImpact = energyImpact
        self.peakEnergyImpact = peakEnergyImpact
        self.cpuMsPerSSum = cpuMsPerSSum
        self.sampleCount = sampleCount
    }
}

/// The two rollups of one window's process samples, produced together.
public struct ProcessRollups: Sendable {
    public var totals: [ProcessTotals]
    public var agentTimeline: [AgentSessions.Tick]

    public init(totals: [ProcessTotals], agentTimeline: [AgentSessions.Tick]) {
        self.totals = totals
        self.agentTimeline = agentTimeline
    }
}

/// Aggregate fetches the analytics layer needs on top of the raw sample reads.
///
/// These roll up in one streaming pass over the store's fetch API rather than in
/// SQL: `SQLiteStore` keeps its connection private, and the analytics layer is
/// not allowed to reach into it. Collapsing by `(name, category)` here still cuts
/// a 20k-row window down to a few hundred rows before any of the attribution
/// work runs, and the pass itself is linear with no intermediate copies.
extension SQLiteStore {

    /// Per-process totals for `[from, to]`, collapsed by `(name, category)` and
    /// ordered by descending energy impact.
    public func processTotals(from: Date, to: Date) throws -> [ProcessTotals] {
        try processTotals(of: processSamples(from: from, to: to))
    }

    /// Both rollups the report needs, from one fetch.
    ///
    /// `process_samples` is the large table — one row per process per tick — so
    /// the difference between one pass and two over a 7-day window is real.
    /// Callers that need only one rollup should keep using the single-purpose
    /// method above; this exists for `Analytics.report`, which needs both.
    public func processRollups(from: Date, to: Date) throws -> ProcessRollups {
        let samples = try processSamples(from: from, to: to)
        return ProcessRollups(
            totals: processTotals(of: samples),
            agentTimeline: AgentSessions.timeline(samples: samples)
        )
    }

    private func processTotals(of samples: [ProcessSample]) -> [ProcessTotals] {
        struct Key: Hashable {
            var name: String
            var category: ProcessCategory
        }

        var accumulator: [Key: ProcessTotals] = [:]
        for sample in samples {
            let key = Key(name: sample.name, category: sample.category)
            if var existing = accumulator[key] {
                existing.energyImpact += sample.energyImpact
                existing.peakEnergyImpact = max(existing.peakEnergyImpact, sample.energyImpact)
                existing.cpuMsPerSSum += sample.cpuMsPerS
                existing.sampleCount += 1
                accumulator[key] = existing
            } else {
                accumulator[key] = ProcessTotals(
                    name: sample.name,
                    category: sample.category,
                    energyImpact: sample.energyImpact,
                    peakEnergyImpact: sample.energyImpact,
                    cpuMsPerSSum: sample.cpuMsPerS,
                    sampleCount: 1
                )
            }
        }

        return accumulator.values.sorted {
            if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
            return $0.name < $1.name
        }
    }

    /// Most recent battery sample at or before `asOf`, searching back `lookback`
    /// seconds. Returns `nil` when the daemon has written nothing in that span.
    public func latestBatterySample(asOf: Date, lookback: TimeInterval) throws -> BatterySample? {
        try batterySamples(from: asOf.addingTimeInterval(-abs(lookback)), to: asOf).last
    }
}
