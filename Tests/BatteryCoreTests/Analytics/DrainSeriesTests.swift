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

    func testFloorPreventsShortGapsAtFastCadenceFromBeingSleep() {
        // On a ~20s sampler, the relative factor alone (3x = 60s) would call
        // a 90s scheduling hiccup "sleep". The measured live database showed
        // dozens of these — an unprivileged sampler briefly descheduled, not
        // the Mac actually sleeping — which is exactly what
        // `minimumSleepGapSeconds` exists to floor out.
        let firstRunEnd = Fixtures.at(200)
        var samples = Fixtures.run(
            from: Fixtures.anchor, hours: 200.0 / 3600, startPercent: 80, pctPerHour: 9, intervalSeconds: 20
        )
        samples += Fixtures.run(
            from: firstRunEnd.addingTimeInterval(90),
            hours: 200.0 / 3600,
            startPercent: 79.5,
            pctPerHour: 9,
            intervalSeconds: 20
        )
        let window = TimeWindow(start: Fixtures.anchor, end: firstRunEnd.addingTimeInterval(500))
        let series = analyze(samples, window: window)

        XCTAssertTrue(series.gaps.isEmpty, "a 90s gap on a ~20s sampling cadence must not read as sleep")
        XCTAssertEqual(series.sleepSeconds, 0)
    }

    func testRelativeFactorStillWinsOverTheFloorOnASlowCadence() {
        // The floor is a minimum, not a replacement for the relative factor.
        // At a slow, 90s cadence the relative threshold (3x = 270s) is well
        // past the 120s floor, so a 200s gap — past the floor, short of the
        // relative threshold — must still read as awake, not sleep.
        let firstRunEnd = Fixtures.at(180)
        var samples = Fixtures.run(
            from: Fixtures.anchor, hours: 180.0 / 3600, startPercent: 80, pctPerHour: 5, intervalSeconds: 90
        )
        samples += Fixtures.run(
            from: firstRunEnd.addingTimeInterval(200),
            hours: 180.0 / 3600,
            startPercent: 79.75,
            pctPerHour: 5,
            intervalSeconds: 90
        )
        let window = TimeWindow(start: Fixtures.anchor, end: firstRunEnd.addingTimeInterval(600))
        let series = analyze(samples, window: window)

        XCTAssertTrue(series.gaps.isEmpty, "200s at a 90s cadence is under the 270s relative threshold")
    }

    func testAdjacentSleepGapsSeparatedByAShortAwakeBridgeAreCoalesced() throws {
        // A Mac that hiccups again right after waking from a real sleep
        // should read on screen as one sleep period, not two — "41 sleep
        // periods" in six hours is not a number anyone can act on.
        let sleepStart = Fixtures.at(Fixtures.hours(0.5))
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 0.5, startPercent: 80, pctPerHour: 10)

        // Sleep gap #1: 300s, well past the 180s threshold at this cadence.
        let bridgeStart = sleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: bridgeStart, percent: 79))
        // A short awake bridge: 50s, comfortably under the 300s coalesce window.
        let secondSleepStart = bridgeStart.addingTimeInterval(50)
        samples.append(Fixtures.batterySample(at: secondSleepStart, percent: 79))
        // Sleep gap #2, directly following the bridge.
        let afterSecondSleep = secondSleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: afterSecondSleep, percent: 77))
        samples += Fixtures.run(
            from: afterSecondSleep, hours: 0.5, startPercent: 77, pctPerHour: 10, includeStart: false
        )

        let window = TimeWindow(start: Fixtures.anchor, end: afterSecondSleep.addingTimeInterval(1800))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.gaps.count, 1, "two sleep gaps bridged by a short awake stretch should read as one episode")
        let gap = try XCTUnwrap(series.gaps.first)
        XCTAssertEqual(gap.start, sleepStart)
        XCTAssertEqual(gap.end, afterSecondSleep)
        // The bridge's 50s of awake time is folded into the merged episode.
        XCTAssertEqual(series.sleepSeconds, 650, accuracy: 1)
    }

    func testBridgeMadeOfSeveralShortSegmentsIsStillCoalesced() throws {
        // The awake bridge between two sleep gaps is rarely a single sample
        // pair on real hardware -- a sampler limping back to its normal
        // cadence for under a minute logs several short segments in a row,
        // not one. Coalescing has to look at the bridge's *total* duration
        // rather than bailing out the moment it sees more than one non-sleep
        // segment (a live 6h database still reported 20 "sleep periods"
        // instead of a handful until this was fixed).
        let sleepStart = Fixtures.at(Fixtures.hours(0.5))
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 0.5, startPercent: 80, pctPerHour: 10)

        let bridgeStart = sleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: bridgeStart, percent: 79))
        // Two more ~20s-cadence samples: two 20s segments, 40s of awake time
        // total, comfortably under the 300s coalesce window but more than
        // the single bridge segment the naive version of this could handle.
        samples.append(Fixtures.batterySample(at: bridgeStart.addingTimeInterval(20), percent: 79))
        samples.append(Fixtures.batterySample(at: bridgeStart.addingTimeInterval(40), percent: 79))
        let secondSleepStart = bridgeStart.addingTimeInterval(40)

        let afterSecondSleep = secondSleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: afterSecondSleep, percent: 77))
        samples += Fixtures.run(
            from: afterSecondSleep, hours: 0.5, startPercent: 77, pctPerHour: 10, includeStart: false
        )

        let window = TimeWindow(start: Fixtures.anchor, end: afterSecondSleep.addingTimeInterval(1800))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.gaps.count, 1, "a multi-segment awake bridge under the coalesce window should still merge")
        let gap = try XCTUnwrap(series.gaps.first)
        XCTAssertEqual(gap.start, sleepStart)
        XCTAssertEqual(gap.end, afterSecondSleep)
    }

    func testDistantSleepGapsAreNotCoalesced() throws {
        // Two real, separately-caused sleeps an hour apart must stay distinct
        // episodes — coalescing is for bridging noise, not merging everything.
        let firstSleepStart = Fixtures.at(Fixtures.hours(0.5))
        var samples = Fixtures.run(from: Fixtures.anchor, hours: 0.5, startPercent: 80, pctPerHour: 10)
        let afterFirstSleep = firstSleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: afterFirstSleep, percent: 79))
        samples += Fixtures.run(
            from: afterFirstSleep, hours: 1, startPercent: 79, pctPerHour: 10, includeStart: false
        )
        let secondSleepStart = afterFirstSleep.addingTimeInterval(3600)
        let afterSecondSleep = secondSleepStart.addingTimeInterval(300)
        samples.append(Fixtures.batterySample(at: afterSecondSleep, percent: 68))
        samples += Fixtures.run(
            from: afterSecondSleep, hours: 0.5, startPercent: 68, pctPerHour: 10, includeStart: false
        )

        let window = TimeWindow(start: Fixtures.anchor, end: afterSecondSleep.addingTimeInterval(1800))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.gaps.count, 2)
    }

    // MARK: - High-resolution charge (preciseCharge)

    /// One hour of samples, one per minute, with a fixed `percent` and a
    /// linearly draining raw mAh pair — the shape a real Apple Silicon
    /// battery reports: `CurrentCapacity`/`MaxCapacity` never move within an
    /// hour (they're quantized to a whole percent), while the underlying
    /// mAh counters do.
    private func flatPercentButDrainingMah(
        startMah: Double?,
        endMah: Double?,
        maxMah: Double?
    ) -> [BatterySample] {
        let steps = 60
        return (0...steps).map { step in
            let date = Fixtures.anchor.addingTimeInterval(Double(step) * 60)
            let fraction = Double(step) / Double(steps)
            let rawCurrent = startMah.map { $0 + ((endMah ?? $0) - $0) * fraction }
            return BatterySample(
                timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                percent: 52,
                isCharging: false,
                externalPower: false,
                wattsDrawn: -10,
                voltageMv: 12_600,
                amperageMa: -800,
                cycleCount: 312,
                maxCapacityPct: 92,
                temperatureC: 31.5,
                rawCurrentMah: rawCurrent,
                rawMaxMah: maxMah
            )
        }
    }

    func testFlatIntegerPercentWithoutAnyMahDataStillGetsANonZeroRateFromPower() throws {
        // No mAh data at all -- the historical-row case: every row in a
        // database is this shape until the sampler daemon restarts on a
        // build that captures raw capacity. This used to report a literal
        // zero median next to a real, nonzero measured wattage; that
        // self-contradiction is exactly what `standaloneFallbackDrop`'s
        // nominal-capacity fallback exists to eliminate, using
        // `AnalyticsOptions.nominalPackWattHours` since there is no
        // per-device capacity signal to prefer.
        let samples = flatPercentButDrainingMah(startMah: nil, endMah: nil, maxMah: nil)
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze(samples, window: window)

        // flatPercentButDrainingMah's fixed 10 W against the default 60 Wh
        // nominal pack: 10 / 60 * 100 = 16.667 %/hr, constant across every
        // interval since none of them have any capacity data to prefer.
        let expectedRate = 10.0 / Fixtures.options.nominalPackWattHours * 100
        XCTAssertEqual(try XCTUnwrap(series.medianPctPerHour), expectedRate, accuracy: 0.01)
        XCTAssertEqual(series.percentDrained, expectedRate, accuracy: 0.01)
    }

    func testFlatGaugeWithZeroMeasuredWattageStaysZeroNotFabricated() throws {
        // The genuine "no drain at all" path, which the power fallback must
        // never override: a flat gauge (real or quantized-to-flat) next to
        // *zero* measured wattage means nothing is actually being drawn, so
        // the rate is a real, honest zero -- not a fabricated nonzero one.
        // The fallback only ever fires when the wattage itself says real
        // power is flowing (`standaloneFallbackDrop`'s `watts > 0` guard);
        // this pins that it does not fire here. (These intervals still count as
        // discharging time -- unplugged, awake, just measuring no draw -- so
        // the rate is 0, not nil; `BatteryHealth` separately treats a literal
        // 0 rate as "not usable" so it can never produce an infinite
        // runtime — see `testZeroWattageWhileUnpluggedYieldsNoRuntimeEstimate`.)
        let samples = (0...30).map { step -> BatterySample in
            Fixtures.batterySample(at: Fixtures.at(Double(step) * 60), percent: 77, watts: 0)
        }
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze(samples, window: window)

        XCTAssertEqual(series.percentDrained, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.overallPctPerHour), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(series.medianPctPerHour), 0, accuracy: 0.001)
    }

    func testFlatIntegerPercentWithDrainingMahProducesNonZeroMedianRate() throws {
        // The actual bug: percent is flat at 52 for the whole hour (real
        // ioreg behavior), but the raw mAh pair drains from 4000 to 3200 out
        // of 8000 — a real 10%/hr rate that the integer percent alone hides.
        let samples = flatPercentButDrainingMah(startMah: 4000, endMah: 3200, maxMah: 8000)
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(Fixtures.hours(1)))
        let series = analyze(samples, window: window)

        // Every sample in this fixture reports the identical integer percent.
        XCTAssertEqual(Set(samples.map(\.percent)), [52])

        XCTAssertNotEqual(try XCTUnwrap(series.medianPctPerHour), 0)
        XCTAssertEqual(try XCTUnwrap(series.medianPctPerHour), 10, accuracy: 0.5)
        XCTAssertEqual(series.percentDrained, 10, accuracy: 0.5)
    }

    func testZeroGaugeDeltaWithNonzeroWattageFallsBackToPowerDerivedRate() throws {
        // Measured on real hardware: the raw mAh gauge (AppleRawCurrentCapacity)
        // refreshes in ~39 mAh steps roughly every 30-40s -- coarser than the
        // sampler's ~20s cadence -- so back-to-back samples routinely see a
        // zero gauge delta even while real, substantial power is drawn. The
        // integer percent is flat too, matching what real hardware reports.
        let rawMaxMah = 8029.0
        let voltageMv = 11_549
        let watts = 45.9
        func sample(at date: Date) -> BatterySample {
            BatterySample(
                timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                percent: 45,
                isCharging: false,
                externalPower: false,
                wattsDrawn: -watts,
                voltageMv: voltageMv,
                amperageMa: -4000,
                cycleCount: 100,
                maxCapacityPct: 95,
                rawCurrentMah: 3606, // gauge hasn't ticked between these samples
                rawMaxMah: rawMaxMah
            )
        }
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(60))
        let series = analyze([sample(at: Fixtures.anchor), sample(at: Fixtures.at(60))], window: window, bucket: .minute)

        // pack watt-hours from the raw capacity and voltage, turned into a
        // %/hr rate from the measured wattage -- ~49.5 %/hr here, matching
        // the live-hardware sanity check (45.9 W / 92.7 Wh = 49.5 %/hr).
        let packWh = rawMaxMah * Double(voltageMv) / 1_000_000
        let expectedPctPerHour = watts / packWh * 100

        XCTAssertEqual(try XCTUnwrap(series.overallPctPerHour), expectedPctPerHour, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series.medianPctPerHour), expectedPctPerHour, accuracy: 0.0001)
        // The self-contradiction this whole fix exists to prevent.
        XCTAssertNotEqual(series.medianPctPerHour, 0)
    }

    func testRealTickReconcilesPrecedingFlatIntervalsWithoutDoubleCounting() throws {
        // Three consecutive flat 20s gaps (gauge hasn't ticked) followed by
        // one real 1-point tick that explains the whole four-interval span
        // on its own. The fallback must not *also* credit the three flat
        // intervals with their own independent wattage estimate on top of
        // that real number.
        //
        // This pins a real regression measured against the live database:
        // 11 real percentage points over a 15-minute, ~20s-cadence window
        // were inflating to ~22.7% before this fix, because every flat
        // sample gap got its own fallback estimate *in addition to* the
        // real tick that eventually arrived to explain the whole run.
        let samples = (0...4).map { step in
            Fixtures.batterySample(at: Fixtures.at(Double(step) * 20), percent: step < 4 ? 50 : 49, watts: 40)
        }
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(100))
        let series = analyze(samples, window: window)

        // Identical wattage across all four intervals, so the one real
        // point splits evenly: 0.25 per interval, summing to exactly 1 --
        // not 1 plus three independent ~0.22-point fallback estimates.
        XCTAssertEqual(series.percentDrained, 1, accuracy: 0.001)
    }

    func testGaugeMovementWinsOverPowerFallbackWhenItMoved() throws {
        // The gauge itself moved (4000 -> 3900 mAh on an 8000 mAh pack): a
        // clean 1.25% drop. The measured wattage here would imply a very
        // different rate if the power fallback applied on top of a gauge
        // reading that already answered the question -- it must not.
        func sample(at date: Date, rawCurrentMah: Double) -> BatterySample {
            BatterySample(
                timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                percent: 50,
                isCharging: false,
                externalPower: false,
                wattsDrawn: -100,
                voltageMv: 12_000,
                amperageMa: -8_000,
                cycleCount: 100,
                maxCapacityPct: 95,
                rawCurrentMah: rawCurrentMah,
                rawMaxMah: 8_000
            )
        }
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(60))
        let series = analyze(
            [sample(at: Fixtures.anchor, rawCurrentMah: 4_000), sample(at: Fixtures.at(60), rawCurrentMah: 3_900)],
            window: window,
            bucket: .minute
        )

        XCTAssertEqual(series.percentDrained, 1.25, accuracy: 0.0005)
    }

    func testDriftingRawMaxCapacityDoesNotLeakIntoTheDrop() throws {
        // AppleRawMaxCapacity drifts on its own, independent of real drain
        // (measured 8029 -> 8027 within a single minute on real hardware).
        // Differencing two independently-drifting preciseCharge ratios would
        // leak that drift into the measured drop; a single stable
        // denominator (previous.rawMaxMah) must not.
        func sample(at date: Date, rawCurrentMah: Double, rawMaxMah: Double) -> BatterySample {
            BatterySample(
                timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                percent: 50,
                isCharging: false,
                externalPower: false,
                wattsDrawn: -10,
                voltageMv: 12_000,
                amperageMa: -800,
                cycleCount: 100,
                maxCapacityPct: 95,
                rawCurrentMah: rawCurrentMah,
                rawMaxMah: rawMaxMah
            )
        }
        let previous = sample(at: Fixtures.anchor, rawCurrentMah: 4_000, rawMaxMah: 8_000)
        // The denominator drifted (8000 -> 7990), not the drain itself.
        let current = sample(at: Fixtures.at(60), rawCurrentMah: 3_980, rawMaxMah: 7_990)
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(60))
        let series = analyze([previous, current], window: window, bucket: .minute)

        // Stable single denominator: (4000 - 3980) / 8000 * 100 = 0.25.
        // Naively differencing previous.preciseCharge (50.0) and
        // current.preciseCharge (~49.8123) would instead give ~0.1877 -- the
        // wrong number this test pins against.
        let naiveDifference = (4_000.0 / 8_000.0 * 100) - (3_980.0 / 7_990.0 * 100)
        XCTAssertEqual(series.percentDrained, 0.25, accuracy: 0.0005)
        XCTAssertGreaterThan(abs(series.percentDrained - naiveDifference), 0.01)
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

    func testRisingChargeWhileOnBatteryNeverProducesNegativeDrain() throws {
        // Sensor noise: the reported percent ticks up (70 -> 71) then back
        // down past its starting point (71 -> 70) while unplugged the whole
        // time. Net real change over the two intervals is exactly 1 point.
        let samples = [
            Fixtures.batterySample(at: Fixtures.anchor, percent: 70),
            Fixtures.batterySample(at: Fixtures.at(60), percent: 71),
            Fixtures.batterySample(at: Fixtures.at(120), percent: 70),
        ]
        let window = TimeWindow(start: Fixtures.anchor, end: Fixtures.at(300))
        let series = analyze(samples, window: window)

        // The rising interval's gauge delta clamps to zero (never negative)
        // rather than fabricating negative drain, so it is held pending
        // rather than credited with drop of its own. The second interval's
        // real, measured 1-point drop (71 -> 70) then closes out that
        // pending interval -- both intervals measured the identical 10 W, so
        // the real 1 point splits evenly between them, 0.5 each, and the
        // total is exactly the real net change: never negative, and never
        // inflated by stacking an independent wattage estimate for the
        // rising interval on top of the real number that already explains
        // it (see the `pendingFlat` comment in `classify(...)`).
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
