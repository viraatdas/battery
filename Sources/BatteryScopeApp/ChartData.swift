import BatteryCore
import Foundation

/// Turns a `DrainSeries` into something Swift Charts can plot without lying.
///
/// The analytics layer reports `nil` for a bucket with no measurable discharge.
/// Plotting that as zero would draw a flat line through a sleeping Mac, so the
/// line is split into contiguous runs of real readings and each run is drawn as
/// its own series. The gap between two runs stays a gap.
enum ChartData {

    /// One plotted reading. `date` is the middle of its bucket so a line drawn
    /// through several points sits where the measurement actually applies.
    struct Point: Identifiable, Hashable {
        var date: Date
        var value: Double
        var id: Date { date }
    }

    /// A run of consecutive non-nil readings. `id` only has to be unique within
    /// one chart, so the run's index is enough.
    struct Segment: Identifiable, Hashable {
        var id: Int
        var points: [Point]
    }

    /// What the drain chart is currently plotting.
    enum Metric: String, CaseIterable, Identifiable {
        case watts = "Watts"
        case percentPerHour = "%/hr"

        var id: String { rawValue }

        var axisLabel: String {
            switch self {
            case .watts: return "W"
            case .percentPerHour: return "%/hr"
            }
        }

        func value(of point: DrainPoint) -> Double? {
            switch self {
            case .watts: return point.watts.map(abs)
            case .percentPerHour: return point.pctPerHour
            }
        }

        func format(_ value: Double) -> String {
            switch self {
            case .watts: return Fmt.watts(value)
            case .percentPerHour: return Fmt.rate(value)
            }
        }
    }

    /// Battery level over the window, split at every hole.
    static func levelSegments(_ series: DrainSeries) -> [Segment] {
        segments(series.points) { $0.percent }
    }

    /// One bar per bucket that actually measured discharge. Buckets with no
    /// reading produce no bar at all rather than a zero-height one.
    static func rateBars(_ series: DrainSeries, metric: Metric) -> [Bar] {
        series.points.compactMap { point in
            guard let value = metric.value(of: point), value > 0 else { return nil }
            return Bar(start: point.bucketStart, end: point.bucketEnd, value: value)
        }
    }

    /// A single bucket's drain, drawn as a rectangle spanning the bucket's real
    /// width so bar width means something.
    struct Bar: Identifiable, Hashable {
        var start: Date
        var end: Date
        var value: Double
        var id: Date { start }
    }

    /// Sleep gaps clipped to the window, so a gap that began before the window
    /// starts does not stretch the x axis backwards.
    static func gaps(_ series: DrainSeries) -> [SleepGap] {
        series.gaps.compactMap { gap in
            let start = max(gap.start, series.window.start)
            let end = min(gap.end, series.window.end)
            guard end > start else { return nil }
            var clipped = gap
            clipped.start = start
            clipped.end = end
            return clipped
        }
    }

    /// True when there is enough to draw. One point is not a chart.
    static func isPlottable(_ series: DrainSeries) -> Bool {
        levelSegments(series).contains { $0.points.count >= 2 }
            || series.points.contains { $0.watts != nil || $0.pctPerHour != nil }
    }

    // MARK: - Splitting

    static func segments(
        _ points: [DrainPoint],
        value: (DrainPoint) -> Double?
    ) -> [Segment] {
        var result: [Segment] = []
        var current: [Point] = []

        func flush() {
            guard !current.isEmpty else { return }
            result.append(Segment(id: result.count, points: current))
            current = []
        }

        for point in points {
            guard let measured = value(point) else {
                flush()
                continue
            }
            let midpoint = point.bucketStart.addingTimeInterval(
                point.bucketEnd.timeIntervalSince(point.bucketStart) / 2
            )
            current.append(Point(date: midpoint, value: measured))
        }
        flush()
        return result
    }
}
