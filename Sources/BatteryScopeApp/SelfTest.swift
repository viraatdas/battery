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
                    // NSSegmentedControl (`.pickerStyle(.segmented)`) can't
                    // draw into an offscreen ImageRenderer context — see
                    // `isOffscreenRender` — so views with one substitute a
                    // static stand-in whenever this is set.
                    .environment(\.isOffscreenRender, true)
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

        // The stall sections, driven from constructed data rather than the live
        // database. A healthy Mac has no stall to render, so without this the
        // one layout that only appears when something has gone wrong would be
        // the one layout never checked.
        check("pressure/stalled", SystemPressureView(
            pressure: SelfTestFixtures.pressure,
            stalls: SelfTestFixtures.stalls,
            windowTitle: "the last 6 hours",
            diskBytesPerSecond: 620 * 1024 * 1024
        ))
        check("pressure/healthy", SystemPressureView(
            pressure: SelfTestFixtures.healthyPressure,
            stalls: [],
            windowTitle: "the last 6 hours"
        ))
        // A populated day with a slice open. Real data takes hours to look like
        // this, and the drill-down is the whole point of the chart.
        check("activity/day", ActivityChartView(
            slices: SelfTestFixtures.day,
            machine: SelfTestFixtures.machine,
            metric: .constant(.cpu),
            selection: .constant(SelfTestFixtures.busiestSliceStart),
            choice: .constant(.last24Hours),
            window: SelfTestFixtures.dayWindow,
            windowTitle: "the last 24 hours"
        ))
        check("activity/breakdown", SliceBreakdownView(
            breakdown: SelfTestFixtures.breakdown,
            isLoading: false,
            onDismiss: {}
        ))

        check("agents/sessions", AgentSessionsView(
            sessions: SelfTestFixtures.sessions,
            machine: SelfTestFixtures.machine,
            windowTitle: "the last 6 hours"
        ))

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

/// Constructed states for the self-test: the ones a healthy machine will not
/// produce on demand.
enum SelfTestFixtures {
    private static let gigabyte: Int64 = 1024 * 1024 * 1024

    static let machine = MachineProfile(totalMemoryBytes: 24 * gigabyte, cpuCount: 14)

    static let pressure = PressureSample(
        timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
        memoryLevel: .critical,
        thermalLevel: .serious,
        totalMemoryBytes: 24 * gigabyte,
        availableMemoryBytes: gigabyte / 2,
        compressedBytes: 7 * gigabyte,
        swapUsedBytes: 5 * gigabyte,
        pageIns: 98_000_000,
        loadAverage1m: 38.4,
        cpuCount: 14
    )

    static let healthyPressure = PressureSample(
        timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
        memoryLevel: .nominal,
        thermalLevel: .nominal,
        totalMemoryBytes: 24 * gigabyte,
        availableMemoryBytes: 11 * gigabyte,
        compressedBytes: gigabyte,
        swapUsedBytes: 0,
        pageIns: 1_200_000,
        loadAverage1m: 3.1,
        cpuCount: 14
    )

    static let stalls: [StallEpisode] = [
        StallEpisode(
            start: Date().addingTimeInterval(-3600),
            end: Date().addingTimeInterval(-3380),
            severity: .critical,
            causes: [.memoryPressure, .swapThrash],
            peakLoadPerCore: 2.9,
            peakMemoryUsedFraction: 0.98,
            swapGrowthBytes: 3 * gigabyte,
            peakSwapUsedBytes: 5 * gigabyte,
            peakPageInsPerSecond: 8_400,
            contributors: [
                StallContributor(
                    id: "rudder-native#1227",
                    label: "Rudder",
                    peakAgentCount: 6,
                    peakProcessCount: 19,
                    peakResidentBytes: 11 * gigabyte,
                    peakCPUCores: 9.4,
                    memoryShareOfMachine: 0.46,
                    cpuShareOfMachine: 0.67
                ),
            ],
            sampleCount: 8,
            peakDiskBytesPerSecond: 620 * 1024 * 1024,
            longestStarvedSeconds: 95
        ),
        StallEpisode(
            start: Date().addingTimeInterval(-7200),
            end: Date().addingTimeInterval(-7080),
            severity: .serious,
            causes: [.cpuSaturation],
            peakLoadPerCore: 2.1,
            peakMemoryUsedFraction: 0.81,
            swapGrowthBytes: 0,
            peakSwapUsedBytes: 0,
            peakPageInsPerSecond: 300,
            contributors: [],
            sampleCount: 5,
            heavyProcesses: [
                HeavyProcess(
                    pid: 411,
                    name: "mds_stores",
                    category: .system,
                    peakResidentBytes: 6 * gigabyte,
                    peakCPUCores: 5.2,
                    peakDiskBytesPerS: 340 * 1024 * 1024,
                    memoryShareOfMachine: 0.25,
                    isAgentMember: false
                ),
            ]
        ),
    ]

    /// A day of five-minute slices with a realistic shape: quiet overnight, a
    /// working day, and one bad spike that stalled the machine.
    static let dayWindow: TimeWindow = {
        let end = ActivityTimeline.align(Date(), to: 300)
        return TimeWindow(start: end.addingTimeInterval(-24 * 3600), end: end)
    }()

    static let day: [ActivitySlice] = {
        var slices: [ActivitySlice] = []
        let count = Int(24 * 3600 / 300)
        for index in 0..<count {
            let start = dayWindow.start.addingTimeInterval(Double(index) * 300)
            let hour = Calendar(identifier: .gregorian).component(.hour, from: start)
            // Overnight idles, the working day runs warm, and one spike bites.
            var cores: Double
            switch hour {
            case 0..<7: cores = 0.4
            case 7..<9: cores = 1.6
            case 9..<18: cores = 3.2
            default: cores = 2.1
            }
            let isSpike = index >= count - 40 && index < count - 34
            if isSpike { cores = 11.5 }

            slices.append(ActivitySlice(
                start: start,
                end: start.addingTimeInterval(300),
                meanCPUCores: cores,
                peakCPUCores: cores * 1.4,
                meanMemoryUsedFraction: isSpike ? 0.96 : 0.62,
                peakMemoryUsedFraction: isSpike ? 0.99 : 0.7,
                meanDiskBytesPerS: isSpike ? 180 * 1024 * 1024 : 4 * 1024 * 1024,
                peakDiskBytesPerS: isSpike ? 420 * 1024 * 1024 : 20 * 1024 * 1024,
                meanWatts: hour >= 9 && hour < 18 ? 18 + cores : nil,
                energyWh: hour >= 9 && hour < 18 ? (18 + cores) * 300 / 3600 : nil,
                dischargingSeconds: hour >= 9 && hour < 18 ? 300 : 0,
                externalPowerSeconds: hour >= 9 && hour < 18 ? 0 : 300,
                worstMemoryLevel: isSpike ? .critical : .nominal,
                worstThermalLevel: isSpike ? .serious : .nominal,
                peakSwapUsedBytes: isSpike ? 5 * gigabyte : 0,
                stallSeverity: isSpike ? .critical : nil,
                sampleCount: 60
            ))
        }
        return slices
    }()

    static var busiestSliceStart: Date {
        day.max { ($0.meanCPUCores ?? 0) < ($1.meanCPUCores ?? 0) }?.start ?? dayWindow.start
    }

    static var breakdown: ActivityBreakdown {
        let slice = day.first { $0.start == busiestSliceStart } ?? day[0]
        return ActivityBreakdown(
            slice: slice,
            basis: .cpuAndMemory,
            isComplete: false,
            rows: [
                .init(name: "claude", category: .devtools, energyImpact: 0, peakCPUCores: 4.2,
                      peakResidentBytes: 1_800 * 1024 * 1024, peakDiskBytesPerS: nil, sharePct: 30),
                .init(name: "swift-frontend", category: .devtools, energyImpact: 0, peakCPUCores: 3.6,
                      peakResidentBytes: 2_100 * 1024 * 1024, peakDiskBytesPerS: nil, sharePct: 26),
                .init(name: "mds_stores", category: .system, energyImpact: 0, peakCPUCores: 2.1,
                      peakResidentBytes: 620 * 1024 * 1024,
                      peakDiskBytesPerS: 190 * 1024 * 1024, sharePct: 15),
                .init(name: "Arc", category: .browser, energyImpact: 0, peakCPUCores: 1.1,
                      peakResidentBytes: 900 * 1024 * 1024, peakDiskBytesPerS: nil, sharePct: 8),
            ],
            sessions: sessions
        )
    }

    static var sessions: [AgentSession] {
        AgentSessions.sessions(samples: [
            member(pid: 100, ppid: 1, name: "rudder-native", megabytes: 24, cpuMsPerS: 60),
            member(pid: 101, ppid: 100, name: "claude", megabytes: 1_800, cpuMsPerS: 1_900),
            member(pid: 102, ppid: 100, name: "claude", megabytes: 1_650, cpuMsPerS: 1_200),
            member(pid: 103, ppid: 100, name: "claude", megabytes: 1_540, cpuMsPerS: 800),
            member(pid: 201, ppid: 101, name: "swift-frontend", megabytes: 2_100, cpuMsPerS: 3_800),
            member(pid: 300, ppid: 1, name: "codex", megabytes: 900, cpuMsPerS: 400),
        ])
    }

    private static func member(
        pid: Int32,
        ppid: Int32,
        name: String,
        megabytes: Int64,
        cpuMsPerS: Double
    ) -> ProcessSample {
        ProcessSample(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            pid: pid,
            name: name,
            energyImpact: 0,
            cpuMsPerS: cpuMsPerS,
            category: .devtools,
            ppid: ppid,
            residentBytes: megabytes * 1024 * 1024
        )
    }
}
