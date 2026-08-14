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

    /// Cycle count, maximum capacity, and a runtime estimate at the median drain
    /// rate measured over the recent past (`Options.healthLookbackSeconds`).
    ///
    /// Returns `nil` when no battery sample exists in the lookback window.
    ///
    /// - Parameter now: the instant to treat as "now"; pass an explicit value
    ///   for reproducible results.
    public func batteryHealth(now: Date = Date()) throws -> BatteryHealth? {
        let window = TimeWindow.last(options.healthLookbackSeconds, ending: now)
        guard let latest = try store.latestBatterySample(
            asOf: now,
            lookback: options.healthLookbackSeconds
        ) else { return nil }

        let series = try drainSeries(window: window, bucket: .fifteenMinutes)
        let rate = series.medianPctPerHour ?? series.overallPctPerHour
        // A zero rate is real (idle on battery) but says nothing about runtime.
        let usableRate = (rate ?? 0) > 0 ? rate : nil

        return BatteryHealth(
            cycleCount: latest.cycleCount,
            maxCapacityPct: latest.maxCapacityPct,
            percent: latest.percent,
            isCharging: latest.isCharging,
            externalPower: latest.externalPower,
            sampledAt: Date(timeIntervalSince1970: Double(latest.timestampMs) / 1000),
            medianPctPerHour: rate,
            medianWatts: series.medianWatts ?? series.overallWatts,
            fullChargeRuntimeHours: usableRate.map { 100 / $0 },
            estimatedHoursRemaining: usableRate.map { latest.percent / $0 },
            measuredOver: window
        )
    }

    // MARK: - 5. Insights

    /// Ranked, plain-English findings for `window`, most severe first.
    ///
    /// Health is measured as of the window's end rather than wall time, so the
    /// whole result is a pure function of what is in the database.
    public func insights(window: TimeWindow) throws -> [Insight] {
        let series = try drainSeries(window: window)
        let processes = try topProcesses(window: window, limit: nil, series: series)
        let categories = Attribution.categoryUsage(processes: processes)
        let health = try batteryHealth(now: window.end)

        return InsightEngine.insights(InsightContext(
            window: window,
            series: series,
            processes: processes,
            categories: categories,
            health: health,
            timeZone: options.timeZone,
            thresholds: options.thresholds
        ))
    }

    // MARK: - Everything at once

    /// One window's full picture, computed with a single pass over the samples.
    ///
    /// Prefer this over calling the individual queries back to back: they would
    /// each re-read and re-bucket the same window.
    public func report(window: TimeWindow, processLimit: Int? = 10) throws -> AnalyticsReport {
        let series = try drainSeries(window: window)
        let allProcesses = try topProcesses(window: window, limit: nil, series: series)
        let categories = Attribution.categoryUsage(processes: allProcesses)
        let health = try batteryHealth(now: window.end)
        let insights = InsightEngine.insights(InsightContext(
            window: window,
            series: series,
            processes: allProcesses,
            categories: categories,
            health: health,
            timeZone: options.timeZone,
            thresholds: options.thresholds
        ))

        return AnalyticsReport(
            window: window,
            series: series,
            processes: processLimit.map { Array(allProcesses.prefix(max(0, $0))) } ?? allProcesses,
            categories: categories,
            health: health,
            insights: insights
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

    public init(
        window: TimeWindow,
        series: DrainSeries,
        processes: [ProcessUsage],
        categories: [CategoryUsage],
        health: BatteryHealth?,
        insights: [Insight]
    ) {
        self.window = window
        self.series = series
        self.processes = processes
        self.categories = categories
        self.health = health
        self.insights = insights
    }
}
