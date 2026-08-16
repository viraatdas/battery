import XCTest
@testable import BatteryCore

/// A full-size window: seven days of samples, the shape the daemon actually
/// produces. Guards against an accidental quadratic in the rollup path.
final class AnalyticsScaleTests: XCTestCase {

    func testSevenDayWindowStaysFastAndCorrect() throws {
        let temp = try TempStore()
        let days = 7.0

        // A battery sample a minute, and ten processes sampled every five
        // minutes: ~10k battery rows and ~20k process rows.
        let battery = Fixtures.run(
            from: Fixtures.anchor,
            hours: days * 24,
            startPercent: 100,
            pctPerHour: 100 / (days * 24)
        )
        let specs = (1...10).map { index in
            Fixtures.ProcessSpec(index == 1 ? "Google Chrome" : "worker-\(index)", energyImpact: Double(index))
        }
        let processes = Fixtures.processSamples(
            specs: specs,
            from: Fixtures.anchor,
            hours: days * 24,
            intervalSeconds: 300
        )
        XCTAssertGreaterThan(battery.count, 10_000)
        XCTAssertGreaterThan(processes.count, 20_000)
        try temp.seed(battery: battery, processes: processes)

        let analytics = try temp.readOnlyAnalytics()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(days * 24)))

        let started = Date()
        let report = try analytics.report(window: window)
        let elapsed = Date().timeIntervalSince(started)

        // Measured ~25-26ms on this machine as of this comment (~10k battery
        // rows, ~20k process rows). 0.5s leaves ~20x headroom for a slower CI
        // box while still catching a real regression back toward multi-second
        // territory -- the old 5s ceiling had ~200x headroom, which is why it
        // stayed green through a real order-of-magnitude slowdown.
        XCTAssertLessThan(elapsed, 0.5, "seven-day report took \(elapsed)s")
        // Auto-bucketed to six hours. Buckets are epoch-aligned, so a window
        // starting at 10:00 opens inside the 06:00 bucket and needs 29 of them
        // to cover seven days.
        XCTAssertEqual(report.series.points.count, 29)
        XCTAssertEqual(report.series.percentDrained, 100, accuracy: 0.1)
        XCTAssertEqual(report.processes.count, 10)
        XCTAssertEqual(report.processes.first?.name, "worker-10")
        XCTAssertEqual(
            report.processes.reduce(0) { $0 + $1.sharePct },
            100,
            accuracy: 0.001
        )
    }
}
