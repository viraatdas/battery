import BatteryCore
import SwiftUI

/// Offscreen render check, run with `BATTERYSCOPE_SELFTEST=1`.
///
/// This app is a menu bar item: there is no window to open in a test harness and
/// no way to assert on it from CI. Rendering the panel to a bitmap and exiting is
/// the cheapest way to prove that every state — onboarding, failure, and a real
/// report — actually builds and lays out rather than trapping on some optional.
enum SelfTest {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BATTERYSCOPE_SELFTEST"] == "1"
    }

    @MainActor
    static func run() -> Never {
        var failures = 0

        // Optional: write each rendered state to a directory, so a layout can be
        // eyeballed without a human sitting in front of the menu bar.
        let outputDirectory = ProcessInfo.processInfo.environment["BATTERYSCOPE_SELFTEST_OUT"]

        /// Renders once per appearance: nothing in this app may look right in
        /// light and illegible in dark.
        func check(_ name: String, _ view: some View) {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "" : "-dark"
                let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let content = view
                    .frame(width: Metrics.popoverWidth)
                    .environment(\.colorScheme, scheme)
                    // A literal backdrop rather than `windowBackgroundColor`:
                    // an AppKit colour resolves against the process appearance,
                    // not the scheme forced into this render, which would put
                    // dark-mode text on a light plate in the PNG only.
                    .background(Color(white: scheme == .dark ? 0.13 : 0.98))

                var image: NSImage?
                let render = {
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                if let appearance {
                    appearance.performAsCurrentDrawingAppearance(render)
                } else {
                    render()
                }

                if let image, image.size.width > 0, image.size.height > 0 {
                    print("ok   \(name)\(suffix) — \(Int(image.size.width))x\(Int(image.size.height))")
                    if let outputDirectory { write(image, name: name + suffix, to: outputDirectory) }
                } else {
                    print("FAIL \(name)\(suffix) — produced no image")
                    failures += 1
                }
            }
        }

        func write(_ image: NSImage, name: String, to directory: String) {
            let file = directory + "/" + name.replacingOccurrences(of: "/", with: "-") + ".png"
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            try? png.write(to: URL(fileURLWithPath: file))
        }

        check("onboarding/no-database", OnboardingView(reason: .noDatabase))
        check("onboarding/too-few-samples", OnboardingView(reason: .tooFewSamples(1)))
        check("failure", FailureView(message: "unable to open database file") {})

        for choice in WindowChoice.allCases {
            let model = AppModel(startTimer: false)
            model.applyForTesting(AppModel.load(choice: choice, now: Date()))
            switch model.outcome {
            case .ready(let snapshot):
                // The body rather than `PopoverView`: an offscreen renderer
                // cannot draw the contents of a scroll view.
                check("popover/\(choice.rawValue)", PopoverContent(
                    snapshot: snapshot,
                    choice: .constant(choice),
                    metric: .constant(.watts)
                ))
            case .onboarding(let reason):
                print("skip popover/\(choice.rawValue) — onboarding (\(reason))")
            case .failure(let message):
                print("skip popover/\(choice.rawValue) — \(message)")
            }
        }

        print(failures == 0 ? "self-test passed" : "self-test failed (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
