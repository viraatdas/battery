import SwiftUI

/// Shown once, above both per-app panels, when the database has never
/// recorded a process sample.
///
/// `CategoryBreakdownView` and `TopOffendersView` both used to fall back to a
/// flat "no activity recorded" line whenever they had nothing to show, which
/// left no way to tell "nothing used power" apart from "you never installed
/// the thing that measures it". Hoisting one explanation up here — instead of
/// two panels each guessing at the same footnote — answers that once, and the
/// panels below go back to being about the data they do have.
struct ProcessSamplerMissingNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Per-app breakdown needs the sampler", systemImage: "info.circle")
                .font(.callout.weight(.medium))
            Text("Battery level and drain are measured already. Per-app energy comes from powermetrics, which only runs as root, so it needs the sampler daemon installed — a supported, optional step, not an error.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: SamplerInstall.command)
        }
        .padding(.horizontal, Metrics.inset)
    }
}
