import AppKit
import ServiceManagement
import SwiftUI

/// The toolbar's overflow menu.
///
/// Launch-at-login, a way to the database and the daemon log, and About all
/// need a home somewhere, but the toolbar is deliberately spare — a refresh
/// icon, a timestamp, Quit. One ellipsis keeps it that way instead of turning
/// the toolbar into a row of six buttons.
struct MoreMenuView: View {
    /// Path of the database currently open, so "Reveal Database" can select it
    /// in Finder. `nil` only in states this view is never shown for.
    var databasePath: String?

    @State private var launchAtLoginStatus = SMAppService.mainApp.status

    private static let daemonLogPath = "/Library/Logs/BatteryScope/daemon.log"

    var body: some View {
        Menu {
            Toggle("Launch at Login", isOn: launchAtLoginBinding)

            Divider()

            if let databasePath {
                Button("Reveal Database in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
                }
            }
            if FileManager.default.fileExists(atPath: Self.daemonLogPath) {
                Button("Open Daemon Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Self.daemonLogPath))
                }
            }

            Divider()

            Text(aboutText)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More")
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginStatus == .enabled },
            set: setLaunchAtLogin
        )
    }

    /// Both `register()` and `unregister()` throw — a declined prompt, a
    /// sandboxing quirk, anything. None of that is worth surfacing to a menu
    /// bar toggle; read the real status back afterwards either way, so the
    /// toggle always reflects reality rather than the tap that produced it.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Degrade quietly — the status read below is the source of truth.
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    /// Falls back to a bare app name when there is no bundle to read a
    /// version from, which is how the offscreen self-test runs the binary.
    private var aboutText: String {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "BatteryScope"
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return name
        }
        return "\(name) \(version)"
    }
}
