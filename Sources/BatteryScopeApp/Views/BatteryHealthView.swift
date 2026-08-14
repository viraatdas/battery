import BatteryCore
import SwiftUI

/// The footer: the slow-moving facts about the cell itself, plus what a full
/// charge would actually buy at the drain rate we just measured.
struct BatteryHealthView: View {
    var health: BatteryHealth?

    var body: some View {
        PanelSection(title: "Battery health", footnote: footnote) {
            if let health {
                HStack(alignment: .top, spacing: 0) {
                    stat(
                        "Cycles",
                        value: Fmt.integer(health.cycleCount),
                        caption: cycleCaption(health.cycleCount)
                    )
                    Divider().frame(height: 28)
                    stat(
                        "Capacity",
                        value: Fmt.percent(health.maxCapacityPct),
                        caption: capacityCaption(health.maxCapacityPct)
                    )
                    Divider().frame(height: 28)
                    stat(
                        "Full charge",
                        value: health.fullChargeRuntimeHours.map(Fmt.hoursMinutes) ?? "—",
                        caption: health.fullChargeRuntimeHours == nil
                            ? "needs more drain"
                            : "at recent rate"
                    )
                }
            } else {
                EmptyHint("No recent battery reading to report health from.")
            }
        }
    }

    private func stat(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.medium))
                .numeric()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func cycleCaption(_ count: Int) -> String {
        count >= 1000 ? "past typical service life" : "charge cycles"
    }

    private func capacityCaption(_ percent: Double) -> String {
        percent < 80 ? "worn, of design" : "of design"
    }

    private var footnote: String? {
        guard let health, let rate = health.medianPctPerHour, rate > 0 else { return nil }
        let hours = Fmt.hoursMinutes(health.measuredOver.hours)
        return "Runtime estimated from a median \(Fmt.rate(rate)) measured over the last \(hours)."
    }
}
