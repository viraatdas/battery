import Foundation

/// Read-only analytics over the sample database: where did the battery go?
///
/// Every query takes an explicit `TimeWindow`, so results are reproducible and
/// the caller decides what "recent" means. The struct holds a `SQLiteStore`
/// (normally opened read-only against the daemon's database) and does no
/// caching — each call re-reads the window it needs.
///
/// A note on units, because it governs how to read every number below: macOS
/// reports a unitless *energy impact* score per process. There is no per-process
/// wattmeter. So watt-hours and battery-percent figures per app are produced by
/// apportioning the battery's *measured* discharge across processes in
/// proportion to their share of total energy impact. Rankings and shares are
/// solid; per-app watt-hours are an estimate.
public struct Analytics: Sendable {

    public typealias Options = AnalyticsOptions

    public let store: SQLiteStore
    public var options: Options

    public init(store: SQLiteStore, options: Options = Options()) {
        self.store = store
        self.options = options
    }

    /// Opens the database read-only at `path`. Throws if it does not exist yet.
    public init(
        readOnlyPath path: String = BatteryScopePaths.defaultDBPath,
        options: Options = Options()
    ) throws {
        self.init(store: try SQLiteStore(path: path, mode: .readOnly), options: options)
    }

    // MARK: - 1. Drain over time

    /// Battery level and drain rate over `window`, bucketed for charting.
    ///
    /// Charging stretches and sleep gaps are excluded from the rate math and
    /// reported separately (`DrainSeries.gaps`, and the per-bucket
    /// `chargingSeconds` / `sleepSeconds`) so a chart can shade them rather than
    /// draw a misleading flat line.
    ///
    /// - Parameter bucket: bucket width; defaults to one chosen from the window
    ///   length so a chart gets roughly 60 points.
    public func drainSeries(window: TimeWindow, bucket: Bucket? = nil) throws -> DrainSeries {
        let resolved = bucket ?? Bucket.auto(for: window)
        let samples = try store.batterySamples(from: window.start, to: window.end)
        return DrainAnalyzer.analyze(
            samples: samples,
            window: window,
            bucket: resolved,
            options: options
        )
    }

    // MARK: - 2. Per-process attribution

    /// Biggest energy users over `window`, helper processes merged into their app.
    ///
    /// `estimatedWh` and `estimatedPercentPoints` on each row are apportioned
    /// from the window's measured discharge by energy-impact share — see the
    /// note on this type.
    ///
    /// - Parameter limit: maximum rows to return; pass `nil` for all of them.
    public func topProcesses(window: TimeWindow, limit: Int? = 10) throws -> [ProcessUsage] {
        let series = try drainSeries(window: window)
        return try topProcesses(window: window, limit: limit, series: series)
    }

    /// Variant that reuses a `DrainSeries` you already computed, to avoid
    /// re-reading the battery samples for the same window.
    public func topProcesses(
        window: TimeWindow,
        limit: Int? = 10,
        series: DrainSeries
    ) throws -> [ProcessUsage] {
        let totals = try store.processTotals(from: window.start, to: window.end)
        let usage = Attribution.processUsage(
            totals: totals,
            dischargeWh: series.dischargeWh,
            percentDrained: series.percentDrained
        )
        guard let limit else { return usage }
        return Array(usage.prefix(max(0, limit)))
    }

    // MARK: - 3. Category rollup

    /// The same attribution rolled up by `ProcessCategory`, each with its top
    /// three apps — browser versus terminal versus background, at a glance.
    public func categoryBreakdown(window: TimeWindow) throws -> [CategoryUsage] {
        let series = try drainSeries(window: window)
        return try categoryBreakdown(window: window, series: series)
    }

    /// Variant that reuses an already-computed `DrainSeries`.
    public func categoryBreakdown(window: TimeWindow, series: DrainSeries) throws -> [CategoryUsage] {
        let processes = try topProcesses(window: window, limit: nil, series: series)
        return Attribution.categoryUsage(processes: processes)
    }

    // MARK: - 4. Battery health

    /// Cycle count, maximum capacity, and a runtime estimate at the drain rate
    /// measured *recently* (`Options.recentRateLookbackSeconds`, anchored at
    /// the latest sample rather than wall-clock `now`), widening only as far
    /// as `Options.healthLookbackSeconds` if that recent window has no real
    /// discharging time to measure — the Mac was asleep or plugged in for
    /// all of it, say.
    ///
    /// Two things went wrong on the way to this shape, in order:
    ///
    /// 1. Averaging the rate across the whole lookback window dilutes a real,
    ///    current high-power draw with however much of that window was idle,
    ///    asleep, or charging — that is how a 45.9 W draw at 63% charge once
    ///    read as "10h 24m left" on screen.
    /// 2. Preferring the *bucket median* rate within a short recent window is
    ///    itself unstable: a short window has few buckets, and the gauge is
    ///    coarse and quantized, so a single real 1-point tick landing in one
    ///    bucket implies an outsized %/hr for that bucket alone — and with
    ///    only a handful of buckets total, the median can land squarely on
    ///    it (measured: a 45.9 W draw briefly read as "97.1%/hr" this way).
    ///    `overallPctPerHour` does not have this problem: it is
    ///    `percentDrained / dischargingHours` across *every* interval in the
    ///    window, so a brief real tick is time-weighted by the few seconds
    ///    it actually covers rather than allowed to stand in for a whole
    ///    bucket next to sparser data.
    ///
    /// So the recent window prefers `overallPctPerHour` (falling back to the
    /// bucket median only if the window somehow has no interval-level total
    /// — practically, never, once `dischargingSeconds` is nonzero), instead
    /// of the median-first order that made sense for the old, wide,
    /// many-bucket health window.
    ///
    /// Returns `nil` when no battery sample exists in the lookback window.
    ///
    /// - Parameter now: the instant to treat as "now"; pass an explicit value
    ///   for reproducible results.
    public func batteryHealth(now: Date = Date()) throws -> BatteryHealth? {
        guard let latest = try store.latestBatterySample(
            asOf: now,
            lookback: options.healthLookbackSeconds
        ) else { return nil }
        let latestSampleDate = Date(timeIntervalSince1970: Double(latest.timestampMs) / 1000)

        var lookbackSeconds = min(options.recentRateLookbackSeconds, options.healthLookbackSeconds)
        var series: DrainSeries
        while true {
            let window = TimeWindow.last(lookbackSeconds, ending: latestSampleDate)
            series = try drainSeries(window: window, bucket: Bucket.auto(for: window))
            let hasEnoughDischarge = series.dischargingSeconds >= options.thresholds.minimumDischargeMinutes * 60
            if hasEnoughDischarge || lookbackSeconds >= options.healthLookbackSeconds { break }
            lookbackSeconds = min(lookbackSeconds * 2, options.healthLookbackSeconds)
        }

        let rate = [series.overallPctPerHour, series.medianPctPerHour]
            .compactMap { $0 }
            .first { $0 > 0 }

        return BatteryHealth(
            cycleCount: latest.cycleCount,
            maxCapacityPct: latest.maxCapacityPct,
            percent: latest.percent,
            isCharging: latest.isCharging,
            externalPower: latest.externalPower,
            sampledAt: latestSampleDate,
            medianPctPerHour: rate,
            medianWatts: series.overallWatts ?? series.medianWatts,
            fullChargeRuntimeHours: rate.map { 100 / $0 },
            estimatedHoursRemaining: rate.map { latest.percent / $0 },
            measuredOver: series.window
        )
    }

    // MARK: - 5. Agent sessions and stalls

    /// Coding-agent sessions active in `window`, heaviest first.
    ///
    /// Grouped by process ancestry, so an orchestrator running six agents is
    /// one row rather than six — see `AgentSessions`. Empty against a database
    /// written before schema v3, which did not record ancestry.
    public func agentSessions(window: TimeWindow) throws -> [AgentSession] {
        AgentSessions.sessions(timeline: try agentTimeline(window: window))
    }

    /// The per-tick agent grouping for `window`.
    ///
    /// Prefers `agent_samples`, which the sampler writes on every tick with no
    /// privilege required. Falls back to the powermetrics-derived
    /// `process_samples` only when that table has nothing for the window —
    /// which covers a database recorded by a v3 daemon, where ancestry rode
    /// along on the process rows instead.
    func agentTimeline(window: TimeWindow) throws -> [AgentSessions.Tick] {
        let tracked = try store.trackedSamples(from: window.start, to: window.end)
        if !tracked.isEmpty {
            return AgentSessions.timeline(samples: tracked)
        }
        let processSamples = try store.processSamples(from: window.start, to: window.end)
        return AgentSessions.timeline(samples: processSamples)
    }

    /// Stretches of `window` the machine spent under enough memory, CPU, or
    /// thermal pressure to feel unresponsive, each with whatever agent
    /// sessions were running through it.
    ///
    /// This is the one query that answers "why did my Mac hang", which is a
    /// different question from "where did my battery go" — a stall can happen
    /// on AC power with the battery untouched.
    public func stalls(window: TimeWindow) throws -> [StallEpisode] {
        let pressure = try store.pressureSamples(from: window.start, to: window.end)
        guard !pressure.isEmpty else { return [] }
        return StallAnalyzer.episodes(
            pressure: pressure,
            tracked: try store.trackedSamples(from: window.start, to: window.end),
            thresholds: options.stallThresholds
        )
    }

    /// Memory and core count of the machine the samples came from, taken from
    /// the most recent pressure sample in `window`. `nil` when none exists.
    public func machineProfile(window: TimeWindow) throws -> MachineProfile? {
        try store.pressureSamples(from: window.start, to: window.end).last.map(MachineProfile.init)
    }

    // MARK: - 6. Insights

    /// Ranked, plain-English findings for `window`, most severe first.
    ///
    /// Health is measured as of the window's end rather than wall time, so the
    /// whole result is a pure function of what is in the database.
    public func insights(window: TimeWindow) throws -> [Insight] {
        try report(window: window, processLimit: nil).insights
    }

    // MARK: - Everything at once

    /// One window's full picture, computed with a single pass over the samples.
    ///
    /// Prefer this over calling the individual queries back to back: they would
    /// each re-read and re-bucket the same window.
    public func report(window: TimeWindow, processLimit: Int? = 10) throws -> AnalyticsReport {
        let series = try drainSeries(window: window)

        // The dedicated agent table is the better source and is small — a few
        // dozen rows per tick against several hundred — so it is read first.
        // Only when it is empty (a database from a sampler that predates it)
        // is the grouping derived from the big process table instead, and only
        // then is the extra pass over that table paid for.
        let tracked = try store.trackedSamples(from: window.start, to: window.end)

        let totals: [ProcessTotals]
        let agentTimeline: [AgentSessions.Tick]
        if tracked.isEmpty {
            let rollups = try store.processRollups(from: window.start, to: window.end)
            totals = rollups.totals
            agentTimeline = rollups.agentTimeline
        } else {
            totals = try store.processTotals(from: window.start, to: window.end)
            agentTimeline = AgentSessions.timeline(samples: tracked)
        }

        let allProcesses = Attribution.processUsage(
            totals: totals,
            dischargeWh: series.dischargeWh,
            percentDrained: series.percentDrained
        )
        let categories = Attribution.categoryUsage(processes: allProcesses)
        let health = try batteryHealth(now: window.end)

        let pressure = try store.pressureSamples(from: window.start, to: window.end)
        let stalls = pressure.isEmpty ? [] : StallAnalyzer.episodes(
            pressure: pressure,
            tracked: tracked,
            thresholds: options.stallThresholds
        )
        let agentSessions = AgentSessions.sessions(timeline: agentTimeline)

        let insights = InsightEngine.insights(InsightContext(
            window: window,
            series: series,
            processes: allProcesses,
            categories: categories,
            health: health,
            timeZone: options.timeZone,
            thresholds: options.thresholds,
            agentSessions: agentSessions,
            stalls: stalls,
            machine: pressure.last.map(MachineProfile.init)
        ))

        return AnalyticsReport(
            window: window,
            series: series,
            processes: processLimit.map { Array(allProcesses.prefix(max(0, $0))) } ?? allProcesses,
            categories: categories,
            health: health,
            insights: insights,
            agentSessions: agentSessions,
            stalls: stalls,
            pressure: pressure.last,
            machine: pressure.last.map(MachineProfile.init),
            diskBytesPerSecond: StallAnalyzer.diskBytesPerSecond(
                pressure: pressure,
                thresholds: options.stallThresholds
            )
        )
    }
}

/// Everything the UI needs for one window, from one pass over the data.
public struct AnalyticsReport: Sendable {
    public var window: TimeWindow
    public var series: DrainSeries
    public var processes: [ProcessUsage]
    public var categories: [CategoryUsage]
    public var health: BatteryHealth?
    public var insights: [Insight]
    /// Coding-agent sessions active in the window, heaviest first.
    public var agentSessions: [AgentSession]
    /// Stalls found in the window, in time order.
    public var stalls: [StallEpisode]
    /// The most recent pressure reading in the window, for a live gauge.
    public var pressure: PressureSample?
    /// Combined disk throughput at that reading, differenced against the one
    /// before it. `nil` when there is no usable pair — a single sample, or a
    /// gap too wide to difference across.
    public var diskBytesPerSecond: Double?
    /// The machine's memory and core count, for turning footprints into shares.
    public var machine: MachineProfile?

    public init(
        window: TimeWindow,
        series: DrainSeries,
        processes: [ProcessUsage],
        categories: [CategoryUsage],
        health: BatteryHealth?,
        insights: [Insight],
        agentSessions: [AgentSession] = [],
        stalls: [StallEpisode] = [],
        pressure: PressureSample? = nil,
        machine: MachineProfile? = nil,
        diskBytesPerSecond: Double? = nil
    ) {
        self.window = window
        self.series = series
        self.processes = processes
        self.categories = categories
        self.health = health
        self.insights = insights
        self.agentSessions = agentSessions
        self.stalls = stalls
        self.pressure = pressure
        self.machine = machine
        self.diskBytesPerSecond = diskBytesPerSecond
    }
}
