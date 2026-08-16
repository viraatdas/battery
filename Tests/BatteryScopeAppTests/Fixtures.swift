import BatteryCore
import Foundation
@testable import BatteryScopeApp

/// Shared construction helpers for the app-layer tests.
///
/// Everything here is pure model construction — no `SQLiteStore`, no
/// filesystem — so these tests exercise exactly the app-layer logic they
/// claim to and nothing about the database underneath it.
enum Fixtures {

    /// A fixed instant so every test's expectations are independent of when
    /// or where the suite runs.
    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    static func batterySample(
        percent: Double = 50,
        isCharging: Bool = false,
        externalPower: Bool = false,
        wattsDrawn: Double = -10,
        cycleCount: Int = 200,
        maxCapacityPct: Double = 90,
        at date: Date = anchor
    ) -> BatterySample {
        BatterySample(
            timestampMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
            percent: percent,
            isCharging: isCharging,
            externalPower: externalPower,
            wattsDrawn: wattsDrawn,
            voltageMv: 12_000,
            amperageMa: -800,
            cycleCount: cycleCount,
            maxCapacityPct: maxCapacityPct
        )
    }

    static func window(end: Date = anchor, durationHours: Double = 6) -> TimeWindow {
        TimeWindow(start: end.addingTimeInterval(-durationHours * 3600), end: end)
    }

    static func emptySeries(window: TimeWindow) -> DrainSeries {
        DrainSeries(
            window: window,
            bucketSeconds: 900,
            points: [],
            gaps: [],
            sampleIntervalSeconds: 60,
            percentDrained: 0,
            dischargeWh: 0,
            dischargingSeconds: 0,
            chargingSeconds: 0,
            sleepSeconds: 0,
            overallPctPerHour: nil,
            overallWatts: nil,
            medianPctPerHour: nil,
            medianWatts: nil
        )
    }

    static func health(
        percent: Double = 50,
        isCharging: Bool = false,
        externalPower: Bool = false,
        estimatedHoursRemaining: Double? = nil,
        window: TimeWindow
    ) -> BatteryHealth {
        BatteryHealth(
            cycleCount: 200,
            maxCapacityPct: 90,
            percent: percent,
            isCharging: isCharging,
            externalPower: externalPower,
            sampledAt: window.end,
            medianPctPerHour: nil,
            medianWatts: nil,
            fullChargeRuntimeHours: nil,
            estimatedHoursRemaining: estimatedHoursRemaining,
            measuredOver: window
        )
    }

    static func report(
        window: TimeWindow,
        series: DrainSeries? = nil,
        processes: [ProcessUsage] = [],
        categories: [CategoryUsage] = [],
        health: BatteryHealth? = nil
    ) -> AnalyticsReport {
        AnalyticsReport(
            window: window,
            series: series ?? emptySeries(window: window),
            processes: processes,
            categories: categories,
            health: health,
            insights: []
        )
    }

    static func snapshot(
        latest: BatterySample?,
        health: BatteryHealth? = nil,
        generatedAt: Date = anchor,
        hasEverRecordedProcessSamples: Bool = true
    ) -> Snapshot {
        let window = window(end: generatedAt)
        return Snapshot(
            report: report(window: window, health: health),
            latest: latest,
            databasePath: "/tmp/fixture.db",
            generatedAt: generatedAt,
            hasEverRecordedProcessSamples: hasEverRecordedProcessSamples
        )
    }
}
