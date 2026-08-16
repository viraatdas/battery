import BatteryCore
import XCTest
@testable import BatteryScopeApp

final class ChartDataTests: XCTestCase {

    private let anchor = Fixtures.anchor

    private func point(
        _ minutesFromAnchor: Double,
        percent: Double? = nil,
        pctPerHour: Double? = nil,
        watts: Double? = nil
    ) -> DrainPoint {
        let start = anchor.addingTimeInterval(minutesFromAnchor * 60)
        return DrainPoint(
            bucketStart: start,
            bucketEnd: start.addingTimeInterval(600),
            percent: percent,
            pctPerHour: pctPerHour,
            watts: watts
        )
    }

    private func series(_ points: [DrainPoint], gaps: [SleepGap] = []) -> DrainSeries {
        let window = TimeWindow(start: anchor, end: anchor.addingTimeInterval(3600))
        return DrainSeries(
            window: window,
            bucketSeconds: 600,
            points: points,
            gaps: gaps,
            sampleIntervalSeconds: 60,
            percentDrained: 0,
            dischargeWh: 0,
            dischargingSeconds: 0,
            chargingSeconds: 0,
            sleepSeconds: 0,
            overallPctPerHour: nil,
            overallWatts: nil,
            medianPctPerHour: nil,
            medianWatts: nil
        )
    }

    // MARK: - levelSegments

    func testLevelSegmentsSplitsAroundGaps() {
        // Three real readings, a hole, then two more: two runs, not one.
        let points = [
            point(0, percent: 90),
            point(10, percent: 89),
            point(20, percent: 88),
            point(30), // no percent: the hole
            point(40, percent: 85),
            point(50, percent: 84),
        ]
        let segments = ChartData.levelSegments(series(points))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.map(\.value), [90, 89, 88])
        XCTAssertEqual(segments[1].points.map(\.value), [85, 84])
    }

    func testLevelSegmentsPointIsBucketMidpoint() {
        let points = [point(0, percent: 50)]
        let segment = ChartData.levelSegments(series(points))[0]
        XCTAssertEqual(segment.points[0].date, anchor.addingTimeInterval(300))
    }

    func testLevelSegmentsAllGapsProducesNoSegments() {
        let points = [point(0), point(10), point(20)]
        XCTAssertTrue(ChartData.levelSegments(series(points)).isEmpty)
    }

    // MARK: - rateBars

    func testRateBarsOnlyIncludesPositiveMeasuredBuckets() {
        let points = [
            point(0, watts: 5),
            point(10, watts: nil),
            point(20, watts: 0),
            point(30, watts: -3), // abs() applied by the Metric, not rateBars
        ]
        let bars = ChartData.rateBars(series(points), metric: .watts)
        // watts: 0 is filtered out (`value > 0`), watts: -3 becomes abs 3 > 0.
        XCTAssertEqual(bars.map(\.value), [5, 3])
    }

    func testRateBarsSpanTheBucketWidth() {
        let p = point(0, watts: 5)
        let bar = ChartData.rateBars(series([p]), metric: .watts)[0]
        XCTAssertEqual(bar.start, p.bucketStart)
        XCTAssertEqual(bar.end, p.bucketEnd)
    }

    func testRateBarsUsesPercentPerHourForThatMetric() {
        let points = [point(0, pctPerHour: 4.5)]
        let bars = ChartData.rateBars(series(points), metric: .percentPerHour)
        XCTAssertEqual(bars.map(\.value), [4.5])
    }

    // MARK: - isPlottable

    func testIsPlottableFalseForEmptySeries() {
        XCTAssertFalse(ChartData.isPlottable(series([])))
    }

    func testIsPlottableFalseForSinglePointWithNoRateData() {
        // One level reading alone is not a line; a single point is not a chart.
        XCTAssertFalse(ChartData.isPlottable(series([point(0, percent: 50)])))
    }

    func testIsPlottableTrueForTwoLevelReadings() {
        XCTAssertTrue(ChartData.isPlottable(series([point(0, percent: 50), point(10, percent: 49)])))
    }

    func testIsPlottableTrueForAnyMeasuredRateEvenWithoutTwoLevelPoints() {
        XCTAssertTrue(ChartData.isPlottable(series([point(0, watts: 5)])))
    }
}
