import Foundation

/// Turns raw battery samples into a bucketed drain series.
///
/// The whole analyzer is pure: same samples in, same series out. It never reads
/// the clock, so scenarios can be replayed exactly in tests.
///
/// Drain is measured between *consecutive* samples, and a pair only counts when
/// the machine was awake and on battery for the whole interval:
/// - either endpoint charging or on AC power  -> charging time, no rate
/// - a delta longer than `sleepGapFactor` x the nominal sample interval, and
///   longer than the `minimumSleepGapSeconds` floor -> sleep gap, no rate
///   (the Mac was not sampling, so we cannot say what happened). Adjacent
///   sleep gaps separated by a short enough awake stretch are coalesced into
///   one (`sleepGapCoalesceSeconds`), so a handful of merged periods reaches
///   the screen instead of dozens of one-sample-pair-long ones.
public enum DrainAnalyzer {

    /// One consecutive-sample interval, classified.
    struct Segment {
        enum Kind { case discharging, charging, sleep }
        var start: Date
        var end: Date
        var kind: Kind
        /// Battery points lost across the interval, clamped at zero.
        var percentDrop: Double
        /// Mean discharge power across the interval.
        var watts: Double

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The fields of a `BatterySample` the drain math actually needs.
    struct Reading {
        var date: Date
        var percent: Double
        /// Raw mAh pair, when the platform reported one — see
        /// `BatterySample.rawCurrentMah`/`rawMaxMah`. Kept as the raw pair
        /// rather than the precomputed `preciseCharge` ratio so `classify`
        /// can difference two readings against a single, stable denominator
        /// (see `gaugeDrop`) instead of two independently-drifting ratios.
        /// `percent` is quantized to a whole integer on most Macs, which
        /// flattens `percentDrop` to zero over short buckets even while real
        /// drain is happening; the raw pair is what `classify(...)` prefers
        /// for that math, with `percent` as the fallback when it's missing.
        var rawCurrentMah: Double?
        var rawMaxMah: Double?
        /// Charging or plugged in: either way the battery is not the source.
        var onPower: Bool
        /// Magnitude of the sampled power draw in watts.
        var watts: Double
        var voltageMv: Int

        init(_ sample: BatterySample) {
            date = Date(timeIntervalSince1970: Double(sample.timestampMs) / 1000)
            percent = sample.percent
            rawCurrentMah = sample.rawCurrentMah
            rawMaxMah = sample.rawMaxMah
            onPower = sample.isCharging || sample.externalPower
            watts = abs(sample.wattsDrawn)
            voltageMv = sample.voltageMv
        }
    }

    public static func analyze(
        samples: [BatterySample],
        window: TimeWindow,
        bucket: Bucket,
        options: AnalyticsOptions = AnalyticsOptions()
    ) -> DrainSeries {
        let readings = samples
            .map(Reading.init)
            .filter { window.contains($0.date) }
            .sorted { $0.date < $1.date }

        let interval = nominalInterval(readings: readings, options: options)
        let (segments, gaps) = classify(readings: readings, interval: interval, options: options)
        let points = bucketize(readings: readings, segments: segments, window: window, bucket: bucket)

        var percentDrained = 0.0
        var dischargeWh = 0.0
        var dischargingSeconds = 0.0
        var chargingSeconds = 0.0
        var sleepSeconds = 0.0
        for segment in segments {
            switch segment.kind {
            case .discharging:
                percentDrained += segment.percentDrop
                dischargeWh += segment.watts * segment.duration / 3600
                dischargingSeconds += segment.duration
            case .charging:
                chargingSeconds += segment.duration
            case .sleep:
                sleepSeconds += segment.duration
            }
        }

        let dischargingHours = dischargingSeconds / 3600
        let overallPctPerHour = dischargingHours > 0 ? percentDrained / dischargingHours : nil
        let overallWatts = dischargingHours > 0 ? dischargeWh / dischargingHours : nil

        let bucketRates = points.compactMap(\.pctPerHour)
        let bucketWatts = points.compactMap(\.watts)

        return DrainSeries(
            window: window,
            bucketSeconds: bucket.seconds,
            points: points,
            gaps: gaps,
            sampleIntervalSeconds: interval,
            percentDrained: percentDrained,
            dischargeWh: dischargeWh,
            dischargingSeconds: dischargingSeconds,
            chargingSeconds: chargingSeconds,
            sleepSeconds: sleepSeconds,
            overallPctPerHour: overallPctPerHour,
            overallWatts: overallWatts,
            medianPctPerHour: median(bucketRates),
            medianWatts: median(bucketWatts)
        )
    }

    // MARK: - Steps

    /// Nominal sample spacing, taken as the median delta so a few long gaps do
    /// not inflate the sleep threshold and hide themselves.
    static func nominalInterval(readings: [Reading], options: AnalyticsOptions) -> Double {
        guard readings.count >= 2 else { return options.assumedSampleIntervalSeconds }
        var deltas: [Double] = []
        deltas.reserveCapacity(readings.count - 1)
        for index in 1..<readings.count {
            let delta = readings[index].date.timeIntervalSince(readings[index - 1].date)
            if delta > 0 { deltas.append(delta) }
        }
        guard let value = median(deltas), value > 0 else {
            return options.assumedSampleIntervalSeconds
        }
        return value
    }

    /// A discharging interval whose gauge read flat, waiting to find out
    /// whether a later real tick will explain it. See `classify(...)`.
    private struct PendingFlatInterval {
        var segmentIndex: Int
        var wattSeconds: Double
        var packWh: Double
    }

    static func classify(
        readings: [Reading],
        interval: Double,
        options: AnalyticsOptions
    ) -> (segments: [Segment], gaps: [SleepGap]) {
        guard readings.count >= 2 else { return ([], []) }

        // Relative *and* absolute: a fast sampler (e.g. 20s) makes the
        // relative factor alone far too sensitive — 3x is 60s there, which a
        // live database showed misclassifying dozens of ordinary 74-1239s
        // scheduling hiccups as sleep. `minimumSleepGapSeconds` is the floor
        // no cadence can shrink below.
        let sleepThreshold = max(interval * max(1, options.sleepGapFactor), options.minimumSleepGapSeconds)
        var segments: [Segment] = []
        var gaps: [SleepGap] = []
        segments.reserveCapacity(readings.count - 1)

        // Flat (gauge == 0) discharging intervals since the last real tick.
        // A real tick almost never lands exactly on a sample boundary — the
        // integer percent counter (or even the raw mAh one, more coarsely)
        // only moves once every few sample gaps — so most discharging
        // intervals read a flat gauge purely from waiting for the next tick,
        // not because nothing was drawn. Those intervals stay pending here
        // until either a real tick arrives to explain the whole span (and
        // gets distributed across it, weighted by each interval's share of
        // the energy actually measured — see the `drop > 0` branch below) or
        // the run never closes (sleep, charging, or the end of the data),
        // in which case `flushPending()` falls back to a standalone,
        // per-interval wattage estimate for each one.
        //
        // This split matters: crediting *every* flat interval with its own
        // independent wattage estimate — which an earlier version of this
        // did — double-counts drain whenever a real tick does eventually
        // arrive, since the tick's own real drop is added on top of
        // estimates that were already guessing at the same energy. Measured
        // on a live 15-minute window: 11 real percentage points (from the
        // actual gauge) were inflated to ~22.7 that way.
        var pendingFlat: [PendingFlatInterval] = []
        var pendingWattSeconds = 0.0

        func flushPending() {
            for entry in pendingFlat {
                segments[entry.segmentIndex].percentDrop = standaloneFallbackDrop(
                    watts: segments[entry.segmentIndex].watts,
                    durationSeconds: segments[entry.segmentIndex].duration,
                    packWh: entry.packWh
                )
            }
            pendingFlat.removeAll()
            pendingWattSeconds = 0
        }

        for index in 1..<readings.count {
            let previous = readings[index - 1]
            let current = readings[index]
            let delta = current.date.timeIntervalSince(previous.date)
            guard delta > 0 else { continue }

            // The gauge-only figure: used as-is for sleep gaps (there is no
            // sane wattage to fall back to across a stretch the Mac wasn't
            // even sampling) and as the real signal discharging segments
            // prefer below. Display (`DrainPoint.percent`) still comes from
            // the integer reading elsewhere — this only changes the rate math.
            let drop = gaugeDrop(previous: previous, current: current)

            if delta > sleepThreshold {
                flushPending()
                let wasCharging = previous.onPower || current.onPower
                gaps.append(SleepGap(
                    start: previous.date,
                    end: current.date,
                    percentLost: drop,
                    wasCharging: wasCharging
                ))
                segments.append(Segment(
                    start: previous.date,
                    end: current.date,
                    kind: .sleep,
                    percentDrop: drop,
                    watts: 0
                ))
                continue
            }

            if previous.onPower || current.onPower {
                flushPending()
                segments.append(Segment(
                    start: previous.date,
                    end: current.date,
                    kind: .charging,
                    percentDrop: 0,
                    watts: 0
                ))
                continue
            }

            let watts = (previous.watts + current.watts) / 2
            let wattSeconds = watts * delta

            if drop > 0 {
                // A real tick: distribute it across every flat interval
                // waiting since the last one, weighted by each interval's
                // share of the energy measured across the whole reconciled
                // span — never a bare, independent estimate stacked on top
                // of a real number.
                let totalWattSeconds = pendingWattSeconds + wattSeconds
                let thisShare: Double
                if totalWattSeconds > 0 {
                    for entry in pendingFlat {
                        segments[entry.segmentIndex].percentDrop = entry.wattSeconds / totalWattSeconds * drop
                    }
                    thisShare = wattSeconds / totalWattSeconds * drop
                } else {
                    // Degenerate: nobody in the run (including this
                    // interval) measured any wattage at all. Split the real
                    // drop evenly rather than divide by zero.
                    let share = drop / Double(pendingFlat.count + 1)
                    for entry in pendingFlat { segments[entry.segmentIndex].percentDrop = share }
                    thisShare = share
                }
                segments.append(Segment(start: previous.date, end: current.date, kind: .discharging, percentDrop: thisShare, watts: watts))
                pendingFlat.removeAll()
                pendingWattSeconds = 0
            } else {
                // Flat: hold this interval's real drop open at 0 until a
                // later tick reconciles the run, or `flushPending()` closes
                // it out on its own.
                let packWh = packCapacityWh(for: previous, nominal: options.nominalPackWattHours)
                segments.append(Segment(start: previous.date, end: current.date, kind: .discharging, percentDrop: 0, watts: watts))
                pendingFlat.append(PendingFlatInterval(segmentIndex: segments.count - 1, wattSeconds: wattSeconds, packWh: packWh))
                pendingWattSeconds += wattSeconds
            }
        }
        flushPending()

        return coalesceSleep(segments: segments, gaps: gaps, coalesceSeconds: max(0, options.sleepGapCoalesceSeconds))
    }

    /// Merges adjacent sleep segments — and any short run of non-sleep
    /// segments bridging two of them — into one sleep segment/gap, when the
    /// bridge's *total* awake time is under `coalesceSeconds`. A Mac waking
    /// briefly mid-sleep, or the sampler hiccuping again right after a real
    /// sleep gap, should read on screen as one sleep period, not several —
    /// and on real hardware that brief-awake bridge is rarely a single
    /// sample pair: a sampler limping back to its normal cadence for a
    /// minute before the next hiccup shows up as several short awake
    /// segments in a row, not one. Bridging only a lone segment (as an
    /// earlier version of this did) left most of those runs unmerged, which
    /// is why a live 6h window still reported 20 "sleep periods" instead of
    /// the handful this coalescing is meant to produce.
    ///
    /// `gaps` must be exactly the ordered subsequence of `.sleep`-kind
    /// segments in `segments` — true by construction, since `classify`
    /// appends both from the same loop iteration — so this walks the two in
    /// lockstep via `consumeSleepWasCharging()` rather than re-matching them
    /// by timestamp.
    private static func coalesceSleep(
        segments: [Segment],
        gaps: [SleepGap],
        coalesceSeconds: Double
    ) -> (segments: [Segment], gaps: [SleepGap]) {
        guard !gaps.isEmpty else { return (segments, gaps) }

        var mergedSegments: [Segment] = []
        var mergedGaps: [SleepGap] = []
        var gapCursor = 0

        func consumeSleepWasCharging() -> Bool {
            defer { gapCursor += 1 }
            return gaps[gapCursor].wasCharging
        }

        var index = 0
        while index < segments.count {
            guard segments[index].kind == .sleep else {
                mergedSegments.append(segments[index])
                index += 1
                continue
            }

            // Absorb this sleep segment, then keep absorbing forward through
            // short non-sleep bridges — each may be several samples long —
            // as long as another sleep segment follows within
            // `coalesceSeconds` of total bridge time.
            var runEnd = index
            var wasCharging = consumeSleepWasCharging()
            var lookahead = index + 1

            while lookahead < segments.count {
                if segments[lookahead].kind == .sleep {
                    runEnd = lookahead
                    wasCharging = wasCharging || consumeSleepWasCharging()
                    lookahead += 1
                    continue
                }
                // Scan the whole run of non-sleep segments, however many
                // samples it took to log it, and see whether it's short
                // enough in total — and actually followed by more sleep —
                // to absorb.
                var bridgeEnd = lookahead
                var bridgeDuration = 0.0
                var bridgeHadCharging = false
                while bridgeEnd < segments.count, segments[bridgeEnd].kind != .sleep {
                    bridgeDuration += segments[bridgeEnd].duration
                    bridgeHadCharging = bridgeHadCharging || segments[bridgeEnd].kind == .charging
                    bridgeEnd += 1
                }
                guard bridgeDuration < coalesceSeconds, bridgeEnd < segments.count else {
                    break
                }
                wasCharging = wasCharging || bridgeHadCharging
                runEnd = bridgeEnd
                wasCharging = wasCharging || consumeSleepWasCharging()
                lookahead = bridgeEnd + 1
            }

            let start = segments[index].start
            let end = segments[runEnd].end
            let percentDrop = segments[index...runEnd].reduce(0) { $0 + $1.percentDrop }
            mergedSegments.append(Segment(start: start, end: end, kind: .sleep, percentDrop: percentDrop, watts: 0))
            mergedGaps.append(SleepGap(start: start, end: end, percentLost: percentDrop, wasCharging: wasCharging))
            index = lookahead
        }

        return (mergedSegments, mergedGaps)
    }

    /// Charge lost between two readings, preferring the raw mAh pair over
    /// the coarser integer `percent` when both endpoints have one. Never
    /// negative — a reading that ticks up while on battery is sensor noise,
    /// not the pack un-discharging (see `testRisingChargeWhileOnBatteryNeverProducesNegativeDrain`).
    ///
    /// The raw pair is differenced against a *single* denominator —
    /// `previous.rawMaxMah` — rather than two independent ratios.
    /// `AppleRawMaxCapacity` drifts on its own by a couple of mAh minute to
    /// minute (measured on real hardware); computing
    /// `previous.preciseCharge - current.preciseCharge` would let that drift
    /// leak into the measured drop, since each ratio has its own wobbling
    /// denominator. Both endpoints are still required to have the full raw
    /// pair before this path is trusted at all — a Mac missing raw keys on
    /// just one sample falls straight back to `percent`.
    private static func gaugeDrop(previous: Reading, current: Reading) -> Double {
        if let previousRaw = previous.rawCurrentMah, let previousMax = previous.rawMaxMah,
           let currentRaw = current.rawCurrentMah, current.rawMaxMah != nil,
           previousMax > 0, previousRaw.isFinite, previousMax.isFinite, currentRaw.isFinite {
            return max(0, (previousRaw - currentRaw) / previousMax * 100)
        }
        return max(0, previous.percent - current.percent)
    }

    /// Watt-hour pack capacity to price a fallback estimate against: the raw
    /// mAh capacity paired with this reading's voltage when available, else
    /// `nominal` (see `AnalyticsOptions.nominalPackWattHours`) — a Mac whose
    /// IORegistry never exposes `AppleRaw{Current,Max}Capacity`, and, in
    /// practice, every database row written before this capacity data
    /// started being captured at all.
    private static func packCapacityWh(for reading: Reading, nominal: Double) -> Double {
        if let rawMaxMah = reading.rawMaxMah, rawMaxMah > 0, reading.voltageMv > 0 {
            return rawMaxMah * Double(reading.voltageMv) / 1_000_000
        }
        return nominal
    }

    /// Last-resort estimate for a single discharging interval that never got
    /// reconciled against a later real tick — the run it belonged to ended
    /// (sleep, charging, or simply ran out of data) before the gauge moved
    /// at all. Turns the interval's own measured wattage into a %/hr-
    /// equivalent drop over its own duration, using `packWh`.
    ///
    /// This is the interval-scoped fallback of last resort, not the primary
    /// path: whenever a real tick *does* arrive to close out a run, `
    /// classify(...)` distributes that tick's real drop across the run
    /// instead of calling this — see the comment above `pendingFlat` there
    /// for why an independent per-interval estimate stacked on top of a real
    /// tick double-counts drain. This only fires for the run at the very end
    /// of the analyzed data (or cut short by sleep/charging) that never got
    /// a closing tick to reconcile against, which is also exactly the
    /// historical-row case: a Mac with no raw mAh data at all reports a flat
    /// integer percent for a very long time, so the whole window is one
    /// never-closed run. A `DrainSeries` must never show a 0.0%/hr rate next
    /// to a nonzero watt average; this is what makes that impossible even in
    /// that case.
    private static func standaloneFallbackDrop(watts: Double, durationSeconds: Double, packWh: Double) -> Double {
        guard watts > 0, durationSeconds > 0, packWh > 0 else { return 0 }
        let pctPerHour = watts / packWh * 100
        return pctPerHour * (durationSeconds / 3600)
    }

    /// Spreads segments over epoch-aligned buckets, splitting a segment that
    /// straddles a boundary in proportion to the time it spends on each side.
    static func bucketize(
        readings: [Reading],
        segments: [Segment],
        window: TimeWindow,
        bucket: Bucket
    ) -> [DrainPoint] {
        let width = bucket.seconds
        let origin = (window.start.timeIntervalSince1970 / width).rounded(.down) * width
        let endEpoch = window.end.timeIntervalSince1970
        let count = max(1, Int(((endEpoch - origin) / width).rounded(.up)))

        var percentSum = [Double](repeating: 0, count: count)
        var percentCount = [Int](repeating: 0, count: count)
        var percentDrop = [Double](repeating: 0, count: count)
        var energyWh = [Double](repeating: 0, count: count)
        var dischargingSeconds = [Double](repeating: 0, count: count)
        var chargingSeconds = [Double](repeating: 0, count: count)
        var sleepSeconds = [Double](repeating: 0, count: count)

        func index(for epoch: Double) -> Int {
            let raw = Int(((epoch - origin) / width).rounded(.down))
            return min(max(raw, 0), count - 1)
        }

        for reading in readings {
            let slot = index(for: reading.date.timeIntervalSince1970)
            percentSum[slot] += reading.percent
            percentCount[slot] += 1
        }

        for segment in segments {
            let segmentStart = segment.start.timeIntervalSince1970
            let segmentEnd = segment.end.timeIntervalSince1970
            let total = segmentEnd - segmentStart
            guard total > 0 else { continue }

            var slot = index(for: segmentStart)
            let lastSlot = index(for: segmentEnd)
            while slot <= lastSlot {
                let slotStart = origin + Double(slot) * width
                let overlap = min(segmentEnd, slotStart + width) - max(segmentStart, slotStart)
                if overlap > 0 {
                    let fraction = overlap / total
                    switch segment.kind {
                    case .discharging:
                        percentDrop[slot] += segment.percentDrop * fraction
                        energyWh[slot] += segment.watts * overlap / 3600
                        dischargingSeconds[slot] += overlap
                    case .charging:
                        chargingSeconds[slot] += overlap
                    case .sleep:
                        sleepSeconds[slot] += overlap
                    }
                }
                slot += 1
            }
        }

        return (0..<count).map { slot in
            let start = Date(timeIntervalSince1970: origin + Double(slot) * width)
            let hours = dischargingSeconds[slot] / 3600
            return DrainPoint(
                bucketStart: start,
                bucketEnd: start.addingTimeInterval(width),
                percent: percentCount[slot] > 0 ? percentSum[slot] / Double(percentCount[slot]) : nil,
                percentDrop: percentDrop[slot],
                energyWh: energyWh[slot],
                pctPerHour: hours > 0 ? percentDrop[slot] / hours : nil,
                watts: hours > 0 ? energyWh[slot] / hours : nil,
                dischargingSeconds: dischargingSeconds[slot],
                chargingSeconds: chargingSeconds[slot],
                sleepSeconds: sleepSeconds[slot]
            )
        }
    }

    // MARK: - Helpers

    /// Median of a sample set; the mean of the middle pair when the count is even.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
