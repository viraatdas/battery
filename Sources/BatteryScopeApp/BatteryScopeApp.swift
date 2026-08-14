import BatteryCore
import SwiftUI

// BatteryScopeApp: SwiftUI shell stub. Real UI is implemented by a later node.

@main
struct BatteryScopeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("BatteryScope")
                .font(.title)
            Text("UI not implemented yet.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
