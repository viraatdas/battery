import BatteryCore
import SwiftUI

/// What is eating the most power, in order. The headline, and for most people
/// the only thing they came to read.
///
/// The design constraint is that a row has to name something you can act on.
/// "Ghostty — 41%" is not actionable with eight tabs open; "battery — rudder"
/// is, because it tells you which tab to go close. Terminal work is therefore
/// grouped by tab and labelled with the folder the tab is sitting in, which is
/// also what the terminal shows in its own title.
struct EnergyListView: View {
    var ranking: EnergyRanking.Result
    var windowTitle: String

    private var maxShare: Double {
        max(ranking.rows.compactMap(\.sharePct).max() ?? 0, 0.0001)
    }

    var body: some View {
        PanelSection(title: "Using the most power", footnote: footnote) {
            if ranking.isEmpty {
                EmptyHint("Nothing is using much power right now.")
            } else {
                VStack(spacing: 8) {
                    ForEach(ranking.rows) { row in
                        line(row)
                    }
                }
            }
        }
    }

    private var footnote: String? {
        guard !ranking.isEmpty else { return nil }
        switch ranking.basis {
        case .energy:
            return "Share of measured energy over the last few minutes."
        case .cpu:
            // Said plainly rather than dressed up: CPU is the dominant term in
            // what a laptop spends power on, but it is not the whole of it, and
            // claiming otherwise would be the kind of confident wrong number
            // this app exists to avoid.
            return "Ranked by CPU, which is most of where power goes. For true "
                + "per-app energy: sudo ./Scripts/install-daemon.sh"
        }
    }

    private func line(_ row: EnergyRanking.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.kind == .terminalTab ? "macwindow" : CategoryStyle.symbol(row.category))
                .font(.system(size: 11))
                .foregroundStyle(CategoryStyle.color(row.category))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                ShareBar(
                    fraction: (row.sharePct ?? 0) / maxShare,
                    color: CategoryStyle.color(row.category),
                    width: 210,
                    height: 5
                )
            }

            Spacer(minLength: 0)

            Text(row.sharePct.map { Fmt.share($0) } ?? "—")
                .font(.callout)
                .numeric()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
        .help(helpText(row))
    }

    private func accessibilityLabel(_ row: EnergyRanking.Row) -> String {
        var text = row.label
        if let detail = row.detail { text += ", running \(detail)" }
        if let share = row.sharePct { text += ", \(Fmt.share(share))" }
        return text
    }

    private func helpText(_ row: EnergyRanking.Row) -> String {
        var lines: [String] = []
        if row.kind == .terminalTab {
            lines.append("Terminal tab in \(row.label)")
            if let detail = row.detail { lines.append("Running: \(detail)") }
        }
        if let memory = row.residentBytes, memory > 0 {
            lines.append("Memory: \(Fmt.bytes(memory))")
        }
        if ranking.basis == .cpu {
            lines.append(String(format: "CPU: %.2f cores", row.cost))
        }
        return lines.joined(separator: "\n")
    }
}
