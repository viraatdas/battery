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

    func testRuntimeEstimateReflectsTheRecentRateNotAStaleWindowAverage() throws {
        // Ninety minutes at 10%/hr, then a thirty-minute spike at 60%/hr that
        // is still going as of `now`. "Time left" has to answer "at the rate
        // the machine is drawing right now" -- the batteryHealth() rate
        // basis is a short window anchored at the latest sample
        // (`AnalyticsOptions.recentRateLookbackSeconds`, 15 min by default),
        // so it lands inside the spike and reflects it, rather than blending
        // in the calmer 90 minutes beforehand the way a whole-window median
        // once did. Averaging across the full lookback is exactly the bug
        // that made a 45.9 W draw at 63% charge read as "10h 24m left" on
        // screen -- a stale rate from earlier in the window diluting a real,
        // current, higher one.
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

        // The last 15 minutes sit entirely inside the 60%/hr spike.
        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 60, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(health.fullChargeRuntimeHours), 100.0 / 60, accuracy: 0.05)
    }

    func testRuntimeEstimateWidensPastAQuietRecentWindowToFindRealDischarge() throws {
        // The last 15 minutes are plugged in -- nothing to measure a rate
        // from there -- but an hour of real discharging at 12%/hr precedes
        // it. The recent window must widen outward from the latest sample
        // until it actually finds discharging time, rather than reporting
        // no estimate just because the *very* last stretch was on AC.
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 1, startPercent: 90, pctPerHour: 12)
        samples += Fixtures.run(
            from: Fixtures.at(Fixtures.hours(1)),
            hours: 0.25,
            startPercent: 78,
            pctPerHour: 0,
            charging: true,
            includeStart: false
        )
        let temp = try TempStore()
        try temp.seed(battery: samples)
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(1.25))))

        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 12, accuracy: 1)
    }

    func testSlowDrainStillEstimatesRuntimeDespiteQuantizedPercent() throws {
        // Real batteries report whole percentage points. At 0.8%/hr a
        // quarter-hour bucket drops 0.2%, which quantizes to no change at
        // all in most buckets. Before the power fallback, that used to
        // report a literal zero median and force a fallback all the way out
        // to the whole-window rate; now real ticks (whenever the percent
        // does cross a whole point) reconcile the flat intervals around
        // them, and any trailing run that never gets a closing tick falls
        // back to its own measured wattage, so the median tracks the true
        // rate instead of reading zero.
        //
        // `watts` (0.48) is chosen to match 0.8%/hr against the default 60 Wh
        // nominal pack (`AnalyticsOptions.nominalPackWattHours`) specifically
        // so the small nominal-fallback estimates agree with the rare real
        // whole-point ticks instead of fighting them -- an arbitrary/
        // unrelated wattage would still yield a finite, positive, large
        // runtime, just not one that lines up with the intended 0.8%/hr.
        var samples = Fixtures.run(
            from: Fixtures.anchor,
            hours: 6,
            startPercent: 90,
            pctPerHour: 0.8,
            watts: 0.48
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

        // No longer a degenerate zero: the median now measures something.
        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), 0.8, accuracy: 0.3)
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

    func testZeroWattageWhileUnpluggedYieldsNoRuntimeEstimate() throws {
        // The genuine "no drain at all" path: unplugged, flat gauge, and
        // *zero* measured wattage -- nothing is actually being drawn. The
        // power fallback must never fire here (it is keyed on `watts > 0`),
        // so the measured rate is a real zero rather than a fabricated one.
        // `batteryHealth()` treats a literal zero rate as unusable so it can
        // never turn that into an infinite "full charge" claim (100 / 0).
        let temp = try TempStore()
        let samples = (0...30).map { step -> BatterySample in
            Fixtures.batterySample(at: Fixtures.at(Double(step) * 60), percent: 77, watts: 0)
        }
        try temp.seed(battery: samples)
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(1))))

        XCTAssertNil(health.medianPctPerHour)
        XCTAssertNil(health.fullChargeRuntimeHours)
        XCTAssertNil(health.estimatedHoursRemaining)
    }

    func testIdleOnBatteryStillEstimatesRuntimeFromMeasuredWattage() throws {
        // Flat integer percent on battery, with no raw mAh data, used to
        // report a literal zero median rate -- and therefore no runtime
        // estimate at all -- even though the machine was plainly drawing
        // real, measured power (Fixtures.run's default 10 W) the whole time.
        // `DrainAnalyzer.standaloneFallbackDrop`'s nominal-capacity fallback
        // now fills that in, so idle-but-discharging gets a sane (if
        // approximate, absent any real capacity signal) runtime instead of
        // nothing. See `AnalyticsOptions.nominalPackWattHours`.
        let temp = try TempStore()
        try temp.seed(battery: Fixtures.run(
            from: Fixtures.anchor,
            hours: 1,
            startPercent: 77,
            pctPerHour: 0
        ))
        let analytics = try temp.readOnlyAnalytics()
        let health = try XCTUnwrap(try analytics.batteryHealth(now: Fixtures.at(Fixtures.hours(1))))

        let expectedRate = 10.0 / analytics.options.nominalPackWattHours * 100
        XCTAssertEqual(try XCTUnwrap(health.medianPctPerHour), expectedRate, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(health.fullChargeRuntimeHours), 100 / expectedRate, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(health.estimatedHoursRemaining), 77 / expectedRate, accuracy: 0.01)
        // Never infinite or undefined: a zero rate next to real wattage is
        // exactly the self-contradiction the fallback exists to eliminate.
        XCTAssertTrue(try XCTUnwrap(health.estimatedHoursRemaining).isFinite)
    }
}
