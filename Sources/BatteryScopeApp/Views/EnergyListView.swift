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
    /// Logical cores on this Mac, so the denominator can be stated in full.
    var cpuCount: Int?

    /// Bars are drawn against 100% of the machine rather than against the
    /// biggest row, so a quiet machine looks quiet instead of making its
    /// largest trivial process look full.
    private var maxShare: Double {
        ranking.machineCores != nil
            ? 100
            : max(ranking.rows.compactMap(\.sharePct).max() ?? 0, 0.0001)
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
            // The denominator is stated, because a percentage whose base is
            // unstated is the kind of confident wrong number this app exists to
            // avoid — and for a while this one was exactly that.
            var text = "Share of this Mac's CPU"
            if let cores = ranking.machineCores {
                text += String(format: ", which averaged %.1f", cores)
                if let cpuCount { text += " of \(cpuCount)" }
                text += " cores busy"
            }
            text += ". macOS will not let an unprivileged sampler read the CPU of "
                + "root-owned processes, so kernel work and system daemons share one "
                + "row. To break that row down: sudo ./Scripts/install-daemon.sh"
            return text
        }
    }

    private func line(_ row: EnergyRanking.Row) -> some View {
        let isRemainder = row.kind == .remainder
        return HStack(spacing: 10) {
            Image(systemName: symbol(for: row))
                .font(.system(size: 11))
                .foregroundStyle(isRemainder ? Color.secondary : CategoryStyle.color(row.category))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.callout)
                        .foregroundStyle(isRemainder ? Color.secondary : Color.primary)
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
                    color: isRemainder ? Color.secondary.opacity(0.4) : CategoryStyle.color(row.category),
                    width: 210,
                    height: 5
                )
            }

            Spacer(minLength: 0)

            Text(row.sharePct.map { Fmt.share($0) } ?? "—")
                .font(.callout)
                .numeric()
                .foregroundStyle(isRemainder ? Color.secondary : Color.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
        .help(helpText(row))
    }

    private func symbol(for row: EnergyRanking.Row) -> String {
        switch row.kind {
        case .terminalTab: return "macwindow"
        case .remainder: return "ellipsis.circle"
        case .application: return CategoryStyle.symbol(row.category)
        }
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
