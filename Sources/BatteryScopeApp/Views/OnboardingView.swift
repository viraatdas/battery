import AppKit
import BatteryCore
import SwiftUI

/// Shown when there is no database, or too little in it to say anything true.
///
/// The app never escalates privileges itself. It shows the exact command, makes
/// it copyable, and explains what you get if you would rather not run it.
struct OnboardingView: View {
    var reason: OnboardingReason

    private static let installCommand = "sudo ./Scripts/install-daemon.sh"

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "battery.100.bolt")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BatteryScope isn't collecting yet")
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Install the sampler")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)

            Text("Run this in Terminal from the project directory. It installs a LaunchDaemon that samples battery and per-process energy once a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            commandBox

            VStack(alignment: .leading, spacing: 6) {
                bullet(
                    symbol: "lock.open",
                    text: "Root is only needed for per-process energy figures. Without it you can still run the batteryscoped sampler yourself and get battery level, charge state and drain rate."
                )
                bullet(
                    symbol: "clock",
                    text: "Charts need at least two samples, so give it a minute or two after installing."
                )
                bullet(
                    symbol: "hand.raised",
                    text: "This app never asks for privileges on its own — it only ever reads the database."
                )
            }

            Text("Looking in \(DBLocation.systemPath) and \(DBLocation.userPath).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.inset)
        .frame(width: Metrics.popoverWidth, alignment: .leading)
    }

    private var subtitle: String {
        switch reason {
        case .noDatabase:
            return "No sample database found yet."
        case .tooFewSamples(let count):
            return count == 0
                ? "The database is there but empty — the sampler hasn't written a reading yet."
                : "Only \(count) sample so far. One reading can't show a trend."
        }
    }

    private var commandBox: some View {
        HStack(spacing: 8) {
            Text(Self.installCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button {
                copy()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help("Copy the install command to the clipboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func bullet(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.installCommand, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}
