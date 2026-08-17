import BatteryCore
import Charts
import SwiftUI

/// The day as five-minute bars, each one openable.
///
/// The chart it replaces plotted battery percentage and watts on one frame with
/// two different y-scales, mostly over hours it had no data for, and answered
/// nothing you could act on. This one has a single scale, a single question —
/// how hard was this Mac working at each point of the day — and a click that
/// tells you what was responsible.
struct ActivityChartView: View {
    var slices: [ActivitySlice]
    var machine: MachineProfile?
    /// Chosen from the data rather than offered as a control. Power is the
    /// honest answer when the Mac was on battery; on AC there is no discharge
    /// to measure and CPU is what remains. A picker here only asked the reader
    /// to answer a question the data already settles.
    var metric: ActivityMetric { slices.contains { $0.meanWatts != nil } ? .power : .cpu }
    @Binding var selection: Date?
    @Binding var choice: WindowChoice
    /// The range the picker currently names. The x-axis is pinned to this
    /// rather than to the extent of the data: a chart that silently rescales to
    /// whatever it happens to have shows four minutes while the picker says six
    /// hours, which is how the chart this replaced came to mean nothing.
    var window: TimeWindow
    var windowTitle: String

    private var plotted: [ActivitySlice] {
        slices.filter { metric.value(of: $0, machine: machine) != nil }
    }

    private var selectedSlice: ActivitySlice? {
        guard let selection else { return nil }
        return slices.first { $0.start <= selection && selection < $0.end }
    }

    var body: some View {
        PanelSection(title: "Activity", footnote: footnote) {
            if plotted.isEmpty {
                EmptyHint(emptyMessage)
            } else {
                chart
            }
        } accessory: {
            windowPicker
        }
    }

    private var emptyMessage: String {
        switch metric {
        case .power:
            return "Nothing to plot for \(windowTitle) — your Mac was plugged in the whole time, "
                + "so no energy left the battery to measure. Switch to CPU."
        case .cpu, .memory, .disk:
            return "No samples yet for \(windowTitle). The sampler writes one every five seconds."
        }
    }

    private var footnote: String? {
        guard !plotted.isEmpty else { return nil }
        // Say so when the window is mostly empty, rather than letting a lone
        // bar at one edge imply the rest of the range was idle.
        let covered = Double(plotted.count) * 300
        let span = window.end.timeIntervalSince(window.start)
        if span > 0, covered / span < 0.25 {
            return "Only \(Fmt.hoursMinutes(covered / 3600)) of \(windowTitle) has been sampled so far. "
                + "Click a slice to see what was running."
        }
        if selectedSlice != nil { return nil }
        return "Five-minute slices. Click one to see what was running."
    }

    @ViewBuilder
    private var windowPicker: some View {
        if isOffscreenRender {
            SegmentedStandIn(options: WindowChoice.allCases.map(\.title), selected: choice.title)
        } else {
            Picker("Window", selection: $choice) {
                ForEach(WindowChoice.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(plotted) { slice in
                BarMark(
                    xStart: .value("From", slice.start),
                    xEnd: .value("To", slice.end),
                    y: .value(metric.axisLabel, metric.value(of: slice, machine: machine) ?? 0)
                )
                .foregroundStyle(color(for: slice))
                // The selected bar keeps full opacity while the rest recede, so
                // the link between the bar and the breakdown below is visible.
                .opacity(selection == nil || selectedSlice?.start == slice.start ? 1 : 0.35)
            }

            if let selectedSlice {
                RuleMark(x: .value("Selected", selectedSlice.start))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: window.start...window.end)
        .chartYAxisLabel(metric.axisLabel, position: .leading)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        select(at: location, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Activity over \(windowTitle), five-minute slices")
    }

    /// Maps a tap to the slice under it. Snapping to the nearest slice rather
    /// than requiring a hit inside a bar means a tap in the empty space above a
    /// short bar still selects it.
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotFrame = geometry[proxy.plotFrame!]
        let x = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        guard let nearest = slices.min(by: {
            abs($0.midpoint.timeIntervalSince(date)) < abs($1.midpoint.timeIntervalSince(date))
        }) else { return }
        selection = selection == nearest.start ? nil : nearest.start
    }

    /// A stalled slice is red whatever the metric says, because "the machine
    /// stopped responding here" outranks how busy it happened to be.
    private func color(for slice: ActivitySlice) -> Color {
        if let severity = slice.stallSeverity {
            return severity >= .critical ? .red : .orange
        }
        return metric.color
    }

    @Environment(\.isOffscreenRender) private var isOffscreenRender
}

/// What the activity chart plots.
enum ActivityMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case disk
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .power: return "Power"
        }
    }

    var axisLabel: String {
        switch self {
        case .cpu: return "cores"
        case .memory: return "%"
        case .disk: return "MB/s"
        case .power: return "W"
        }
    }

    var color: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .purple
        case .disk: return .teal
        case .power: return .green
        }
    }

    func value(of slice: ActivitySlice, machine: MachineProfile?) -> Double? {
        switch self {
        case .cpu: return slice.meanCPUCores
        case .memory: return slice.meanMemoryUsedFraction.map { $0 * 100 }
        case .disk: return slice.meanDiskBytesPerS.map { $0 / (1024 * 1024) }
        case .power: return slice.meanWatts
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu: return String(format: "%.1f cores", value)
        case .memory: return Fmt.percent(value)
        case .disk: return String(format: "%.0f MB/s", value)
        case .power: return Fmt.watts(value)
        }
    }
}

extension ActivitySlice {
    var midpoint: Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }
}
