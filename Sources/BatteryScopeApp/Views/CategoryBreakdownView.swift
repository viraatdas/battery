import BatteryCore
import SwiftUI

/// Where the energy went, by kind of software.
///
/// One stacked bar answers "what sort of thing drained me" in a glance; the
/// legend below turns that into numbers. Both take their colours from
/// `CategoryStyle`, so the bar segment and its legend swatch can never drift.
struct CategoryBreakdownView: View {
    var categories: [CategoryUsage]
    var windowTitle: String
    /// False when the database has never recorded a process sample at all —
    /// in that case `ProcessSamplerMissingNotice` already explains why above
    /// this section, so the empty state here stays brief rather than
    /// repeating it.
    var hasEverRecordedProcessSamples: Bool = true

    private var rows: [CategoryUsage] {
        CategoryStyle.sorted(categories.filter { $0.sharePct > 0 })
    }

    private var total: Double {
        max(rows.reduce(0) { $0 + $1.sharePct }, 0.0001)
    }

    var body: some View {
        PanelSection(
            title: "By category",
            footnote: rows.isEmpty ? nil :
                "Watt-hours are estimates: measured discharge apportioned by each app's share of energy impact."
        ) {
            if rows.isEmpty {
                EmptyHint(hasEverRecordedProcessSamples
                    ? "No process activity recorded for \(windowTitle)."
                    : "Not available — see above.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    stackedBar
                    legend
                }
            }
        }
    }

    private var stackedBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(rows, id: \.category) { row in
                    Rectangle()
                        .fill(CategoryStyle.color(row.category))
                        .frame(width: max(1, geometry.size.width * (row.sharePct / total)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Energy by category")
        .accessibilityValue(rows.map { "\(CategoryStyle.label($0.category)) \(Fmt.share($0.sharePct))" }
            .joined(separator: ", "))
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(rows, id: \.category) { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(CategoryStyle.color(row.category))
                        .frame(width: 9, height: 9)
                    Text(CategoryStyle.label(row.category))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.share(row.sharePct))
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.secondary)
                    Text(Fmt.estimated(Fmt.wattHours(row.estimatedWh)))
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
