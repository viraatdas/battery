import BatteryCore
import SwiftUI

/// What the machine's headroom looks like right now, and every stall it has
/// hit in the window.
///
/// This is the panel for a different question from the rest of the app: not
/// "where did my battery go" but "why did this thing stop responding". The two
/// are genuinely separate — a Mac pinned at full load on AC power hangs badly
/// while drawing nothing from the battery — so the answer lives in its own
/// section rather than being mixed into the drain figures.
struct SystemPressureView: View {
    var pressure: PressureSample?
    var stalls: [StallEpisode]
    var windowTitle: String
    /// Combined disk throughput right now, when two pressure samples close
    /// enough together exist to derive it. `nil` reads as "not measured".
    var diskBytesPerSecond: Double?

    var body: some View {
        PanelSection(
            title: "System pressure",
            footnote: pressure == nil
                ? "Needs a sampler build from this version — older databases have no pressure data."
                : nil
        ) {
            if let pressure {
                VStack(alignment: .leading, spacing: 10) {
                    gauges(pressure)
                    stallSummary
                }
            } else {
                EmptyHint("No pressure samples yet.")
            }
        }
    }

    // MARK: - Live gauges

    @ViewBuilder
    private func gauges(_ pressure: PressureSample) -> some View {
        VStack(spacing: 7) {
            if let usedFraction = pressure.memoryUsedFraction {
                gauge(
                    label: "Memory",
                    value: Fmt.percent(usedFraction * 100),
                    caption: memoryCaption(pressure),
                    fraction: usedFraction,
                    color: Self.color(
                        for: pressure.memoryLevel,
                        fallback: usedFraction >= 0.9 ? .orange : .green
                    )
                )
            }
            if let loadPerCore = pressure.loadPerCore {
                gauge(
                    label: "CPU",
                    // A multiplier, not a percentage: oversubscription is the
                    // whole point here, and "274%" reads as a broken gauge
                    // where "2.7x" reads as "nearly three deep on every core".
                    value: String(format: "%.1fx", loadPerCore),
                    caption: "load \(String(format: "%.1f", pressure.loadAverage1m)) on \(pressure.cpuCount) cores",
                    // Scaled to 2x cores rather than clipped at 1x, since
                    // everything interesting happens above the core count.
                    fraction: min(loadPerCore / 2, 1),
                    color: loadPerCore >= 1.5 ? .orange : .green
                )
            }
            if pressure.swapUsedBytes > 0 {
                gauge(
                    label: "Swap",
                    value: Fmt.bytes(pressure.swapUsedBytes),
                    caption: "paging to disk",
                    fraction: min(Double(pressure.swapUsedBytes) / Double(max(pressure.totalMemoryBytes, 1)), 1),
                    color: .red
                )
            }
            if let diskBytesPerSecond, diskBytesPerSecond > 1024 * 1024 {
                gauge(
                    label: "Disk",
                    value: "\(Fmt.bytes(Int64(diskBytesPerSecond)))/s",
                    caption: "read + written, all volumes",
                    // 500 MB/s is the scale at which the queue starts to matter
                    // on the machines this runs on.
                    fraction: min(diskBytesPerSecond / (500 * 1024 * 1024), 1),
                    color: diskBytesPerSecond >= 400 * 1024 * 1024 ? .orange : .green
                )
            }
            if pressure.thermalLevel >= .serious {
                Label(
                    "CPU is thermally throttled (\(pressure.thermalLevel.rawValue))",
                    systemImage: "thermometer.high"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// macOS's own pressure verdict wins when it has raised one; otherwise the
    /// caller's read of the raw numbers stands. The OS knows about kill
    /// thresholds we do not, so its `critical` is never softened by our maths.
    static func color(for level: PressureLevel, fallback: Color) -> Color {
        switch level {
        case .nominal: return fallback
        case .moderate: return .orange
        case .serious, .critical: return .red
        }
    }

    private func memoryCaption(_ pressure: PressureSample) -> String {
        let used = pressure.totalMemoryBytes - pressure.availableMemoryBytes
        var caption = "\(Fmt.bytes(used)) of \(Fmt.bytes(pressure.totalMemoryBytes))"
        if pressure.memoryLevel > .nominal {
            caption += " — macOS reports \(pressure.memoryLevel.rawValue) pressure"
        }
        return caption
    }

    private func gauge(
        label: String,
        value: String,
        caption: String,
        fraction: Double,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                ShareBar(fraction: fraction, color: color, width: 200, height: 4)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(value)
                .font(.callout)
                .numeric()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(caption)")
    }

    // MARK: - Stalls

    @ViewBuilder
    private var stallSummary: some View {
        if stalls.isEmpty {
            Text("No stalls in \(windowTitle).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Most recent first, whatever order the caller passed: the
                // stall someone is currently asking about is the last one.
                ForEach(stalls.sorted { $0.start > $1.start }.prefix(3), id: \.id) { episode in
                    StallRow(episode: episode)
                }
                if stalls.count > 3 {
                    Footnote("\(stalls.count - 3) earlier stall\(stalls.count - 3 == 1 ? "" : "s") not shown.")
                }
            }
        }
    }
}

/// One stall: when, how long, why, and who was holding the machine.
struct StallRow: View {
    var episode: StallEpisode

    private var causeText: String {
        episode.causes.prefix(2).map(\.label).joined(separator: " + ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: episode.severity >= .critical
                ? "exclamationmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(episode.severity >= .critical ? .red : .orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Fmt.clock(episode.start))
                        .font(.callout)
                        .numeric()
                    Text(Fmt.hoursMinutes(episode.duration / 3600))
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if !causeText.isEmpty {
                    Text(causeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let culprit = episode.primaryContributor {
                    Text(blame(culprit))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let heavy = episode.heavyProcesses.first(where: { !$0.isAgentMember }) {
                    Text(blame(heavy))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if episode.longestStarvedSeconds > 0 {
                    // The strongest signal there is, so it is said plainly.
                    Text("unresponsive for \(Fmt.hoursMinutes(episode.longestStarvedSeconds / 3600)) — BatteryScope could not run")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Correlational by construction — the wording says "was running", never
    /// "caused", because a session holding memory during a stall is evidence
    /// and not proof.
    private func blame(_ culprit: StallContributor) -> String {
        var text = "\(culprit.label) was running \(culprit.peakAgentCount) agent"
            + (culprit.peakAgentCount == 1 ? "" : "s")
        if let memory = culprit.peakResidentBytes {
            text += ", holding \(Fmt.bytes(memory))"
            if let share = culprit.memoryShareOfMachine {
                text += " (\(Fmt.percent(share * 100)))"
            }
        }
        return text
    }

    /// The same claim for a lone process — the honest answer when the culprit
    /// is Spotlight rather than anything the user launched.
    private func blame(_ heavy: HeavyProcess) -> String {
        var parts: [String] = []
        if let memory = heavy.peakResidentBytes {
            var text = Fmt.bytes(memory)
            if let share = heavy.memoryShareOfMachine {
                text += " (\(Fmt.percent(share * 100)))"
            }
            parts.append(text)
        }
        if heavy.peakCPUCores >= 0.5 {
            parts.append(String(format: "%.1f cores", heavy.peakCPUCores))
        }
        if let disk = heavy.peakDiskBytesPerS, disk > 1024 * 1024 {
            parts.append("\(Fmt.bytes(Int64(disk)))/s disk")
        }
        let detail = parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
        return "heaviest was \(heavy.name)\(detail)"
    }
}
