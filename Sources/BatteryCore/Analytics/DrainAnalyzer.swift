import Foundation

/// Turns raw battery samples into a bucketed drain series.
///
/// The whole analyzer is pure: same samples in, same series out. It never reads
/// the clock, so scenarios can be replayed exactly in tests.
///
/// Drain is measured between *consecutive* samples, and a pair only counts when
/// the machine was awake and on battery for the whole interval:
/// - either endpoint charging or on AC power  -> charging time, no rate
/// - a delta longer than `sleepGapFactor` x the nominal sample interval -> sleep
///   gap, no rate (the Mac was not sampling, so we cannot say what happened)
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
        /// Charging or plugged in: either way the battery is not the source.
        var onPower: Bool
        /// Magnitude of the sampled power draw in watts.
        var watts: Double

        init(_ sample: BatterySample) {
            date = Date(timeIntervalSince1970: Double(sample.timestampMs) / 1000)
            percent = sample.percent
            onPower = sample.isCharging || sample.externalPower
            watts = abs(sample.wattsDrawn)
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

    static func classify(
        readings: [Reading],
        interval: Double,
        options: AnalyticsOptions
    ) -> (segments: [Segment], gaps: [SleepGap]) {
        guard readings.count >= 2 else { return ([], []) }

        let sleepThreshold = interval * max(1, options.sleepGapFactor)
        var segments: [Segment] = []
        var gaps: [SleepGap] = []
        segments.reserveCapacity(readings.count - 1)

        for index in 1..<readings.count {
            let previous = readings[index - 1]
            let current = readings[index]
            let delta = current.date.timeIntervalSince(previous.date)
            guard delta > 0 else { continue }

            let drop = max(0, previous.percent - current.percent)

            if delta > sleepThreshold {
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
                segments.append(Segment(
                    start: previous.date,
                    end: current.date,
                    kind: .charging,
                    percentDrop: 0,
                    watts: 0
                ))
                continue
            }

            segments.append(Segment(
                start: previous.date,
                end: current.date,
                kind: .discharging,
                percentDrop: drop,
                watts: (previous.watts + current.watts) / 2
            ))
        }

        return (segments, gaps)
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
