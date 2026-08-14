import XCTest
@testable import BatteryCore

/// The insight rules. Each rule is exercised on a scenario built to trigger it
/// and on one built to keep it quiet, so a rule cannot pass by always firing.
final class InsightTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - Context building

    private func totals(_ specs: [Fixtures.ProcessSpec]) -> [ProcessTotals] {
        specs.map { spec in
            ProcessTotals(
                name: spec.name,
                category: Categorizer.categorize(name: spec.name, bundlePathHint: spec.bundlePathHint),
                energyImpact: spec.energyImpact,
                peakEnergyImpact: spec.energyImpact,
                cpuMsPerSSum: spec.cpuMsPerS,
                sampleCount: 1
            )
        }
    }

    private func context(
        samples: [BatterySample],
        specs: [Fixtures.ProcessSpec] = [],
        window: TimeWindow,
        health: BatteryHealth? = nil,
        thresholds: InsightThresholds = InsightThresholds()
    ) -> InsightContext {
        let series = DrainAnalyzer.analyze(
            samples: samples,
            window: window,
            bucket: Bucket.auto(for: window),
            options: Fixtures.options
        )
        let processes = Attribution.processUsage(
            totals: totals(specs),
            dischargeWh: series.dischargeWh,
            percentDrained: series.percentDrained
        )
        return InsightContext(
            window: window,
            series: series,
            processes: processes,
            categories: Attribution.categoryUsage(processes: processes),
            health: health,
            timeZone: utc,
            thresholds: thresholds
        )
    }

    private func insight(_ id: String, in insights: [Insight]) -> Insight? {
        insights.first { $0.id == id }
    }

    private var twoHourWindow: TimeWindow {
        TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
    }

    // MARK: - Rule 1: top process

    func testTopProcessRuleNamesTheBiggestApp() throws {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: Fixtures.browserHeavy,
            window: twoHourWindow
        ))
        let top = try XCTUnwrap(insight("top-process", in: insights))

        XCTAssertEqual(top.title, "Google Chrome is your biggest battery user")
        XCTAssertTrue(top.detail.contains("60%"), top.detail)
        // 60% of 20 Wh discharged, and 60% of the 20 points lost.
        XCTAssertTrue(top.detail.contains("12.0 Wh"), top.detail)
        XCTAssertTrue(top.detail.contains("12%"), top.detail)
        XCTAssertEqual(top.severity, .warning)
    }

    func testTopProcessRuleStaysQuietWhenNothingStandsOut() {
        let evenSplit = (1...10).map { Fixtures.ProcessSpec("app-\($0)", energyImpact: 10) }
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: evenSplit,
            window: twoHourWindow
        ))
        XCTAssertNil(insight("top-process", in: insights))
    }

    // MARK: - Rule 2: heavy categories

    func testBackgroundProcessesAreCalledOut() throws {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: Fixtures.backgroundHeavy,
            window: twoHourWindow
        ))
        let background = try XCTUnwrap(insight("category-share:background", in: insights))

        XCTAssertEqual(background.title, "Background processes are a large share of your drain")
        XCTAssertTrue(background.detail.contains("79%"), background.detail)
        XCTAssertTrue(background.detail.contains("nsurlsessiond"), background.detail)
        XCTAssertEqual(background.severity, .warning)
    }

    func testCategoryRuleSkipsSmallCategories() {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: Fixtures.browserHeavy,
            window: twoHourWindow
        ))
        // Terminal is 8% of this mix, well under the 20% cutoff.
        XCTAssertNil(insight("category-share:terminal", in: insights))
        XCTAssertNotNil(insight("category-share:browser", in: insights))
    }

    // MARK: - Rule 3: trend

    func testDrainRateDoublingIsReportedWithTheTimeOfDay() throws {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let insights = InsightEngine.insights(context(
            samples: Fixtures.doublingDrain(),
            specs: Fixtures.browserHeavy,
            window: window
        ))
        let trend = try XCTUnwrap(insight("drain-trend-up", in: insights))

        XCTAssertEqual(trend.title, "Drain rate more than doubled after 2 PM")
        XCTAssertTrue(trend.detail.contains("5.0%/hr"), trend.detail)
        XCTAssertTrue(trend.detail.contains("15.0%/hr"), trend.detail)
        XCTAssertEqual(trend.severity, .warning)
    }

    func testImprovingDrainRateIsReportedAsInfo() throws {
        // The mirror image: heavy first, light second.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 4, startPercent: 100, pctPerHour: 15)
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(4)),
            hours: 4,
            startPercent: 40,
            pctPerHour: 5,
            includeStart: false
        )
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let trend = try XCTUnwrap(insight(
            "drain-trend-down",
            in: InsightEngine.insights(context(samples: samples, window: window))
        ))

        XCTAssertEqual(trend.title, "Drain rate settled down after 2 PM")
        XCTAssertEqual(trend.severity, .info)
    }

    func testSteadyDrainProducesNoTrendInsight() {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            window: twoHourWindow
        ))
        XCTAssertNil(insight("drain-trend-up", in: insights))
        XCTAssertNil(insight("drain-trend-down", in: insights))
    }

    // MARK: - Rule 4: sleep drain

    func testSleepDrainIsReportedSeparatelyFromAwakeDrain() throws {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(6)))
        let insights = InsightEngine.insights(context(samples: Fixtures.sleepGap(), window: window))
        let sleep = try XCTUnwrap(insight("sleep-drain", in: insights))

        XCTAssertEqual(sleep.title, "You lost 4.0% while your Mac was asleep")
        XCTAssertTrue(sleep.detail.contains("1 sleep period"), sleep.detail)
        XCTAssertTrue(sleep.detail.contains("4h"), sleep.detail)
        XCTAssertTrue(sleep.detail.contains("1.0%/hr"), sleep.detail)
        // 1%/hr asleep is high enough to suggest something is waking the Mac.
        XCTAssertEqual(sleep.severity, .warning)
        XCTAssertTrue(sleep.detail.contains("Power Nap"), sleep.detail)
    }

    func testHealthySleepDrainIsOnlyANotice() throws {
        // Four hours asleep losing 1.2%: real, but not alarming.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 1, startPercent: 80, pctPerHour: 10)
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(5)),
            hours: 1,
            startPercent: 68.8,
            pctPerHour: 10
        )
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(6)))
        let sleep = try XCTUnwrap(insight(
            "sleep-drain",
            in: InsightEngine.insights(context(samples: samples, window: window))
        ))

        XCTAssertEqual(sleep.severity, .notice)
        XCTAssertFalse(sleep.detail.contains("Power Nap"), sleep.detail)
    }

    func testNoSleepInsightWithoutAGap() {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            window: twoHourWindow
        ))
        XCTAssertNil(insight("sleep-drain", in: insights))
    }

    // MARK: - Rule 5: absolute drain rate

    func testHighDrainRateIsTranslatedIntoRuntime() throws {
        let samples = Fixtures.run(
            from: Fixtures.anchor,
            hours: 2,
            startPercent: 90,
            pctPerHour: 30,
            watts: 25
        )
        let high = try XCTUnwrap(insight(
            "high-drain-rate",
            in: InsightEngine.insights(context(samples: samples, window: twoHourWindow))
        ))

        XCTAssertEqual(high.title, "High drain rate: 30.0%/hr")
        XCTAssertTrue(high.detail.contains("25.0 W"), high.detail)
        // 100 / 30 = 3.33 hours on a full charge.
        XCTAssertTrue(high.detail.contains("3h 20m"), high.detail)
        XCTAssertEqual(high.severity, .warning)
    }

    func testModerateDrainRateDoesNotFire() {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            window: twoHourWindow
        ))
        XCTAssertNil(insight("high-drain-rate", in: insights))
    }

    // MARK: - Rule 6: battery health

    func testWornBatteryIsFlagged() throws {
        let health = BatteryHealth(
            cycleCount: 1_024,
            maxCapacityPct: 72,
            percent: 55,
            isCharging: false,
            externalPower: false,
            sampledAt: Fixtures.at(Fixtures.hours(2)),
            medianPctPerHour: 10,
            medianWatts: 10,
            fullChargeRuntimeHours: 10,
            estimatedHoursRemaining: 5.5,
            measuredOver: twoHourWindow
        )
        let flagged = try XCTUnwrap(insight(
            "battery-health",
            in: InsightEngine.insights(context(
                samples: Fixtures.steadyDrain(),
                window: twoHourWindow,
                health: health
            ))
        ))

        XCTAssertEqual(flagged.title, "Battery health is down to 72%")
        XCTAssertTrue(flagged.detail.contains("1,024 cycles"), flagged.detail)
        XCTAssertTrue(flagged.detail.contains("10h"), flagged.detail)
        XCTAssertEqual(flagged.severity, .warning)
    }

    func testHealthyBatteryIsNotFlagged() {
        let health = BatteryHealth(
            cycleCount: 120,
            maxCapacityPct: 97,
            percent: 80,
            isCharging: false,
            externalPower: false,
            sampledAt: Fixtures.at(Fixtures.hours(2)),
            medianPctPerHour: 10,
            medianWatts: 10,
            fullChargeRuntimeHours: 10,
            estimatedHoursRemaining: 8,
            measuredOver: twoHourWindow
        )
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            window: twoHourWindow,
            health: health
        ))
        XCTAssertNil(insight("battery-health", in: insights))
    }

    // MARK: - Rule 7: browser versus terminal

    func testBrowserVersusTerminalAnswersTheQuestionDirectly() throws {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: Fixtures.browserHeavy,
            window: twoHourWindow
        ))
        let comparison = try XCTUnwrap(insight("browser-vs-terminal", in: insights))

        XCTAssertEqual(comparison.title, "Your browser is outweighing your terminal work")
        XCTAssertTrue(comparison.detail.contains("60%"), comparison.detail)
    }

    func testTerminalHeavyMixFlipsTheComparison() throws {
        let insights = InsightEngine.insights(context(
            samples: Fixtures.steadyDrain(),
            specs: Fixtures.terminalHeavy,
            window: twoHourWindow
        ))
        let comparison = try XCTUnwrap(insight("browser-vs-terminal", in: insights))
        XCTAssertEqual(comparison.title, "Your terminal work is outweighing your browser")
    }

    // MARK: - Rules 8 and 9: thin or absent data

    func testNoDischargeDataProducesAnExplanation() throws {
        let samples = Fixtures.run(
            from: Fixtures.anchor,
            hours: 2,
            startPercent: 50,
            pctPerHour: -10,
            charging: true
        )
        let insights = InsightEngine.insights(context(
            samples: samples,
            specs: Fixtures.browserHeavy,
            window: twoHourWindow
        ))
        let none = try XCTUnwrap(insight("no-discharge-data", in: insights))

        XCTAssertEqual(none.title, "No battery drain measured in the last 2h")
        XCTAssertTrue(none.detail.contains("plugged in"), none.detail)
        // Without measured drain there is nothing to rank apps against.
        XCTAssertNil(insight("high-drain-rate", in: insights))
    }

    func testMostlyPluggedInWarnsThatAttributionIsThin() throws {
        // Ten minutes unplugged inside a two-hour window. The interval spanning
        // the unplug counts as AC time, so nine minutes are measurable.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 1, startPercent: 60, pctPerHour: 0, charging: true)
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(1)),
            hours: 1 / 6,
            startPercent: 60,
            pctPerHour: 10,
            includeStart: false
        )
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(1) + 600),
            hours: 50.0 / 60,
            startPercent: 58,
            pctPerHour: 0,
            charging: true,
            includeStart: false
        )
        let insights = InsightEngine.insights(context(samples: samples, window: twoHourWindow))
        let thin = try XCTUnwrap(insight("mostly-plugged-in", in: insights))

        XCTAssertEqual(thin.title, "You were mostly on AC power")
        XCTAssertTrue(thin.detail.contains("9m"), thin.detail)
    }

    // MARK: - Ranking

    func testInsightsAreRankedBySeverityThenScore() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let insights = InsightEngine.insights(context(
            samples: Fixtures.doublingDrain(),
            specs: Fixtures.browserHeavy,
            window: window
        ))

        XCTAssertGreaterThan(insights.count, 3)
        for index in 1..<insights.count {
            let previous = insights[index - 1]
            let current = insights[index]
            XCTAssertGreaterThanOrEqual(previous.severity, current.severity)
            if previous.severity == current.severity {
                XCTAssertGreaterThanOrEqual(previous.score, current.score)
            }
        }
        XCTAssertEqual(Set(insights.map(\.id)).count, insights.count, "insight ids must be unique")
    }

    func testEveryInsightHasReadableText() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let insights = InsightEngine.insights(context(
            samples: Fixtures.doublingDrain(),
            specs: Fixtures.backgroundHeavy,
            window: window
        ))

        for found in insights {
            XCTAssertFalse(found.title.isEmpty)
            XCTAssertFalse(found.detail.isEmpty)
            XCTAssertTrue(found.detail.hasSuffix("."), "detail should be a sentence: \(found.detail)")
            XCTAssertFalse(found.title.contains("nan"), found.title)
            XCTAssertFalse(found.detail.contains("nan"), found.detail)
        }
    }

    // MARK: - Formatting

    func testDurationFormatting() {
        XCTAssertEqual(InsightFormat.hoursMinutes(0), "0m")
        XCTAssertEqual(InsightFormat.hoursMinutes(0.5), "30m")
        XCTAssertEqual(InsightFormat.hoursMinutes(1), "1h")
        XCTAssertEqual(InsightFormat.hoursMinutes(100.0 / 30), "3h 20m")
    }

    func testNumberFormattingIsLocaleIndependent() {
        XCTAssertEqual(InsightFormat.integer(1_024), "1,024")
        XCTAssertEqual(InsightFormat.integer(999), "999")
        XCTAssertEqual(InsightFormat.integer(1_234_567), "1,234,567")
        XCTAssertEqual(InsightFormat.percent(60), "60%")
        XCTAssertEqual(InsightFormat.percent(4.25), "4.2%")
        XCTAssertEqual(InsightFormat.rate(10), "10.0%/hr")
        XCTAssertEqual(InsightFormat.wattHours(0.5), "0.50 Wh")
        XCTAssertEqual(InsightFormat.wattHours(12), "12.0 Wh")
    }

    func testTimeOfDayUsesTheConfiguredTimeZone() {
        XCTAssertEqual(InsightFormat.timeOfDay(Fixtures.at(Fixtures.hours(4)), timeZone: utc), "2 PM")
        XCTAssertEqual(InsightFormat.timeOfDay(Fixtures.at(Fixtures.hours(4) + 1800), timeZone: utc), "2:30 PM")
        XCTAssertEqual(
            InsightFormat.timeOfDay(Fixtures.at(Fixtures.hours(4)), timeZone: TimeZone(identifier: "America/Los_Angeles")!),
            "6 AM"
        )
    }

    func testListFormatting() {
        XCTAssertEqual(InsightFormat.list([]), "")
        XCTAssertEqual(InsightFormat.list(["a"]), "a")
        XCTAssertEqual(InsightFormat.list(["a", "b"]), "a and b")
        XCTAssertEqual(InsightFormat.list(["a", "b", "c"]), "a, b and c")
    }

    func testWindowLabels() {
        let end = Fixtures.anchor
        XCTAssertEqual(InsightFormat.windowLabel(.lastHours(3, ending: end)), "the last 3h")
        XCTAssertEqual(InsightFormat.windowLabel(.last24Hours(ending: end)), "the last 1d")
        XCTAssertEqual(InsightFormat.windowLabel(.last7Days(ending: end)), "the last 7d")
        XCTAssertEqual(InsightFormat.windowLabel(.lastHours(0.75, ending: end)), "the last 45m")
    }

    // MARK: - End to end through the store

    func testInsightsFromASeededStore() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.doublingDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.browserHeavy,
                from: Fixtures.anchor,
                hours: 8
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let insights = try analytics.insights(window: window)
        let ids = Set(insights.map(\.id))

        XCTAssertTrue(ids.contains("top-process"), "\(ids)")
        XCTAssertTrue(ids.contains("drain-trend-up"), "\(ids)")
        XCTAssertTrue(ids.contains("category-share:browser"), "\(ids)")
        XCTAssertEqual(insights.first?.severity, .warning)
    }

    func testReportComputesEveryViewInOnePass() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.doublingDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.browserHeavy,
                from: Fixtures.anchor,
                hours: 8
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(8)))
        let report = try analytics.report(window: window, processLimit: 3)

        XCTAssertEqual(report.processes.count, 3)
        XCTAssertEqual(report.processes.first?.name, "Google Chrome")
        XCTAssertFalse(report.categories.isEmpty)
        XCTAssertFalse(report.insights.isEmpty)
        XCTAssertNotNil(report.health)
        XCTAssertEqual(
            report.series.percentDrained,
            try analytics.drainSeries(window: window).percentDrained,
            accuracy: 0.001
        )
    }
}
