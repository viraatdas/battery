import BatteryCore
import SwiftUI

/// The top of the panel: charge, draw, runtime, and how current all of that is.
///
/// This is the one place allowed to use a large type size — it is the answer to
/// "what is happening right now", and everything below it is supporting detail.
struct StatusHeaderView: View {
    var status: StatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.percent(status.percent))
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .numeric()
                    .contentTransition(.numericText())

                if let watts = status.watts {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.watts(watts))
                            .font(.title3.weight(.medium))
                            .numeric()
                        Text("current draw")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Label(status.stateText, systemImage: status.stateSymbol)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(status.isCharging ? Color.green : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }

            HStack(spacing: 6) {
                Text(status.remainingText)
                    .font(.callout)
                    .numeric()
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.quaternary)
                HStack(spacing: 4) {
                    if status.isStale {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(status.freshnessText)
                        .font(.callout)
                        .numeric()
                }
                .foregroundStyle(status.isStale ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
    }
}
