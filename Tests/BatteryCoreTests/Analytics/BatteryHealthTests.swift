import XCTest
@testable import BatteryCore

/// Health readings and the runtime estimate derived from recent drain.
final class BatteryHealthTests: XCTestCase {

    func testHealthReadsTheLatestSampleAndEstimatesRuntime() throws {
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.run(
            from: Fixtures.anchor,
            hours: 2,
            startPercent: 80,
            pctPerHour: 10,
            cycleCount: 412,
            maxCapacityPct: 88
        ))
        let analytics = try temp.readOnlyAnalytics()
        let now = Fixtures.at(Fixtures.hours(2))
        let health = try XCTUnwrap(try analytics.batteryHealth(now: now))

        XCTAssertEqual(health.cycleCount, 412)
        XCTAssertEqual(health.maxCapacityPct, 88, accuracy: 0.001)
        XCTAssertEqual(health.percent, 60, accuracy: 0.001)
        XCTAssertEqual(health.sampledAt, now)
        XCTAssertFalse(health.isCharging)

        // 10%/hr means a full charge lasts ten hours, and 60% has six left.
        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(health.fullChargeRuntimeHours), 10, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(health.estimatedHoursRemaining), 6, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(health.medianWatts), 10, accuracy: 0.001)
    }

    func testRuntimeEstimateUsesTheMedianNotTheWorstSpike() throws {
        // Ninety minutes at 10%/hr, then a thirty-minute spike at 60%/hr.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 1.5, startPercent: 100, pctPerHour: 10)
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(1.5)),
            hours: 0.5,
            startPercent: 85,
            pctPerHour: 60,
            watts: 60,
            includeStart: false
        )
        let temp = try TempStore()
        try temp.seed(battery: samples)
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(2))))

        // The median of the quarter-hour buckets stays with the steady rate.
        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 10, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(health.fullChargeRuntimeHours), 10, accuracy: 0.5)
    }

    func testSlowDrainStillEstimatesRuntimeDespiteAZeroMedian() throws {
        // Real batteries report whole percentage points. At 2%/hr a quarter-hour
        // bucket drops 0.5%, which quantizes to no change at all in most buckets,
        // so the median rate is 0 even though the machine is plainly discharging.
        // The estimate has to fall back to the whole-window rate rather than
        // claiming it cannot measure the drain.
        var samples = Fixtures.run(
            from: Fixtures.anchor,
            hours: 6,
            startPercent: 90,
            pctPerHour: 0.8,
            watts: 8
        )
        samples = samples.map {
            BatterySample(
                timestampMs: $0.timestampMs,
                percent: $0.percent.rounded(),
                isCharging: $0.isCharging,
                externalPower: $0.externalPower,
                wattsDrawn: $0.wattsDrawn,
                voltageMv: $0.voltageMv,
                amperageMa: $0.amperageMa,
                cycleCount: $0.cycleCount,
                maxCapacityPct: $0.maxCapacityPct,
                temperatureC: $0.temperatureC
            )
        }
        let temp = try TempStore()
        try temp.seed(battery: samples)
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(6))))

        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 0, accuracy: 0.001)
        let remaining = try XCTUnwrap(health.estimatedHoursRemaining)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertTrue(remaining.isFinite)
        // ~85% left at roughly 0.8%/hr runs to a few days, not "unmeasurable".
        XCTAssertGreaterThan(remaining, 24)
    }

    func testHealthIsNilWhenNothingWasSampledInTheLookback() throws {
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.steadyDrain())
        let analytics = try temp.readOnlyAnalytics()

        // A day later, the six-hour lookback finds nothing.
        XCTAssertNil(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(26))))
    }

    func testRuntimeEstimateIsAbsentWhilePluggedIn() throws {
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.run(
            from: Fixtures.anchor,
            hours: 1,
            startPercent: 50,
            pctPerHour: -20,
            charging: true
        ))
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(1))))

        XCTAssertTrue(health.isCharging)
        XCTAssertTrue(health.externalPower)
        XCTAssertNil(health.medianPctPerHour)
        XCTAssertNil(health.fullChargeRuntimeHours)
        XCTAssertNil(health.estimatedHoursRemaining)
    }

    func testIdleOnBatteryDoesNotClaimInfiniteRuntime() throws {
        // Flat percent on battery: the measured rate is a real zero, but it is
        // no basis for a runtime estimate.
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.run(
            from: Fixtures.anchor,
            hours: 1,
            startPercent: 77,
            pctPerHour: 0
        ))
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(1))))

        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 0, accuracy: 0.001)
        XCTAssertNil(health.fullChargeRuntimeHours)
        XCTAssertNil(health.estimatedHoursRemaining)
    }
}
