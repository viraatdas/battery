import BatteryCore
import SwiftUI

/// The whole panel. Its only job is ordering and spacing — every number it shows
/// was computed before it was handed the snapshot.
struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.outcome {
            case .onboarding(let reason):
                OnboardingView(reason: reason)
            case .failure(let message):
                FailureView(message: message) { model.refresh() }
            case .ready(let snapshot):
                ready(snapshot)
            }
        }
        .frame(width: Metrics.popoverWidth)
    }

    private func ready(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                PopoverContent(
                    snapshot: snapshot,
                    choice: $model.choice,
                    selectedSlice: $model.selectedSlice,
                    breakdown: model.breakdown,
                    isLoadingBreakdown: model.isLoadingBreakdown
                )
            }
            .frame(maxHeight: Metrics.popoverMaxHeight)

            Divider()
            toolbar(snapshot)
        }
    }

    private func toolbar(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 8) {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Re-read the sample database now")

            // A `TimelineView` rather than reading `Date()` in `body`: this
            // label needs to keep ticking ("just now" → "20s ago" → …) between
            // refreshes, and a plain `Date()` here only re-evaluates when
            // something else happens to redraw the toolbar.
            TimelineView(.periodic(from: snapshot.generatedAt, by: 1)) { context in
                Text("Updated \(Fmt.age(context.date.timeIntervalSince(snapshot.generatedAt)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .numeric()
            }

            Spacer(minLength: 0)

            MoreMenuView(databasePath: snapshot.databasePath)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 8)
    }
}

/// The scrolling body: every section, in reading order. Split out from
/// `PopoverView` so the whole stack can be rendered and inspected without a
/// scroll view around it.
struct PopoverContent: View {
    var snapshot: Snapshot
    @Binding var choice: WindowChoice
    var selectedSlice: Binding<Date?> = .constant(nil)
    var breakdown: ActivityBreakdown?
    var isLoadingBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            StatusHeaderView(status: StatusSummary(snapshot: snapshot))

            SectionDivider()

            // The headline, and for most people the only thing they read: what
            // is using power, named by terminal tab rather than by terminal.
            EnergyListView(
                ranking: snapshot.report.energyRanking,
                windowTitle: choice.longTitle,
                cpuCount: snapshot.report.machine?.cpuCount
            )

            SectionDivider()

            // The day at a glance, with a click-through for any five minutes.
            ActivityChartView(
                slices: snapshot.report.activity,
                machine: snapshot.report.machine,
                selection: selectedSlice,
                choice: $choice,
                window: snapshot.report.window,
                windowTitle: choice.longTitle
            )

            if breakdown != nil || isLoadingBreakdown {
                SectionDivider()
                SliceBreakdownView(
                    breakdown: breakdown,
                    isLoading: isLoadingBreakdown,
                    onDismiss: { selectedSlice.wrappedValue = nil }
                )
            }

            // Everything below is diagnosis rather than the daily question, so
            // it only appears when there is something wrong to report. A panel
            // that is always on screen saying "nothing is wrong" is clutter.
            if !snapshot.report.stalls.isEmpty {
                SectionDivider()
                SystemPressureView(
                    pressure: snapshot.report.pressure,
                    stalls: snapshot.report.stalls,
                    windowTitle: choice.longTitle,
                    diskBytesPerSecond: snapshot.report.diskBytesPerSecond
                )
            }

            if !snapshot.report.insights.isEmpty {
                SectionDivider()
                InsightsView(
                    insights: snapshot.report.insights,
                    windowTitle: choice.longTitle
                )
            }

            SectionDivider()

            BatteryHealthView(health: snapshot.report.health)
        }
        .padding(.bottom, Metrics.sectionSpacing)
    }
}

/// The database exists but would not open or read. Never fatal: the sampler may
/// simply be mid-write, and the next refresh usually clears it.
struct FailureView: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't read the sample database", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("This is usually temporary — the sampler writes in WAL mode and the next refresh normally succeeds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try again", action: retry)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.popoverWidth, alignment: .leading)
    }
}
