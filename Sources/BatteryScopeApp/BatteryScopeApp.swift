import BatteryCore
import SwiftUI

/// BatteryScope: a menu bar readout of where the battery actually went.
///
/// The app is a pure reader. The sampler daemon owns the database; this process
/// opens it read-only, redraws every fifteen seconds, and never writes, never
/// escalates privileges, and never blocks the sampler.
@main
struct BatteryScopeApp: App {
    @StateObject private var model = AppModel()

    init() {
        if SelfTest.isRequested { MainActor.assumeIsolated { SelfTest.run() } }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabelView(summary: MenuBarSummary(sample: model.snapshot?.latest))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item itself: one symbol, one number, fixed-width digits so the
/// label does not shuffle its neighbours every time the draw changes.
struct MenuBarLabelView: View {
    var summary: MenuBarSummary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: summary.symbol)
            Text(summary.text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .accessibilityLabel(summary.accessibility)
    }
}
