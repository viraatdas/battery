import BatteryCore
import SwiftUI

/// The ranked list of apps, which is the part of this panel most likely to
/// change someone's behaviour.
///
/// The ranking is trustworthy — it comes straight from measured energy-impact
/// share. The watt-hour figure beside it is apportioned, so it carries a `~`
/// and the section carries a footnote saying so.
struct TopOffendersView: View {
    var processes: [ProcessUsage]
    var windowTitle: String

    /// Eight rows is what fits without the panel becoming a scroll marathon,
    /// and past eight the shares are noise anyway.
    private var rows: [ProcessUsage] { Array(processes.prefix(8)) }

    private var maxShare: Double {
        max(rows.map(\.sharePct).max() ?? 0, 0.0001)
    }

    var body: some View {
        PanelSection(
            title: "Top offenders",
            footnote: rows.isEmpty ? nil :
                "~ marks an estimate. macOS reports a unitless energy impact per process, not watts, so shares are ranked from that and the window's measured discharge is divided among them."
        ) {
            if rows.isEmpty {
                EmptyHint("No app activity recorded for \(windowTitle).")
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.element.name) { index, usage in
                        row(index: index, usage: usage)
                    }
                }
            }
        }
    }

    private func row(index: Int, usage: ProcessUsage) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption)
                .numeric()
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(usage.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CategoryBadge(category: usage.category)
                    Spacer(minLength: 4)
                }
                ShareBar(
                    fraction: usage.sharePct / maxShare,
                    color: CategoryStyle.color(usage.category),
                    width: 200,
                    height: 4
                )
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.share(usage.sharePct))
                    .font(.callout)
                    .numeric()
                Text(Fmt.estimated(Fmt.wattHours(usage.estimatedWh)))
                    .font(.caption2)
                    .numeric()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(usage.name), \(CategoryStyle.label(usage.category)), \(Fmt.share(usage.sharePct)) of drain, estimated \(Fmt.wattHours(usage.estimatedWh))"
        )
        .help(helpText(usage))
    }

    private func helpText(_ usage: ProcessUsage) -> String {
        var lines = [
            "\(Fmt.share(usage.sharePct)) of energy impact over \(windowTitle)",
            "Estimated \(Fmt.wattHours(usage.estimatedWh)) / \(Fmt.share(usage.estimatedPercentPoints)) of battery",
        ]
        if usage.mergedProcessNames.count > 1 {
            lines.append("Includes: " + usage.mergedProcessNames.prefix(6).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// The small category pill used beside an app name.
struct CategoryBadge: View {
    var category: ProcessCategory

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: CategoryStyle.symbol(category))
                .font(.system(size: 8, weight: .semibold))
            Text(CategoryStyle.label(category))
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(CategoryStyle.color(category))
        .background(CategoryStyle.color(category).opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}
