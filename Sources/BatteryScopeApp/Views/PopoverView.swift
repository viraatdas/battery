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
                    metric: $model.metric
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

            Text("Updated \(Fmt.age(Date().timeIntervalSince(snapshot.generatedAt)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .numeric()

            Spacer(minLength: 0)

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
    @Binding var metric: ChartData.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            StatusHeaderView(status: StatusSummary(snapshot: snapshot))

            SectionDivider()

            DrainChartView(
                series: snapshot.report.series,
                metric: $metric,
                choice: $choice
            )

            SectionDivider()

            CategoryBreakdownView(
                categories: snapshot.report.categories,
                windowTitle: choice.longTitle
            )

            SectionDivider()

            TopOffendersView(
                processes: snapshot.report.processes,
                windowTitle: choice.longTitle
            )

            SectionDivider()

            InsightsView(
                insights: snapshot.report.insights,
                windowTitle: choice.longTitle
            )

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
