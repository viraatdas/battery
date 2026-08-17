import BatteryCore
import Charts
import SwiftUI

/// Battery level and measured drain over the selected window.
///
/// Two stacked plots share one x axis: the level line on top, the per-bucket
/// drain underneath. They are separate charts rather than one dual-axis chart
/// because a shared y scale between percent and watts would only be decorative.
///
/// Holes are holes. A bucket with no measurable discharge draws nothing, and a
/// sleep gap is shaded across both plots so it is obvious the line was not
/// interpolated through it.
struct DrainChartView: View {
    var series: DrainSeries
    @Binding var metric: ChartData.Metric
    @Binding var choice: WindowChoice

    @Environment(\.isOffscreenRender) private var isOffscreenRender

    private var domain: ClosedRange<Date> { series.window.start...series.window.end }

    /// Ticks past this point would have their label clipped by the right edge of
    /// the plot, so they get a grid line and no text.
    private var lastLabelledTick: Date {
        series.window.end.addingTimeInterval(-series.window.duration * 0.09)
    }
    private var levelSegments: [ChartData.Segment] { ChartData.levelSegments(series) }
    private var bars: [ChartData.Bar] { ChartData.rateBars(series, metric: metric) }
    private var gaps: [SleepGap] { ChartData.gaps(series) }

    var body: some View {
        PanelSection(title: "Drain", footnote: footnote) {
            if ChartData.isPlottable(series) {
                VStack(alignment: .leading, spacing: 10) {
                    levelChart
                    rateChart
                    legend
                }
            } else {
                EmptyHint("No battery samples in \(choice.longTitle) yet.")
            }
        }
        // The window picker lives on the activity chart above, which is the
        // primary one now. Two segmented controls driving the same binding read
        // as two independent settings.
    }

    // MARK: - Level

    private var levelChart: some View {
        Chart {
            gapMarks
            ForEach(levelSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Charge", point.value),
                        series: .value("Segment", segment.id)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: levelDomain)
        // No x labels here: the rate chart directly below shares this axis and
        // labels it once, so the pair reads as one plot instead of two.
        .chartXAxis { xAxis(labelled: false) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(Fmt.percent(percent)).numeric()
                    }
                }
            }
        }
        .frame(height: 96)
        // Room for the last x label, applied to both plots so their plot areas
        // stay aligned with each other.
        .padding(.trailing, 6)
        .accessibilityLabel("Battery charge over \(choice.longTitle)")
    }

    /// Padded a little around the observed range so a nearly flat line does not
    /// fill the plot and look dramatic.
    private var levelDomain: ClosedRange<Double> {
        let values = levelSegments.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max(2, (high - low) * 0.2)
        return max(0, low - padding)...min(100, high + padding)
    }

    // MARK: - Rate

    private var rateChart: some View {
        Chart {
            gapMarks
            ForEach(bars) { bar in
                RectangleMark(
                    xStart: .value("From", bar.start),
                    xEnd: .value("To", bar.end),
                    yStart: .value("Zero", 0),
                    yEnd: .value(metric.axisLabel, bar.value)
                )
                .foregroundStyle(Color.accentColor.opacity(0.55))
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis { xAxis(labelled: true) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(String(format: "%.0f", number)).numeric()
                    }
                }
            }
        }
        .frame(height: 56)
        .padding(.trailing, 6)
        .accessibilityLabel("Drain rate in \(metric.axisLabel) over \(choice.longTitle)")
    }

    // MARK: - Shared marks

    @ChartContentBuilder
    private var gapMarks: some ChartContent {
        ForEach(gaps, id: \.start) { gap in
            RectangleMark(
                xStart: .value("Sleep start", gap.start),
                xEnd: .value("Sleep end", gap.end)
            )
            .foregroundStyle(Color.secondary.opacity(0.16))
        }
    }

    private func xAxis(labelled: Bool) -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(.quaternary)
            if labelled {
                AxisValueLabel {
                    if let date = value.as(Date.self), date <= lastLabelledTick {
                        Text(Fmt.clock(date)).numeric()
                    }
                }
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: Color.accentColor, label: "Charge")
            legendItem(color: Color.accentColor.opacity(0.55), label: "Drain (\(metric.axisLabel))")
            if !gaps.isEmpty {
                legendItem(color: Color.secondary.opacity(0.3), label: "Asleep")
            }
            Spacer(minLength: 0)
            if isOffscreenRender {
                SegmentedStandIn(options: ChartData.Metric.allCases.map(\.axisLabel), selected: metric.axisLabel)
                    .frame(width: 92)
            } else {
                Picker("Rate unit", selection: $metric) {
                    ForEach(ChartData.Metric.allCases) { option in
                        Text(option.axisLabel).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 92)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
        }
    }

    private var footnote: String {
        var parts: [String] = []
        if let rate = series.medianPctPerHour, series.hasDischargeData {
            parts.append("Median \(Fmt.rate(rate))")
        }
        if let watts = series.overallWatts, series.hasDischargeData {
            parts.append(Fmt.watts(watts) + " average")
        }
        if series.sleepSeconds > 0 {
            let lost = series.sleepPercentLost
            let asleep = "Asleep \(Fmt.hoursMinutes(series.sleepSeconds / 3600))"
            parts.append(lost > 0.05 ? asleep + ", \(Fmt.share(lost)) lost" : asleep)
        }
        if series.chargingSeconds > 0 {
            parts.append("Charging \(Fmt.hoursMinutes(series.chargingSeconds / 3600))")
        }
        parts.append("Gaps mean no measured discharge, not zero draw")
        return parts.joined(separator: " · ")
    }
}
