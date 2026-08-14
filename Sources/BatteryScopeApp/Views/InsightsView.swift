import BatteryCore
import SwiftUI

/// The ranked findings, already sorted most severe first by the analytics layer.
///
/// Severity is carried by a symbol and a single tint, not by a coloured card —
/// four filled panels stacked up would shout, and most of these are informational.
struct InsightsView: View {
    var insights: [Insight]
    var windowTitle: String

    /// Five is enough to be useful; more is a wall of text nobody reads.
    private var rows: [Insight] { Array(insights.prefix(5)) }

    var body: some View {
        PanelSection(title: "Insights") {
            if rows.isEmpty {
                EmptyHint("Nothing stands out over \(windowTitle).")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { insight in
                        row(insight)
                    }
                }
            }
        }
    }

    private func row(_ insight: Insight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.symbol(insight.severity))
                .font(.callout)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Self.tint(insight.severity))
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ severity: InsightSeverity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .notice: return "lightbulb.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    static func tint(_ severity: InsightSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .notice: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
