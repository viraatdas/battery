import XCTest
@testable import BatteryCore

/// Helper-process merging and per-process / per-category attribution.
final class AttributionTests: XCTestCase {

    // MARK: - Name normalisation

    func testChromeHelpersMergeIntoChrome() {
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Google Chrome Helper (GPU)"), "Google Chrome")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Google Chrome Helper"), "Google Chrome")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Google Chrome"), "Google Chrome")
    }

    func testWebKitProcessesMergeIntoSafari() {
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "com.apple.WebKit.WebContent"), "Safari")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "com.apple.WebKit.Networking"), "Safari")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "com.apple.WebKit.GPU"), "Safari")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Safari Web Content"), "Safari")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Safari"), "Safari")
    }

    func testOtherHelperSuffixesAreStripped() {
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Slack Helper (Renderer)"), "Slack")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Code Helper (Plugin)"), "Code")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Arc Helper"), "Arc")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Notion Helper (GPU)"), "Notion")
    }

    func testNamesWithoutHelperSuffixesArePreserved() {
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "ghostty"), "ghostty")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "node"), "node")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "mds_stores"), "mds_stores")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "  WindowServer  "), "WindowServer")
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: ""), "")
    }

    func testRealParenthesesInAnAppNameSurvive() {
        // Only known helper role tags are stripped, not every trailing paren.
        XCTAssertEqual(AppNameNormalizer.canonicalName(for: "Xcode (Beta)"), "Xcode (Beta)")
    }

    // MARK: - Per-process rollup

    private func totals(_ entries: [(String, ProcessCategory, Double, Int)]) -> [ProcessTotals] {
        entries.map { name, category, energy, count in
            ProcessTotals(
                name: name,
                category: category,
                energyImpact: energy,
                peakEnergyImpact: energy / Double(count),
                cpuMsPerSSum: energy,
                sampleCount: count
            )
        }
    }

    func testHelperEnergyIsSummedIntoTheParentApp() throws {
        let usage = Attribution.processUsage(
            totals: totals([
                ("Google Chrome", .browser, 100, 10),
                ("Google Chrome Helper (Renderer)", .browser, 300, 10),
                ("Google Chrome Helper (GPU)", .browser, 100, 10),
                ("ghostty", .terminal, 500, 10),
            ]),
            dischargeWh: 20,
            percentDrained: 40
        )

        XCTAssertEqual(usage.count, 2)
        let chrome = try XCTUnwrap(usage.first { $0.name == "Google Chrome" })
        XCTAssertEqual(chrome.energyImpact, 500, accuracy: 0.001)
        XCTAssertEqual(chrome.sharePct, 50, accuracy: 0.001)
        XCTAssertEqual(chrome.sampleCount, 30)
        XCTAssertEqual(chrome.category, .browser)
        XCTAssertEqual(chrome.mergedProcessNames, [
            "Google Chrome", "Google Chrome Helper (GPU)", "Google Chrome Helper (Renderer)",
        ])
    }

    func testMeasuredDischargeIsApportionedByEnergyShare() throws {
        let usage = Attribution.processUsage(
            totals: totals([
                ("Google Chrome", .browser, 750, 10),
                ("ghostty", .terminal, 250, 10),
            ]),
            dischargeWh: 20,
            percentDrained: 40
        )

        let chrome = try XCTUnwrap(usage.first)
        XCTAssertEqual(chrome.sharePct, 75, accuracy: 0.001)
        XCTAssertEqual(chrome.estimatedWh, 15, accuracy: 0.001)
        XCTAssertEqual(chrome.estimatedPercentPoints, 30, accuracy: 0.001)

        // The estimates reconcile with what the battery actually lost.
        XCTAssertEqual(usage.reduce(0) { $0 + $1.estimatedWh }, 20, accuracy: 0.001)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.estimatedPercentPoints }, 40, accuracy: 0.001)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.sharePct }, 100, accuracy: 0.001)
    }

    func testZeroEnergyProducesZeroSharesRatherThanNaN() {
        let usage = Attribution.processUsage(
            totals: totals([("ghostty", .terminal, 0, 5)]),
            dischargeWh: 0,
            percentDrained: 0
        )
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].sharePct, 0)
        XCTAssertEqual(usage[0].estimatedWh, 0)
        XCTAssertFalse(usage[0].estimatedWh.isNaN)
    }

    func testMergedRowTakesTheCategoryOfItsHeaviestProcesses() throws {
        // The stray `.other` row must not outvote the browser-classified bulk.
        let usage = Attribution.processUsage(
            totals: totals([
                ("Google Chrome", .browser, 400, 10),
                ("Google Chrome Helper (Renderer)", .other, 100, 10),
            ]),
            dischargeWh: 10,
            percentDrained: 10
        )
        XCTAssertEqual(try XCTUnwrap(usage.first).category, .browser)
    }

    func testUsageIsSortedByEnergyDescending() {
        let usage = Attribution.processUsage(
            totals: totals([
                ("ghostty", .terminal, 100, 5),
                ("Google Chrome", .browser, 300, 5),
                ("node", .devtools, 200, 5),
            ]),
            dischargeWh: 5,
            percentDrained: 5
        )
        XCTAssertEqual(usage.map(\.name), ["Google Chrome", "node", "ghostty"])
    }

    // MARK: - Category rollup

    func testCategoryRollupSumsSharesAndKeepsTopThree() throws {
        let usage = Attribution.processUsage(
            totals: totals([
                ("Google Chrome", .browser, 300, 5),
                ("Safari", .browser, 200, 5),
                ("Firefox", .browser, 100, 5),
                ("Arc", .browser, 50, 5),
                ("ghostty", .terminal, 250, 5),
                ("mds_stores", .background, 100, 5),
            ]),
            dischargeWh: 10,
            percentDrained: 20
        )
        let categories = Attribution.categoryUsage(processes: usage)

        let browser = try XCTUnwrap(categories.first { $0.category == .browser })
        XCTAssertEqual(browser.energyImpact, 650, accuracy: 0.001)
        XCTAssertEqual(browser.topProcesses.count, 3)
        XCTAssertEqual(browser.topProcesses.map(\.name), ["Google Chrome", "Safari", "Firefox"])

        // Category shares partition the window with nothing lost or double-counted.
        XCTAssertEqual(categories.reduce(0) { $0 + $1.sharePct }, 100, accuracy: 0.001)
        XCTAssertEqual(categories.reduce(0) { $0 + $1.estimatedWh }, 10, accuracy: 0.001)
        XCTAssertEqual(categories.map(\.category), [.browser, .terminal, .background])
    }

    // MARK: - Store-backed, end to end

    func testTopProcessesOverASeededStore() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.steadyDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.browserHeavy,
                from: Fixtures.anchor,
                hours: 2
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let processes = try analytics.topProcesses(window: window, limit: 5)

        XCTAssertEqual(processes.count, 5)
        let chrome = try XCTUnwrap(processes.first)
        XCTAssertEqual(chrome.name, "Google Chrome")
        XCTAssertEqual(chrome.category, .browser)
        // 60 of the 100 energy-impact points in the mix are Chrome's.
        XCTAssertEqual(chrome.sharePct, 60, accuracy: 0.001)
        XCTAssertEqual(chrome.estimatedWh, 12, accuracy: 0.01)
        XCTAssertEqual(chrome.estimatedPercentPoints, 12, accuracy: 0.01)
        XCTAssertEqual(chrome.mergedProcessNames.count, 3)
    }

    func testLimitIsRespectedAndNilReturnsEverything() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.steadyDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.browserHeavy,
                from: Fixtures.anchor,
                hours: 2
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))

        XCTAssertEqual(try analytics.topProcesses(window: window, limit: 2).count, 2)
        // Nine raw processes, but Chrome's three rows merge into one.
        XCTAssertEqual(try analytics.topProcesses(window: window, limit: nil).count, 7)
    }

    func testCategoryBreakdownSeparatesBrowserFromTerminalWork() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.steadyDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.browserHeavy,
                from: Fixtures.anchor,
                hours: 2
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let categories = try analytics.categoryBreakdown(window: window)

        let browser = try XCTUnwrap(categories.first { $0.category == .browser })
        let terminal = try XCTUnwrap(categories.first { $0.category == .terminal })
        let background = try XCTUnwrap(categories.first { $0.category == .background })
        let system = try XCTUnwrap(categories.first { $0.category == .system })

        XCTAssertEqual(browser.sharePct, 60, accuracy: 0.001) // Chrome plus both helpers
        XCTAssertEqual(terminal.sharePct, 8, accuracy: 0.001)
        XCTAssertEqual(background.sharePct, 5, accuracy: 0.001) // nsurlsessiond
        XCTAssertEqual(system.sharePct, 15, accuracy: 0.001) // WindowServer plus mds_stores
        XCTAssertEqual(browser.topProcesses.map(\.name), ["Google Chrome"])
        XCTAssertGreaterThan(browser.sharePct, terminal.sharePct)
        XCTAssertEqual(categories.reduce(0) { $0 + $1.sharePct }, 100, accuracy: 0.001)
    }

    func testTerminalHeavyMixInvertsTheRanking() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: Fixtures.steadyDrain(),
            processes: Fixtures.processSamples(
                specs: Fixtures.terminalHeavy,
                from: Fixtures.anchor,
                hours: 2
            )
        )
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let categories = try analytics.categoryBreakdown(window: window)

        let browser = try XCTUnwrap(categories.first { $0.category == .browser })
        let terminal = try XCTUnwrap(categories.first { $0.category == .terminal })
        let devtools = try XCTUnwrap(categories.first { $0.category == .devtools })

        XCTAssertGreaterThan(terminal.sharePct + devtools.sharePct, browser.sharePct)
        XCTAssertEqual(browser.sharePct, 100.0 * 10 / 75, accuracy: 0.001)
    }

    func testProcessTotalsCollapseSamplesBeforeAttribution() throws {
        let temp = try TempStore()
        try temp.seed(
            battery: [],
            processes: Fixtures.processSamples(
                specs: [Fixtures.ProcessSpec("ghostty", energyImpact: 3)],
                from: Fixtures.anchor,
                hours: 1
            )
        )
        // 61 ticks of one process collapse to a single row.
        let rows = try temp.store.processTotals(
            from: Fixtures.anchor,
            to: Fixtures.at(Fixtures.hours(1))
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sampleCount, 61)
        XCTAssertEqual(rows[0].energyImpact, 183, accuracy: 0.001)
        XCTAssertEqual(rows[0].peakEnergyImpact, 3, accuracy: 0.001)
    }

    func testWindowsWithNoProcessSamplesReturnNothing() throws {
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.steadyDrain())
        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))

        XCTAssertTrue(try analytics.topProcesses(window: window).isEmpty)
        XCTAssertTrue(try analytics.categoryBreakdown(window: window).isEmpty)
    }
}
