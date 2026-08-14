import XCTest
@testable import BatteryCore

/// Drain-rate math: bucketing, charging exclusion, and sleep-gap handling.
final class DrainSeriesTests: XCTestCase {

    private func analyze(
        _ samples: [BatterySample],
        window: TimeWindow,
        bucket: Bucket = .hour,
        options: AnalyticsOptions = Fixtures.options
    ) -> DrainSeries {
        DrainAnalyzer.analyze(samples: samples, window: window, bucket: bucket, options: options)
    }

    // MARK: - Steady drain

    func testSteadyDrainProducesConstantRatePerBucket() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let series = analyze(Fixtures.steadyDrain(), window: window)

        XCTAssertEqual(series.points.count, 2)
        for point in series.points {
            XCTAssertEqual(try XCTUnwrap(point.pctPerHour), 10, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(point.watts), 10, accuracy: 0.001)
            XCTAssertEqual(point.dischargingSeconds, 3600, accuracy: 1)
            XCTAssertEqual(point.chargingSeconds, 0)
            XCTAssertEqual(point.sleepSeconds, 0)
        }
        XCTAssertEqual(series.percentDrained, 20, accuracy: 0.001)
        XCTAssertEqual(series.dischargeWh, 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.overallPctPerHour), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.medianPctPerHour), 10, accuracy: 0.001)
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertTrue(series.hasDischargeData)
    }

    func testSampleIntervalIsInferredFromTheMedianDelta() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let series = analyze(Fixtures.steadyDrain(intervalSeconds: 30), window: window)
        XCTAssertEqual(series.sampleIntervalSeconds, 30, accuracy: 0.001)
    }

    func testBucketPercentIsTheMeanOfItsSamples() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let series = analyze(Fixtures.steadyDrain(), window: window)

        // First hour runs 80% down to 70%, so its samples average about 75%.
        XCTAssertEqual(try XCTUnwrap(series.points[0].percent), 75, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(series.points[1].percent), 65, accuracy: 0.2)
    }

    func testFinerBucketsSplitTheSameTotals() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let coarse = analyze(Fixtures.steadyDrain(), window: window, bucket: .hour)
        let fine = analyze(Fixtures.steadyDrain(), window: window, bucket: .fifteenMinutes)

        XCTAssertEqual(fine.points.count, 8)
        XCTAssertEqual(fine.percentDrained, coarse.percentDrained, accuracy: 0.001)
        XCTAssertEqual(fine.dischargeWh, coarse.dischargeWh, accuracy: 0.001)
        XCTAssertEqual(
            fine.points.reduce(0) { $0 + $1.percentDrop },
            coarse.points.reduce(0) { $0 + $1.percentDrop },
            accuracy: 0.001
        )
    }

    // MARK: - Charging

    func testChargingTimeIsExcludedFromDrainMath() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(3)))
        let series = analyze(Fixtures.chargingInterlude(), window: window)

        // Two of the three hours ran on battery at 10%/hr.
        XCTAssertEqual(series.percentDrained, 20, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(series.overallPctPerHour), 10, accuracy: 0.2)
        XCTAssertEqual(series.chargingSeconds, 3600, accuracy: 120)
        XCTAssertEqual(series.dischargingSeconds, 7200, accuracy: 120)

        // The battery climbing while plugged in must never read as negative drain.
        XCTAssertGreaterThanOrEqual(series.percentDrained, 0)
        for point in series.points {
            XCTAssertGreaterThanOrEqual(point.percentDrop, 0)
        }
    }

    func testPluggedInWithoutChargingStillCountsAsAcPower() {
        // externalPower true, isCharging false: battery is not the source.
        let samples = (0...60).map { step in
            BatterySample(
                timestampMs: Int64((Fixtures.at(Double(step) * 60).timeIntervalSince1970 * 1000).rounded()),
                percent: 100,
                isCharging: false,
                externalPower: true,
                wattsDrawn: 0,
                voltageMv: 12_600,
                amperageMa: 0,
                cycleCount: 10,
                maxCapacityPct: 99,
                temperatureC: nil
            )
        }
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze(samples, window: window)

        XCTAssertFalse(series.hasDischargeData)
        XCTAssertEqual(series.chargingSeconds, 3600, accuracy: 1)
        XCTAssertNil(series.overallPctPerHour)
    }

    // MARK: - Sleep gaps

    func testSleepGapIsDetectedAndExcludedFromRates() throws {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(6)))
        let series = analyze(Fixtures.sleepGap(), window: window)

        XCTAssertEqual(series.gaps.count, 1)
        let gap = try XCTUnwrap(series.gaps.first)
        XCTAssertEqual(gap.start, Fixtures.at(Fixtures.hours(1)))
        XCTAssertEqual(gap.end, Fixtures.at(Fixtures.hours(5)))
        XCTAssertEqual(gap.percentLost, 4, accuracy: 0.001)
        XCTAssertEqual(gap.durationSeconds, Fixtures.hours(4), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(gap.pctPerHour), 1, accuracy: 0.001)
        XCTAssertFalse(gap.wasCharging)

        // The 4% lost while asleep is reported as a gap, never as awake drain.
        XCTAssertEqual(series.percentDrained, 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.overallPctPerHour), 10, accuracy: 0.001)
        XCTAssertEqual(series.sleepSeconds, Fixtures.hours(4), accuracy: 1)
        XCTAssertEqual(series.sleepPercentLost, 4, accuracy: 0.001)
    }

    func testSleepSecondsLandInTheBucketsTheGapCovers() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(6)))
        let series = analyze(Fixtures.sleepGap(), window: window)

        // Hours 1-5 are asleep; hours 0 and 5 are awake and discharging.
        XCTAssertEqual(series.points[0].sleepSeconds, 0, accuracy: 1)
        for index in 1...4 {
            XCTAssertEqual(series.points[index].sleepSeconds, 3600, accuracy: 1)
            XCTAssertNil(series.points[index].pctPerHour)
        }
        XCTAssertEqual(series.points[5].sleepSeconds, 0, accuracy: 1)
        XCTAssertNotNil(series.points[5].pctPerHour)
    }

    func testGapShorterThanThreeIntervalsIsNotSleep() {
        // 60s nominal interval, one 170s delta: under the 3x threshold.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 0.5, startPercent: 80, pctPerHour: 10)
        samples += Fixtures.run(
            from: Fixtures.at(1800 + 170),
            hours: 0.5,
            startPercent: 74.5,
            pctPerHour: 10
        )
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let series = analyze(samples, window: window)

        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertEqual(series.sleepSeconds, 0)
    }

    func testGapJustOverThreeIntervalsIsSleep() {
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 0.5, startPercent: 80, pctPerHour: 10)
        samples += Fixtures.run(
            from: Fixtures.at(1800 + 200),
            hours: 0.5,
            startPercent: 74.5,
            pctPerHour: 10
        )
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(2)))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(try XCTUnwrap(series.gaps.first).durationSeconds, 200, accuracy: 1)
    }

    func testGapWhilePluggedInIsMarkedAsCharging() {
        var samples = Fixtures.run(
            from: Fixtures.anchor,
            hours: 0.5,
            startPercent: 40,
            pctPerHour: -20,
            charging: true
        )
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(4)),
            hours: 0.5,
            startPercent: 100,
            pctPerHour: 0,
            charging: true
        )
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(5)))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertTrue(try XCTUnwrap(series.gaps.first).wasCharging)
        // Charging gaps must not be counted as battery lost to sleep.
        XCTAssertEqual(series.sleepPercentLost, 0, accuracy: 0.001)
    }

    // MARK: - Degenerate input

    func testEmptyWindowYieldsNoRatesButStillHasPoints() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze([], window: window)

        XCTAssertFalse(series.hasDischargeData)
        XCTAssertEqual(series.points.count, 1)
        XCTAssertNil(series.points[0].percent)
        XCTAssertNil(series.overallPctPerHour)
        XCTAssertEqual(series.sampleIntervalSeconds, 60, accuracy: 0.001)
        XCTAssertTrue(series.points[0].isEmpty)
    }

    func testSingleSampleProducesNoSegments() {
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze([Fixtures.batterySample(at: Fixtures.anchor, percent: 55)], window: window)

        XCTAssertFalse(series.hasDischargeData)
        XCTAssertEqual(try XCTUnwrap(series.points[0].percent), 55, accuracy: 0.001)
    }

    func testSamplesOutsideTheWindowAreIgnored() {
        let samples = Fixtures.steadyDrain()
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.percentDrained, 10, accuracy: 0.001)
        XCTAssertEqual(series.dischargingSeconds, 3600, accuracy: 1)
    }

    func testRisingChargeWhileOnBatteryNeverProducesNegativeDrain() {
        // Sensor noise: the reported percent ticks up while unplugged.
        let samples = [
            Fixtures.batterySample(at: Fixtures.anchor, percent: 70),
            Fixtures.batterySample(at: Fixtures.at(60), percent: 71),
            Fixtures.batterySample(at: Fixtures.at(120), percent: 70),
        ]
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(300))
        let series = analyze(samples, window: window)

        XCTAssertGreaterThanOrEqual(series.percentDrained, 0)
        XCTAssertEqual(series.percentDrained, 1, accuracy: 0.001)
    }

    // MARK: - Windows and buckets

    func testAutoBucketScalesWithTheWindow() {
        let end = Fixtures.anchor
        XCTAssertEqual(Bucket.auto(for: .lastHour(ending: end)).seconds, Bucket.minute.seconds)
        XCTAssertEqual(Bucket.auto(for: .last6Hours(ending: end)).seconds, Bucket.fifteenMinutes.seconds)
        XCTAssertEqual(Bucket.auto(for: .last24Hours(ending: end)).seconds, Bucket.halfHour.seconds)
        XCTAssertEqual(Bucket.auto(for: .last7Days(ending: end)).seconds, Bucket.sixHours.seconds)
    }

    func testTimeWindowHelpers() {
        let end = Fixtures.anchor
        XCTAssertEqual(TimeWindow.last24Hours(ending: end).hours, 24, accuracy: 0.001)
        XCTAssertEqual(TimeWindow.last7Days(ending: end).duration, 7 * 86400, accuracy: 0.001)
        XCTAssertEqual(TimeWindow.lastHours(4, ending: end).midpoint, end.addingTimeInterval(-Fixtures.hours(2)))
        // Reversed bounds are normalised rather than producing a negative window.
        XCTAssertEqual(TimeWindow(start: end, end: end.addingTimeInterval(-60)).duration, 60, accuracy: 0.001)
    }

    func testMedianHandlesEvenAndOddCounts() {
        XCTAssertNil(DrainAnalyzer.median([]))
        XCTAssertEqual(try XCTUnwrap(DrainAnalyzer.median([5])), 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(DrainAnalyzer.median([3, 1, 2])), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(DrainAnalyzer.median([4, 1, 3, 2])), 2.5, accuracy: 0.001)
    }
}
