import Foundation

/// Everything the insight rules are allowed to look at.
///
/// Bundling the inputs keeps the rules pure — they never touch a store or the
/// clock — so a scenario can be constructed directly in a test without SQLite.
public struct InsightContext: Sendable {
    public var window: TimeWindow
    public var series: DrainSeries
    public var processes: [ProcessUsage]
    public var categories: [CategoryUsage]
    public var health: BatteryHealth?
    public var timeZone: TimeZone
    public var thresholds: InsightThresholds

    public init(
        window: TimeWindow,
        series: DrainSeries,
        processes: [ProcessUsage],
        categories: [CategoryUsage],
        health: BatteryHealth?,
        timeZone: TimeZone = .current,
        thresholds: InsightThresholds = InsightThresholds()
    ) {
        self.window = window
        self.series = series
        self.processes = processes
        self.categories = categories
        self.health = health
        self.timeZone = timeZone
        self.thresholds = thresholds
    }
}

/// Deterministic rules that turn the numbers into sentences worth reading.
///
/// Each rule returns at most one insight (the category rule returns one per
/// qualifying category) and every rule is independent, so adding a rule cannot
/// change what the others say. Output is ranked by severity, then by score.
public enum InsightEngine {

    public static func insights(_ context: InsightContext) -> [Insight] {
        var found: [Insight] = []
        found.append(contentsOf: [
            noDataRule(context),
            mostlyPluggedInRule(context),
            topProcessRule(context),
            highDrainRule(context),
            trendRule(context),
            sleepDrainRule(context),
            batteryHealthRule(context),
            browserVersusTerminalRule(context),
        ].compactMap { $0 })
        found.append(contentsOf: heavyCategoryRules(context))

        return found.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
    }

    // MARK: - Rules

    /// Nothing measurable happened: say so instead of reporting zeros as facts.
    static func noDataRule(_ context: InsightContext) -> Insight? {
        guard !context.series.hasDischargeData else { return nil }
        let reason: String
        if context.series.chargingSeconds > 0 && context.series.sleepSeconds > 0 {
            reason = "you were plugged in or asleep for all of it"
        } else if context.series.chargingSeconds > 0 {
            reason = "you were plugged in for all of it"
        } else if context.series.sleepSeconds > 0 {
            reason = "your Mac was asleep for all of it"
        } else {
            reason = "there are not enough battery samples yet"
        }
        return Insight(
            id: "no-discharge-data",
            severity: .info,
            title: "No battery drain measured in \(InsightFormat.windowLabel(context.window))",
            detail: "There is nothing to attribute for this window because \(reason).",
            score: 0
        )
    }

    /// Attribution over a few minutes of battery time is noise; flag it up front.
    static func mostlyPluggedInRule(_ context: InsightContext) -> Insight? {
        let series = context.series
        guard series.hasDischargeData else { return nil }
        let covered = series.dischargingSeconds + series.chargingSeconds + series.sleepSeconds
        guard covered > 0 else { return nil }
        let share = series.dischargingSeconds / covered
        guard share < context.thresholds.mostlyPluggedInDischargeShare else { return nil }
        return Insight(
            id: "mostly-plugged-in",
            severity: .info,
            title: "You were mostly on AC power",
            detail: "Only \(InsightFormat.duration(seconds: series.dischargingSeconds)) of "
                + "\(InsightFormat.windowLabel(context.window)) ran on battery, so the breakdown "
                + "below is based on a small slice of time.",
            score: 1 - share
        )
    }

    /// The single biggest app, when one actually stands out.
    static func topProcessRule(_ context: InsightContext) -> Insight? {
        guard let top = context.processes.first, top.sharePct > 0 else { return nil }
        guard top.sharePct >= context.thresholds.topProcessSharePct else { return nil }

        var detail = "\(top.name) accounted for about \(InsightFormat.percent(top.sharePct)) of "
            + "measured energy use in \(InsightFormat.windowLabel(context.window))"
        if context.series.hasDischargeData {
            detail += " — roughly \(InsightFormat.wattHours(top.estimatedWh)) "
                + "(~\(InsightFormat.percent(top.estimatedPercentPoints)) of battery)"
        }
        detail += ". Energy impact is a relative score, so the watt-hours are an estimate."

        let severity: InsightSeverity = top.sharePct >= 40 ? .warning : .notice
        return Insight(
            id: "top-process",
            severity: severity,
            title: "\(top.name) is your biggest battery user",
            detail: detail,
            score: top.sharePct
        )
    }

    /// Heavy categories, one insight each. Background and system get a sharper
    /// headline because they are the drain a person cannot see.
    static func heavyCategoryRules(_ context: InsightContext) -> [Insight] {
        context.categories.compactMap { rollup in
            guard rollup.sharePct >= context.thresholds.backgroundSharePct else { return nil }
            let invisible = rollup.category == .background || rollup.category == .system
            let names = rollup.topProcesses.prefix(3).map(\.name)

            var detail = "\(InsightFormat.categoryLabel(rollup.category).capitalizedFirst) drew about "
                + "\(InsightFormat.percent(rollup.sharePct)) of measured energy use"
            if context.series.hasDischargeData {
                detail += " (~\(InsightFormat.wattHours(rollup.estimatedWh)), "
                    + "\(InsightFormat.percent(rollup.estimatedPercentPoints)) of battery)"
            }
            detail += " in \(InsightFormat.windowLabel(context.window))."
            if !names.isEmpty {
                detail += " Led by \(InsightFormat.list(Array(names)))."
            }

            let title = invisible
                ? "\(InsightFormat.categoryLabel(rollup.category).capitalizedFirst) are a large share of your drain"
                : "\(InsightFormat.categoryLabel(rollup.category).capitalizedFirst) led your battery use"

            return Insight(
                id: "category-share:\(rollup.category.rawValue)",
                severity: invisible && rollup.sharePct >= 35 ? .warning : .notice,
                title: title,
                detail: detail,
                score: rollup.sharePct - (invisible ? 0 : 1)
            )
        }
    }

    /// Absolute drain rate, translated into how long a charge would last.
    static func highDrainRule(_ context: InsightContext) -> Insight? {
        let series = context.series
        guard series.dischargingSeconds >= context.thresholds.minimumDischargeMinutes * 60 else {
            return nil
        }
        guard let rate = series.medianPctPerHour ?? series.overallPctPerHour,
              rate >= context.thresholds.highDrainPctPerHour
        else { return nil }

        var detail = "Your median drain over \(InsightFormat.windowLabel(context.window)) was "
            + "\(InsightFormat.rate(rate))"
        if let watts = series.medianWatts ?? series.overallWatts {
            detail += " (\(InsightFormat.watts(watts)))"
        }
        if rate > 0 {
            detail += ", which works out to about \(InsightFormat.hoursMinutes(100 / rate)) "
                + "on a full charge"
        }
        detail += "."

        return Insight(
            id: "high-drain-rate",
            severity: rate >= context.thresholds.highDrainPctPerHour * 1.5 ? .warning : .notice,
            title: "High drain rate: \(InsightFormat.rate(rate))",
            detail: detail,
            score: rate
        )
    }

    /// Did drain change partway through the window? Compares the two halves,
    /// weighting each by the time actually spent discharging.
    static func trendRule(_ context: InsightContext) -> Insight? {
        let midpoint = context.window.midpoint
        var firstDrop = 0.0, firstSeconds = 0.0
        var secondDrop = 0.0, secondSeconds = 0.0

        for point in context.series.points where point.dischargingSeconds > 0 {
            if point.bucketStart < midpoint {
                firstDrop += point.percentDrop
                firstSeconds += point.dischargingSeconds
            } else {
                secondDrop += point.percentDrop
                secondSeconds += point.dischargingSeconds
            }
        }

        let minimumSeconds = context.thresholds.minimumDischargeMinutes * 60 / 2
        guard firstSeconds >= minimumSeconds, secondSeconds >= minimumSeconds else { return nil }
        let firstRate = firstDrop / (firstSeconds / 3600)
        let secondRate = secondDrop / (secondSeconds / 3600)
        guard firstRate > 0, secondRate > 0 else { return nil }

        let ratio = secondRate / firstRate
        let time = InsightFormat.timeOfDay(midpoint, timeZone: context.timeZone)

        if ratio >= context.thresholds.trendRatio {
            let phrase = ratio >= 2 ? "more than doubled" : "climbed"
            return Insight(
                id: "drain-trend-up",
                severity: ratio >= 2 ? .warning : .notice,
                title: "Drain rate \(phrase) after \(time)",
                detail: "Before \(time) you averaged \(InsightFormat.rate(firstRate)); after it you "
                    + "averaged \(InsightFormat.rate(secondRate)). Something you started around then "
                    + "is costing you battery.",
                score: ratio * 10
            )
        }

        if ratio <= 1 / context.thresholds.trendRatio {
            return Insight(
                id: "drain-trend-down",
                severity: .info,
                title: "Drain rate settled down after \(time)",
                detail: "Before \(time) you averaged \(InsightFormat.rate(firstRate)); after it you "
                    + "averaged \(InsightFormat.rate(secondRate)).",
                score: 1 / max(ratio, 0.0001)
            )
        }

        return nil
    }

    /// Battery lost while the Mac was asleep — the drain nobody watches.
    static func sleepDrainRule(_ context: InsightContext) -> Insight? {
        let sleeping = context.series.gaps.filter { !$0.wasCharging }
        guard !sleeping.isEmpty else { return nil }
        let lost = sleeping.reduce(0) { $0 + $1.percentLost }
        guard lost >= context.thresholds.sleepDrainPercent else { return nil }

        let seconds = sleeping.reduce(0) { $0 + $1.durationSeconds }
        let hours = seconds / 3600
        let rate = hours > 0 ? lost / hours : 0
        let unhealthy = rate >= context.thresholds.unhealthySleepPctPerHour

        var detail = "Across \(sleeping.count) sleep period\(sleeping.count == 1 ? "" : "s") totalling "
            + "\(InsightFormat.duration(seconds: seconds)), the battery fell "
            + "\(InsightFormat.percent(lost))"
        if rate > 0 {
            detail += " (\(InsightFormat.rate(rate)))"
        }
        detail += "."
        if unhealthy {
            detail += " Sustained sleep drain above "
                + "\(InsightFormat.rate(context.thresholds.unhealthySleepPctPerHour)) usually means "
                + "something is waking your Mac — check Power Nap, Bluetooth wake, and Find My."
        }

        return Insight(
            id: "sleep-drain",
            severity: unhealthy ? .warning : .notice,
            title: "You lost \(InsightFormat.percent(lost)) while your Mac was asleep",
            detail: detail,
            score: lost
        )
    }

    /// Battery condition, when it is bad enough to matter.
    static func batteryHealthRule(_ context: InsightContext) -> Insight? {
        guard let health = context.health else { return nil }
        let worn = health.maxCapacityPct < context.thresholds.wornCapacityPct
        let manyCycles = health.cycleCount >= context.thresholds.highCycleCount
        guard worn || manyCycles else { return nil }

        var detail = "Maximum capacity is \(InsightFormat.percent(health.maxCapacityPct)) of design "
            + "capacity after \(InsightFormat.integer(health.cycleCount)) cycles."
        if worn {
            detail += " Apple considers a battery due for service below "
                + "\(InsightFormat.percent(context.thresholds.wornCapacityPct)) capacity."
        }
        if let runtime = health.fullChargeRuntimeHours {
            detail += " At your recent drain rate a full charge lasts about "
                + "\(InsightFormat.hoursMinutes(runtime))."
        }

        return Insight(
            id: "battery-health",
            severity: worn ? .warning : .info,
            title: worn
                ? "Battery health is down to \(InsightFormat.percent(health.maxCapacityPct))"
                : "Battery has \(InsightFormat.integer(health.cycleCount)) charge cycles",
            detail: detail,
            score: worn ? (100 - health.maxCapacityPct) : 1
        )
    }

    /// Directly answers "is it the browser or my terminal?" when both are in play.
    static func browserVersusTerminalRule(_ context: InsightContext) -> Insight? {
        let browser = context.categories.first { $0.category == .browser }
        let terminalish = context.categories.filter { $0.category == .terminal || $0.category == .devtools }
        guard let browser, browser.sharePct > 0, !terminalish.isEmpty else { return nil }
        let terminalShare = terminalish.reduce(0) { $0 + $1.sharePct }
        guard terminalShare > 0 else { return nil }

        let ratio = browser.sharePct / terminalShare
        guard ratio >= 1.5 || ratio <= 1 / 1.5 else { return nil }
        let browserWins = ratio >= 1.5

        let title = browserWins
            ? "Your browser is outweighing your terminal work"
            : "Your terminal work is outweighing your browser"
        let detail = "Browsers came to \(InsightFormat.percent(browser.sharePct)) of measured energy "
            + "use while terminals and developer tools came to "
            + "\(InsightFormat.percent(terminalShare)) in \(InsightFormat.windowLabel(context.window))."

        return Insight(
            id: "browser-vs-terminal",
            severity: .info,
            title: title,
            detail: detail,
            score: max(browser.sharePct, terminalShare)
        )
    }
}

extension String {
    /// Uppercases only the first character, leaving acronyms and the rest alone.
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
