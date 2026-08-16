import Foundation

// MARK: - Time windows

/// A closed time range that every analytics query is scoped to.
///
/// Windows are always explicit so results are reproducible: callers pass the
/// `now` they want the window anchored to rather than relying on wall time.
public struct TimeWindow: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// Seconds covered by the window.
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Hours covered by the window.
    public var hours: Double { duration / 3600 }
    /// The instant halfway through the window.
    public var midpoint: Date { start.addingTimeInterval(duration / 2) }

    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    /// A window of `duration` seconds ending at `end`.
    public static func last(_ duration: TimeInterval, ending end: Date) -> TimeWindow {
        TimeWindow(start: end.addingTimeInterval(-abs(duration)), end: end)
    }

    public static func lastHours(_ hours: Double, ending end: Date) -> TimeWindow {
        last(hours * 3600, ending: end)
    }

    public static func lastHour(ending end: Date) -> TimeWindow { lastHours(1, ending: end) }
    public static func last6Hours(ending end: Date) -> TimeWindow { lastHours(6, ending: end) }
    public static func last24Hours(ending end: Date) -> TimeWindow { lastHours(24, ending: end) }
    public static func last7Days(ending end: Date) -> TimeWindow { lastHours(24 * 7, ending: end) }
}

/// Bucket width used to downsample a window into chartable points.
public struct Bucket: Codable, Sendable, Hashable {
    /// Bucket width in seconds; always > 0.
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds > 0 ? seconds : 60
    }

    public static let minute = Bucket(seconds: 60)
    public static let fiveMinutes = Bucket(seconds: 300)
    public static let fifteenMinutes = Bucket(seconds: 900)
    public static let halfHour = Bucket(seconds: 1800)
    public static let hour = Bucket(seconds: 3600)
    public static let sixHours = Bucket(seconds: 21600)
    public static let day = Bucket(seconds: 86400)

    static let ladder: [Bucket] = [
        .minute, .fiveMinutes, .fifteenMinutes, .halfHour, .hour, .sixHours, .day,
    ]

    /// Smallest ladder bucket that keeps the window under `targetPoints` points.
    public static func auto(for window: TimeWindow, targetPoints: Int = 60) -> Bucket {
        let target = max(1, targetPoints)
        for candidate in ladder where window.duration / candidate.seconds <= Double(target) {
            return candidate
        }
        return ladder[ladder.count - 1]
    }
}

// MARK: - Drain series

/// One chartable point: battery level plus the drain measured inside the bucket.
///
/// Rates are `nil` when the bucket contains no measurable discharge (the Mac was
/// asleep, plugged in, or simply had no samples), so a chart can leave a hole
/// rather than drawing a fake zero.
public struct DrainPoint: Codable, Sendable, Hashable {
    public var bucketStart: Date
    public var bucketEnd: Date
    /// Mean battery charge of the samples inside the bucket, `nil` if there were none.
    public var percent: Double?
    /// Battery percentage points lost to measured discharge inside the bucket.
    public var percentDrop: Double
    /// Watt-hours discharged inside the bucket, from the sampled power draw.
    public var energyWh: Double
    /// Mean discharge rate over the discharging time in this bucket.
    public var pctPerHour: Double?
    /// Mean discharge power over the discharging time in this bucket.
    public var watts: Double?
    /// Seconds of measured discharge backing `pctPerHour` / `watts`.
    public var dischargingSeconds: Double
    /// Seconds spent charging or on AC power (excluded from drain math).
    public var chargingSeconds: Double
    /// Seconds covered by a sleep gap (excluded from drain math).
    public var sleepSeconds: Double

    public init(
        bucketStart: Date,
        bucketEnd: Date,
        percent: Double? = nil,
        percentDrop: Double = 0,
        energyWh: Double = 0,
        pctPerHour: Double? = nil,
        watts: Double? = nil,
        dischargingSeconds: Double = 0,
        chargingSeconds: Double = 0,
        sleepSeconds: Double = 0
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.percent = percent
        self.percentDrop = percentDrop
        self.energyWh = energyWh
        self.pctPerHour = pctPerHour
        self.watts = watts
        self.dischargingSeconds = dischargingSeconds
        self.chargingSeconds = chargingSeconds
        self.sleepSeconds = sleepSeconds
    }

    /// True when the bucket has neither samples nor covered time.
    public var isEmpty: Bool {
        percent == nil && dischargingSeconds == 0 && chargingSeconds == 0 && sleepSeconds == 0
    }
}

/// A stretch of wall time with no samples, long enough to mean the Mac slept.
public struct SleepGap: Codable, Sendable, Hashable {
    /// Timestamp of the last sample before the gap.
    public var start: Date
    /// Timestamp of the first sample after the gap.
    public var end: Date
    /// Battery percentage points lost across the gap (never negative).
    public var percentLost: Double
    /// True when either side of the gap was charging or on AC power.
    public var wasCharging: Bool

    public init(start: Date, end: Date, percentLost: Double, wasCharging: Bool) {
        self.start = start
        self.end = end
        self.percentLost = percentLost
        self.wasCharging = wasCharging
    }

    public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }
    public var hours: Double { durationSeconds / 3600 }
    /// Drain rate across the gap; `nil` for gaps shorter than a second.
    public var pctPerHour: Double? {
        guard hours > 0 else { return nil }
        return percentLost / hours
    }
}

/// Battery level and drain rate over a window, bucketed for charting.
public struct DrainSeries: Codable, Sendable, Hashable {
    public var window: TimeWindow
    /// Bucket width the points were computed at.
    public var bucketSeconds: Double
    public var points: [DrainPoint]
    /// Sleep gaps inside the window, for shading the chart.
    public var gaps: [SleepGap]
    /// Nominal spacing between samples, inferred as the median sample delta.
    public var sampleIntervalSeconds: Double
    /// Total percentage points lost to measured discharge (excludes sleep and charging).
    public var percentDrained: Double
    /// Total watt-hours discharged over the window.
    public var dischargeWh: Double
    public var dischargingSeconds: Double
    public var chargingSeconds: Double
    public var sleepSeconds: Double
    /// Discharge rate across the whole window: `percentDrained` over discharging time.
    public var overallPctPerHour: Double?
    /// Mean discharge power across the whole window.
    public var overallWatts: Double?
    /// Median of the per-bucket discharge rates; more robust than the mean to spikes.
    public var medianPctPerHour: Double?
    /// Median of the per-bucket discharge power.
    public var medianWatts: Double?

    public init(
        window: TimeWindow,
        bucketSeconds: Double,
        points: [DrainPoint],
        gaps: [SleepGap],
        sampleIntervalSeconds: Double,
        percentDrained: Double,
        dischargeWh: Double,
        dischargingSeconds: Double,
        chargingSeconds: Double,
        sleepSeconds: Double,
        overallPctPerHour: Double?,
        overallWatts: Double?,
        medianPctPerHour: Double?,
        medianWatts: Double?
    ) {
        self.window = window
        self.bucketSeconds = bucketSeconds
        self.points = points
        self.gaps = gaps
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.percentDrained = percentDrained
        self.dischargeWh = dischargeWh
        self.dischargingSeconds = dischargingSeconds
        self.chargingSeconds = chargingSeconds
        self.sleepSeconds = sleepSeconds
        self.overallPctPerHour = overallPctPerHour
        self.overallWatts = overallWatts
        self.medianPctPerHour = medianPctPerHour
        self.medianWatts = medianWatts
    }

    /// Battery percent lost across all sleep gaps that were not charging.
    public var sleepPercentLost: Double {
        gaps.filter { !$0.wasCharging }.reduce(0) { $0 + $1.percentLost }
    }

    public var hasDischargeData: Bool { dischargingSeconds > 0 }
}

// MARK: - Attribution

/// One app's share of the window's battery use, after helper processes are merged in.
///
/// `estimatedWh` and `estimatedPercentPoints` are ESTIMATES. macOS reports a
/// unitless "energy impact" score per process, not joules, so we apportion the
/// measured battery discharge across processes in proportion to their share of
/// total energy impact. That is a reasonable ranking, not a calorimeter.
public struct ProcessUsage: Codable, Sendable, Hashable {
    /// Canonical app name; helper processes are folded into their parent app.
    public var name: String
    public var category: ProcessCategory
    /// Summed energy impact across every sample of every merged process.
    public var energyImpact: Double
    /// Share of the window's total energy impact, 0...100.
    public var sharePct: Double
    /// Estimated watt-hours drawn, apportioned from measured discharge by share.
    public var estimatedWh: Double
    /// Estimated battery percentage points consumed, apportioned by share.
    public var estimatedPercentPoints: Double
    /// Highest single-sample energy impact seen for this app.
    public var peakEnergyImpact: Double
    /// Number of process samples merged into this row.
    public var sampleCount: Int
    /// Raw process names that were merged into this row, sorted.
    public var mergedProcessNames: [String]

    public init(
        name: String,
        category: ProcessCategory,
        energyImpact: Double,
        sharePct: Double,
        estimatedWh: Double,
        estimatedPercentPoints: Double,
        peakEnergyImpact: Double,
        sampleCount: Int,
        mergedProcessNames: [String]
    ) {
        self.name = name
        self.category = category
        self.energyImpact = energyImpact
        self.sharePct = sharePct
        self.estimatedWh = estimatedWh
        self.estimatedPercentPoints = estimatedPercentPoints
        self.peakEnergyImpact = peakEnergyImpact
        self.sampleCount = sampleCount
        self.mergedProcessNames = mergedProcessNames
    }
}

/// A `ProcessCategory` rollup of the same attribution, with its biggest contributors.
public struct CategoryUsage: Codable, Sendable, Hashable {
    public var category: ProcessCategory
    public var energyImpact: Double
    public var sharePct: Double
    public var estimatedWh: Double
    public var estimatedPercentPoints: Double
    /// Highest-impact apps in this category, at most three.
    public var topProcesses: [ProcessUsage]

    public init(
        category: ProcessCategory,
        energyImpact: Double,
        sharePct: Double,
        estimatedWh: Double,
        estimatedPercentPoints: Double,
        topProcesses: [ProcessUsage]
    ) {
        self.category = category
        self.energyImpact = energyImpact
        self.sharePct = sharePct
        self.estimatedWh = estimatedWh
        self.estimatedPercentPoints = estimatedPercentPoints
        self.topProcesses = topProcesses
    }
}

// MARK: - Health

/// Battery condition plus a runtime estimate from recently measured drain.
public struct BatteryHealth: Codable, Sendable, Hashable {
    /// Charge cycles reported by the most recent sample.
    public var cycleCount: Int
    /// Maximum capacity as a percentage of design capacity.
    public var maxCapacityPct: Double
    /// Charge level of the most recent sample.
    public var percent: Double
    public var isCharging: Bool
    public var externalPower: Bool
    /// Timestamp of the sample these readings came from.
    public var sampledAt: Date
    /// Median recent discharge rate the estimates below are based on.
    public var medianPctPerHour: Double?
    public var medianWatts: Double?
    /// Hours a full charge would last at `medianPctPerHour`.
    public var fullChargeRuntimeHours: Double?
    /// Hours left from the current charge at `medianPctPerHour`.
    public var estimatedHoursRemaining: Double?
    /// Window the recent drain rate was measured over.
    public var measuredOver: TimeWindow

    public init(
        cycleCount: Int,
        maxCapacityPct: Double,
        percent: Double,
        isCharging: Bool,
        externalPower: Bool,
        sampledAt: Date,
        medianPctPerHour: Double?,
        medianWatts: Double?,
        fullChargeRuntimeHours: Double?,
        estimatedHoursRemaining: Double?,
        measuredOver: TimeWindow
    ) {
        self.cycleCount = cycleCount
        self.maxCapacityPct = maxCapacityPct
        self.percent = percent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.sampledAt = sampledAt
        self.medianPctPerHour = medianPctPerHour
        self.medianWatts = medianWatts
        self.fullChargeRuntimeHours = fullChargeRuntimeHours
        self.estimatedHoursRemaining = estimatedHoursRemaining
        self.measuredOver = measuredOver
    }
}

// MARK: - Insights

public enum InsightSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case info
    case notice
    case warning
    case critical

    var rank: Int {
        switch self {
        case .info: return 0
        case .notice: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A ranked, plain-English finding about where the battery went.
public struct Insight: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier for the rule that produced this insight.
    public var id: String
    public var severity: InsightSeverity
    /// One-line headline.
    public var title: String
    /// Supporting sentence with the numbers behind the headline.
    public var detail: String
    /// Ranking score within a severity band; higher sorts first.
    public var score: Double

    public init(id: String, severity: InsightSeverity, title: String, detail: String, score: Double) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.score = score
    }
}

/// Cutoffs that decide when an insight rule fires. Exposed so the UI (and tests)
/// can tune sensitivity without forking the rules.
public struct InsightThresholds: Sendable, Hashable, Codable {
    /// A single app must reach this share of drain to be called out.
    public var topProcessSharePct: Double = 15
    /// Combined background+system share that counts as "a lot".
    public var backgroundSharePct: Double = 20
    /// Second-half / first-half drain ratio that counts as a real change.
    public var trendRatio: Double = 1.5
    /// Battery points lost while asleep before we mention it.
    public var sleepDrainPercent: Double = 1.0
    /// Sleep drain rate above which sleep looks unhealthy.
    public var unhealthySleepPctPerHour: Double = 1.0
    /// Discharge rate that counts as heavy use.
    public var highDrainPctPerHour: Double = 20
    /// Maximum capacity below which the battery is considered worn.
    public var wornCapacityPct: Double = 80
    /// Cycle count worth mentioning.
    public var highCycleCount: Int = 1000
    /// Minimum measured discharge before rate-based rules are trustworthy.
    public var minimumDischargeMinutes: Double = 10
    /// Share of the window on battery below which attribution is called thin.
    public var mostlyPluggedInDischargeShare: Double = 0.25
    /// Share of the machine's memory (or cores) an agent session must hold
    /// before a stall is named on it, rather than merely reported alongside
    /// it. Attribution here is correlational, so the bar is deliberately high
    /// enough that a small session running during someone else's stall is not
    /// blamed for it.
    public var attributionShare: Double = 0.35

    public init() {}
}

/// Tuning for the analytics engine as a whole.
public struct AnalyticsOptions: Sendable {
    /// A sample delta longer than this multiple of the nominal interval is sleep.
    public var sleepGapFactor: Double = 3.0
    /// Absolute floor under the sleep-gap threshold, regardless of what
    /// `sleepGapFactor` x the nominal interval would otherwise allow. An
    /// unprivileged sampler getting descheduled for under two minutes is
    /// ordinary OS scheduling jitter, not the Mac actually sleeping —
    /// confirmed against a live database sampling every ~20s, where a purely
    /// relative 3x threshold (60s there) misclassified a whole cluster of
    /// 74-1239s scheduling gaps as sleep.
    ///
    /// This floor alone does not fully clear that cluster — the same live
    /// database's gap distribution runs a long tail out to 1,239.5s before
    /// jumping to a handful of clearly distinct events at 1,315.8s+, so a
    /// floor sized to actually separate them would have to sit well above
    /// "a couple of minutes" and would also swallow a legitimate ~200s sleep
    /// gap at a normal 60s cadence (`sleepGapFactor` already covers that
    /// case correctly on its own). 120s is deliberately conservative: it
    /// only overrides the relative factor at fast cadences where 3x alone
    /// is clearly too tight, and leaves the rest of that cluster to
    /// `sleepGapCoalesceSeconds` and, if still too noisy for a given
    /// deployment, a higher value here — this is exposed specifically so it
    /// can be tuned per-cadence rather than hardcoded.
    public var minimumSleepGapSeconds: Double = 120
    /// Two sleep gaps separated by less than this much continuous awake time
    /// are coalesced into one, and the short awake stretch between them is
    /// folded into the merged sleep period. A Mac waking briefly mid-sleep
    /// (or the sampler hiccuping again right after a real sleep gap) should
    /// read as one sleep period, not several — "41 sleep periods" in six
    /// hours is not a number a person can act on, and it is what turned a
    /// real drain chart into a near-solid grey field.
    public var sleepGapCoalesceSeconds: Double = 300
    /// Sample spacing assumed when a window has too few samples to infer one.
    public var assumedSampleIntervalSeconds: Double = 60
    /// Time zone used when an insight names a time of day.
    public var timeZone: TimeZone = .current
    /// How far back `batteryHealth()` looks for a *sample to report on* —
    /// cycle count, capacity, charge percent — and the outer bound it will
    /// widen `recentRateLookbackSeconds` out to if there is truly nothing
    /// more recent to measure a rate from.
    public var healthLookbackSeconds: TimeInterval = 6 * 3600
    /// How far back `batteryHealth()` looks, anchored at the *latest sample*
    /// (not wall-clock `now`, which may be well after the sampler last
    /// wrote), to measure the drain rate that "time left" and "full charge"
    /// are based on. Deliberately short: a rate averaged across
    /// `healthLookbackSeconds` (6h) dilutes a real, current high-power draw
    /// with however much of that window was idle, asleep, or charging,
    /// which is how a 45.9 W draw at 63% once read as "10h 24m left" and
    /// then "52h 47m" instead of the ~1h a reader can check against the
    /// number on the current-draw line right above it. `batteryHealth()`
    /// widens this window (doubling, capped at `healthLookbackSeconds`)
    /// only when it does not yet contain `InsightThresholds
    /// .minimumDischargeMinutes` of actual discharging time to measure —
    /// e.g. the Mac has been asleep or plugged in for the whole recent
    /// window — never merely because a wider window would read differently.
    public var recentRateLookbackSeconds: TimeInterval = 15 * 60
    /// Last-resort pack capacity for `DrainAnalyzer`'s power-derived drop
    /// (see `standaloneFallbackDrop`), used only when a discharging interval
    /// never gets a real gauge tick to reconcile against (no raw mAh
    /// capacity to compute a precise one from) — a Mac whose IORegistry
    /// never exposes `AppleRaw{Current,Max}Capacity`, and — the common case
    /// in practice — every row written before this capacity data started
    /// being captured at all (a whole database is this shape until the
    /// sampler daemon restarts on the new build). 60 Wh sits roughly in the
    /// middle of the modern MacBook lineup (a 13" MacBook Air packs about
    /// 52 Wh; a 16" MacBook Pro about 100 Wh) — wrong for any one specific
    /// machine, but a nonzero rate next to a nonzero wattage is a better
    /// answer than the literal, self-contradicting zero it replaces.
    public var nominalPackWattHours: Double = 60
    public var thresholds: InsightThresholds = InsightThresholds()
    /// Cutoffs deciding when the machine counts as stalled, for
    /// `Analytics.stalls` and the stall insight.
    public var stallThresholds: StallThresholds = StallThresholds()

    public init() {}

    public init(
        sleepGapFactor: Double = 3.0,
        minimumSleepGapSeconds: Double = 120,
        sleepGapCoalesceSeconds: Double = 300,
        assumedSampleIntervalSeconds: Double = 60,
        timeZone: TimeZone = .current,
        healthLookbackSeconds: TimeInterval = 6 * 3600,
        recentRateLookbackSeconds: TimeInterval = 15 * 60,
        nominalPackWattHours: Double = 60,
        thresholds: InsightThresholds = InsightThresholds()
    ) {
        self.sleepGapFactor = sleepGapFactor
        self.minimumSleepGapSeconds = minimumSleepGapSeconds
        self.sleepGapCoalesceSeconds = sleepGapCoalesceSeconds
        self.assumedSampleIntervalSeconds = assumedSampleIntervalSeconds
        self.timeZone = timeZone
        self.healthLookbackSeconds = healthLookbackSeconds
        self.recentRateLookbackSeconds = recentRateLookbackSeconds
        self.nominalPackWattHours = nominalPackWattHours
        self.thresholds = thresholds
    }
}
