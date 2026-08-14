import Foundation
import XCTest
@testable import BatteryCore

/// Synthetic sample scenarios shared by the analytics tests.
///
/// Every timestamp is derived from `Fixtures.anchor`, a fixed UTC instant, so
/// assertions on drain rates and on time-of-day strings are stable regardless of
/// when or where the suite runs.
enum Fixtures {

    /// 10:00:00 UTC on a fixed day. An 8-hour window from here has its midpoint
    /// at exactly 14:00 UTC, which the insight rules render as "2 PM".
    static let anchor = Date(timeIntervalSince1970: 1_699_956_000)

    /// UTC everywhere, so `Analytics` never picks up the host's time zone.
    static var options: AnalyticsOptions {
        var options = AnalyticsOptions()
        options.timeZone = TimeZone(identifier: "UTC")!
        return options
    }

    static func at(_ secondsFromAnchor: Double) -> Date {
        anchor.addingTimeInterval(secondsFromAnchor)
    }

    static func hours(_ count: Double) -> TimeInterval { count * 3600 }

    // MARK: - Battery samples

    static func batterySample(
        at date: Date,
        percent: Double,
        charging: Bool = false,
        externalPower: Bool = false,
        watts: Double = 10,
        cycleCount: Int = 312,
        maxCapacityPct: Double = 92
    ) -> BatterySample {
        BatterySample(
            timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
            percent: percent,
            isCharging: charging,
            externalPower: externalPower || charging,
            // The sampler records draw as negative while discharging.
            wattsDrawn: charging ? watts : -watts,
            voltageMv: 12_600,
            amperageMa: charging ? 1_200 : -800,
            cycleCount: cycleCount,
            maxCapacityPct: maxCapacityPct,
            temperatureC: 31.5
        )
    }

    /// A run of samples at a constant rate.
    ///
    /// - Parameters:
    ///   - pctPerHour: percentage points lost per hour; negative charges instead.
    ///   - includeStart: pass `false` when appending to an earlier run so the
    ///     shared boundary sample is not duplicated.
    static func run(
        from start: Date,
        hours durationHours: Double,
        startPercent: Double,
        pctPerHour: Double,
        watts: Double = 10,
        charging: Bool = false,
        intervalSeconds: Double = 60,
        includeStart: Bool = true,
        cycleCount: Int = 312,
        maxCapacityPct: Double = 92
    ) -> [BatterySample] {
        let steps = Int((durationHours * 3600 / intervalSeconds).rounded())
        var samples: [BatterySample] = []
        for step in (includeStart ? 0 : 1)...max(steps, includeStart ? 0 : 1) {
            let offset = Double(step) * intervalSeconds
            let percent = startPercent - pctPerHour * (offset / 3600)
            samples.append(batterySample(
                at: start.addingTimeInterval(offset),
                percent: percent,
                charging: charging,
                watts: watts,
                cycleCount: cycleCount,
                maxCapacityPct: maxCapacityPct
            ))
        }
        return samples
    }

    /// Steady 10%/hr discharge from 80%, two hours long.
    static func steadyDrain(intervalSeconds: Double = 60) -> [BatterySample] {
        run(from: anchor, hours: 2, startPercent: 80, pctPerHour: 10, intervalSeconds: intervalSeconds)
    }

    /// Discharge, an hour plugged in charging, then discharge again.
    static func chargingInterlude() -> [BatterySample] {
        var samples = run(from: anchor, hours: 1, startPercent: 80, pctPerHour: 10)
        samples += run(
            from: at(hours(1)),
            hours: 1,
            startPercent: 70,
            pctPerHour: -20,
            watts: 30,
            charging: true,
            includeStart: false
        )
        samples += run(
            from: at(hours(2)),
            hours: 1,
            startPercent: 90,
            pctPerHour: 10,
            includeStart: false
        )
        return samples
    }

    /// An hour awake, four hours asleep losing 4%, then an hour awake again.
    static func sleepGap() -> [BatterySample] {
        var samples = run(from: anchor, hours: 1, startPercent: 80, pctPerHour: 10)
        samples += run(
            from: at(hours(5)),
            hours: 1,
            startPercent: 66,
            pctPerHour: 10,
            includeStart: true
        )
        return samples
    }

    /// Four hours at 5%/hr, then four hours at 15%/hr — a clean trend break at
    /// the window midpoint (14:00 UTC).
    static func doublingDrain() -> [BatterySample] {
        var samples = run(from: anchor, hours: 4, startPercent: 100, pctPerHour: 5)
        samples += run(
            from: at(hours(4)),
            hours: 4,
            startPercent: 80,
            pctPerHour: 15,
            watts: 30,
            includeStart: false
        )
        return samples
    }

    // MARK: - Process samples

    /// One process's contribution, held constant across the sampled window.
    struct ProcessSpec {
        var name: String
        var energyImpact: Double
        var cpuMsPerS: Double = 50
        var bundlePathHint: String?

        init(_ name: String, energyImpact: Double, cpuMsPerS: Double = 50, bundlePathHint: String? = nil) {
            self.name = name
            self.energyImpact = energyImpact
            self.cpuMsPerS = cpuMsPerS
            self.bundlePathHint = bundlePathHint
        }
    }

    /// Emits every spec at every tick between `start` and `start + hours`.
    static func processSamples(
        specs: [ProcessSpec],
        from start: Date,
        hours durationHours: Double,
        intervalSeconds: Double = 60
    ) -> [ProcessSample] {
        let steps = Int((durationHours * 3600 / intervalSeconds).rounded())
        var samples: [ProcessSample] = []
        var pid: Int32 = 100
        var pidsByName: [String: Int32] = [:]
        for spec in specs {
            pidsByName[spec.name] = pid
            pid += 1
        }

        for step in 0...steps {
            let date = start.addingTimeInterval(Double(step) * intervalSeconds)
            for spec in specs {
                samples.append(ProcessSample(
                    timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                    pid: pidsByName[spec.name] ?? 0,
                    name: spec.name,
                    bundlePathHint: spec.bundlePathHint,
                    energyImpact: spec.energyImpact,
                    cpuMsPerS: spec.cpuMsPerS,
                    category: Categorizer.categorize(name: spec.name, bundlePathHint: spec.bundlePathHint)
                ))
            }
        }
        return samples
    }

    /// A browser-dominated mix, with Chrome split across helper processes the
    /// way macOS actually reports it.
    static let browserHeavy: [ProcessSpec] = [
        ProcessSpec("Google Chrome", energyImpact: 10),
        ProcessSpec("Google Chrome Helper (Renderer)", energyImpact: 30),
        ProcessSpec("Google Chrome Helper (GPU)", energyImpact: 20),
        ProcessSpec("ghostty", energyImpact: 8),
        ProcessSpec("node", energyImpact: 7),
        ProcessSpec("mds_stores", energyImpact: 5),
        ProcessSpec("Slack Helper (Renderer)", energyImpact: 5),
        ProcessSpec("nsurlsessiond", energyImpact: 5),
        ProcessSpec("WindowServer", energyImpact: 10),
    ]

    /// A terminal-dominated mix for the mirror-image assertions.
    static let terminalHeavy: [ProcessSpec] = [
        ProcessSpec("ghostty", energyImpact: 25),
        ProcessSpec("node", energyImpact: 20),
        ProcessSpec("swift-frontend", energyImpact: 15),
        ProcessSpec("Google Chrome", energyImpact: 5),
        ProcessSpec("Google Chrome Helper (Renderer)", energyImpact: 5),
        ProcessSpec("mds_stores", energyImpact: 5),
    ]

    /// A background-dominated mix: nothing the user opened is doing the work.
    /// These daemon-shaped names all classify as `.background`.
    static let backgroundHeavy: [ProcessSpec] = [
        ProcessSpec("nsurlsessiond", energyImpact: 20),
        ProcessSpec("cfprefsd", energyImpact: 15),
        ProcessSpec("trustd", energyImpact: 12),
        ProcessSpec("distnoted", energyImpact: 8),
        ProcessSpec("mds_stores", energyImpact: 10),
        ProcessSpec("ghostty", energyImpact: 5),
    ]
}

/// A `SQLiteStore` on a throwaway file, cleaned up with the test case.
final class TempStore {
    let directory: URL
    let path: String
    let store: SQLiteStore

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BatteryScopeAnalytics-\(UUID().uuidString)", isDirectory: true)
        path = directory.appendingPathComponent("analytics.db").path
        store = try SQLiteStore(path: path, mode: .readWrite)
    }

    /// Reopens the same file read-only, the way the app and CLI use it.
    func readOnlyAnalytics(options: AnalyticsOptions = Fixtures.options) throws -> Analytics {
        Analytics(store: try SQLiteStore(path: path, mode: .readOnly), options: options)
    }

    func seed(battery: [BatterySample], processes: [ProcessSample] = []) throws {
        for sample in battery { try store.insert(batterySample: sample) }
        try store.insert(processSamples: processes)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
