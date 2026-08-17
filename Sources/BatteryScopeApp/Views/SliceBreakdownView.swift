import BatteryCore
import SwiftUI

/// What was running during the five minutes you clicked.
///
/// The honesty problem this has to solve: without the root daemon there is no
/// per-process *energy* measurement, only CPU and memory for the heaviest few
/// processes. That is a genuinely useful answer to "what was that spike" and a
/// genuinely incomplete answer to "where did my battery go", so the panel says
/// which one it is giving rather than letting the reader assume.
struct SliceBreakdownView: View {
    var breakdown: ActivityBreakdown?
    var isLoading: Bool
    var onDismiss: () -> Void

    // A `Button` cannot be drawn into an offscreen `ImageRenderer` context and
    // comes out as a placeholder glyph, so the self-test renders without it.
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    var body: some View {
        PanelSection(title: title, footnote: footnote) {
            if let breakdown {
                VStack(alignment: .leading, spacing: 10) {
                    headline(breakdown.slice)
                    if !breakdown.sessions.isEmpty {
                        sessions(breakdown.sessions)
                    }
                    rows(breakdown)
                }
            } else if isLoading {
                EmptyHint("Reading that slice…")
            } else {
                EmptyHint("Click a bar above to see what was running.")
            }
        } accessory: {
            if breakdown != nil, !isOffscreenRender {
                Button("Close", action: onDismiss)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard let breakdown else { return "Slice detail" }
        let start = Fmt.clock(breakdown.slice.start)
        let end = Fmt.clock(breakdown.slice.end)
        return "\(start) – \(end)"
    }

    private var footnote: String? {
        guard let breakdown else { return nil }
        if breakdown.isComplete {
            return "Ranked by energy impact across every process, from powermetrics."
        }
        return "Ranked by CPU. These are the machine's heaviest processes, not every process — "
            + "per-process energy needs the root sampler (sudo ./Scripts/install-daemon.sh)."
    }

    /// The slice's own numbers, so the detail stands on its own without the
    /// reader having to remember which bar they clicked.
    private func headline(_ slice: ActivitySlice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let cores = slice.meanCPUCores {
                    metric(String(format: "%.1f", cores), "cores")
                }
                if let memory = slice.meanMemoryUsedFraction {
                    metric(Fmt.percent(memory * 100), "memory")
                }
                if let watts = slice.meanWatts {
                    metric(Fmt.watts(watts), "draw")
                }
                if let disk = slice.meanDiskBytesPerS, disk > 1024 * 1024 {
                    metric("\(Fmt.bytes(Int64(disk)))/s", "disk")
                }
                Spacer(minLength: 0)
            }
            if let severity = slice.stallSeverity {
                Label(
                    severity >= .critical ? "Your Mac stalled during this slice" : "Under pressure during this slice",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(severity >= .critical ? .red : .orange)
            }
            if !slice.hasBatteryData {
                Text("On AC for all of it — no battery energy to attribute.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout)
                .numeric()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sessions(_ sessions: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sessions.prefix(3)) { session in
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(CategoryStyle.color(.devtools))
                    Text("\(session.label) — \(session.peakAgentCount) agent\(session.peakAgentCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let memory = session.peakResidentBytes {
                        Text(Fmt.bytes(memory))
                            .font(.caption)
                            .numeric()
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func rows(_ breakdown: ActivityBreakdown) -> some View {
        let maxShare = max(breakdown.rows.compactMap(\.sharePct).max() ?? 0, 0.0001)
        return VStack(spacing: 6) {
            ForEach(breakdown.rows) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            CategoryBadge(category: row.category)
                            Spacer(minLength: 4)
                        }
                        ShareBar(
                            fraction: (row.sharePct ?? 0) / maxShare,
                            color: CategoryStyle.color(row.category),
                            width: 190,
                            height: 4
                        )
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(primaryValue(row, basis: breakdown.basis))
                            .font(.callout)
                            .numeric()
                        if let secondary = secondaryValue(row) {
                            Text(secondary)
                                .font(.caption2)
                                .numeric()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func primaryValue(_ row: ActivityBreakdownRow, basis: ActivityBasis) -> String {
        switch basis {
        case .energyImpact:
            return row.sharePct.map { Fmt.share($0) } ?? "—"
        case .cpuAndMemory:
            return String(format: "%.1f cores", row.peakCPUCores)
        }
    }

    private func secondaryValue(_ row: ActivityBreakdownRow) -> String? {
        if let memory = row.peakResidentBytes, memory > 0 {
            return Fmt.bytes(memory)
        }
        if let disk = row.peakDiskBytesPerS, disk > 1024 * 1024 {
            return "\(Fmt.bytes(Int64(disk)))/s"
        }
        return nil
    }
}
