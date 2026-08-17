import XCTest
@testable import BatteryCore

/// The five-minute activity timeline and its per-slice drill-down.
final class ActivityTimelineTests: XCTestCase {

    /// A round wall-clock instant, so slice alignment is easy to reason about:
    /// 2023-11-14 22:13:20 UTC.
    private let baseMs: Int64 = 1_700_000_000_000
    private let gigabyte: Int64 = 1024 * 1024 * 1024

    private func pressure(
        offsetSeconds: Int64,
        cpuTicksUsed: Int64 = 0,
        cpuTicksIdle: Int64 = 0,
        availableGB: Double = 12,
        diskReadBytes: Int64 = 0,
        cpuCount: Int = 10,
        samplerStart: Double = 100
    ) -> PressureSample {
        PressureSample(
            timestampMs: baseMs + offsetSeconds * 1000,
            memoryLevel: .nominal,
            thermalLevel: .nominal,
            totalMemoryBytes: 24 * gigabyte,
            availableMemoryBytes: Int64(availableGB * Double(gigabyte)),
            compressedBytes: 0,
            swapUsedBytes: 0,
            pageIns: 0,
            loadAverage1m: 2,
            cpuCount: cpuCount,
            uptimeSeconds: 10_000 + Double(offsetSeconds),
            diskReadBytes: diskReadBytes,
            diskWriteBytes: 0,
            intervalSeconds: 5,
            samplerStartUptime: samplerStart,
            cpuTicksUsed: cpuTicksUsed,
            cpuTicksIdle: cpuTicksIdle
        )
    }

    private var window: TimeWindow {
        TimeWindow(
            start: Date(timeIntervalSince1970: Double(baseMs) / 1000 - 3600),
            end: Date(timeIntervalSince1970: Double(baseMs) / 1000 + 3600)
        )
    }

    // MARK: - Slicing

    func testSlicesAlignToWallClockBoundaries() {
        // Whatever the window, a slice must start on a five-minute boundary, so
        // the same slice carries the same numbers between refreshes.
        let aligned = ActivityTimeline.align(
            Date(timeIntervalSince1970: 1_700_000_213),
            to: 300
        )
        XCTAssertEqual(aligned.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertLessThanOrEqual(aligned.timeIntervalSince1970, 1_700_000_213)
    }

    func testCPUUtilisationComesFromTickCounters() {
        // 50 ticks of work against 50 idle over the interval: half the machine.
        let first = pressure(offsetSeconds: 0, cpuTicksUsed: 1_000, cpuTicksIdle: 1_000)
        let second = pressure(offsetSeconds: 5, cpuTicksUsed: 1_050, cpuTicksIdle: 1_050)

        XCTAssertEqual(second.cpuUtilisation(since: first) ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second.cpuCoresBusy(since: first) ?? 0, 5, accuracy: 0.0001)
    }

    func testUtilisationIsNilWhenCountersGoBackwards() {
        // A reboot resets the counters; differencing across it is meaningless.
        let first = pressure(offsetSeconds: 0, cpuTicksUsed: 10_000, cpuTicksIdle: 10_000)
        let second = pressure(offsetSeconds: 5, cpuTicksUsed: 5, cpuTicksIdle: 5)
        XCTAssertNil(second.cpuUtilisation(since: first))
    }

    func testBuildsOneSlicePerFiveMinutesOfSamples() {
        // 20 minutes of samples every 5s, all at 20% CPU.
        var samples: [PressureSample] = []
        for tick in 0...240 {
            samples.append(pressure(
                offsetSeconds: Int64(tick * 5),
                cpuTicksUsed: Int64(tick) * 20,
                cpuTicksIdle: Int64(tick) * 80
            ))
        }

        let slices = ActivityTimeline.build(window: window, pressure: samples)

        XCTAssertGreaterThanOrEqual(slices.count, 4)
        XCTAssertEqual(slices, slices.sorted { $0.start < $1.start }, "slices come back in time order")
        for slice in slices {
            XCTAssertEqual(slice.end.timeIntervalSince(slice.start), 300)
            XCTAssertEqual(slice.meanCPUCores ?? 0, 2, accuracy: 0.01, "20% of 10 cores")
        }
    }

    func testSamplerRestartDoesNotProduceAFabricatedSlice() {
        // Two runs either side of a gap: differencing across it would invent an
        // enormous rate from counters that belong to different runs.
        let before = pressure(offsetSeconds: 0, cpuTicksUsed: 1_000, cpuTicksIdle: 1_000, samplerStart: 100)
        let after = pressure(offsetSeconds: 5, cpuTicksUsed: 900_000, cpuTicksIdle: 1_000, samplerStart: 900)

        let slices = ActivityTimeline.build(window: window, pressure: [before, after])
        XCTAssertTrue(slices.isEmpty, "a pair spanning two sampler runs is not a measurement")
    }

    func testWideGapIsNotDifferenced() {
        let before = pressure(offsetSeconds: 0, cpuTicksUsed: 1_000, cpuTicksIdle: 1_000)
        let after = pressure(offsetSeconds: 3_600, cpuTicksUsed: 900_000, cpuTicksIdle: 1_000)
        XCTAssertTrue(ActivityTimeline.build(window: window, pressure: [before, after]).isEmpty)
    }

    // MARK: - Battery

    private func battery(offsetSeconds: Int64, watts: Double, externalPower: Bool) -> BatterySample {
        BatterySample(
            timestampMs: baseMs + offsetSeconds * 1000,
            percent: 80,
            isCharging: false,
            externalPower: externalPower,
            wattsDrawn: watts,
            voltageMv: 12_000,
            amperageMa: -1_000,
            cycleCount: 100,
            maxCapacityPct: 92
        )
    }

    func testEnergyIsMeasuredOnlyWhileDischarging() {
        var pressures: [PressureSample] = []
        var batteries: [BatterySample] = []
        for tick in 0...60 {
            pressures.append(pressure(
                offsetSeconds: Int64(tick * 5),
                cpuTicksUsed: Int64(tick) * 10,
                cpuTicksIdle: Int64(tick) * 90
            ))
            batteries.append(battery(offsetSeconds: Int64(tick * 5), watts: -20, externalPower: false))
        }

        let slices = ActivityTimeline.build(window: window, pressure: pressures, battery: batteries)
        let first = slices.first

        XCTAssertEqual(first?.meanWatts ?? 0, 20, accuracy: 0.01)
        XCTAssertTrue(first?.hasBatteryData ?? false)
        // Energy is watts times the time actually spent discharging. Asserted
        // as that relationship rather than a fixed figure, because the first
        // slice of a run is a partial one — samples start partway into it.
        let expectedWh = 20 * (first?.dischargingSeconds ?? 0) / 3600
        XCTAssertEqual(first?.energyWh ?? 0, expectedWh, accuracy: 0.001)
        XCTAssertGreaterThan(first?.dischargingSeconds ?? 0, 0)
    }

    func testOnACThereIsNoEnergyToReport() {
        var pressures: [PressureSample] = []
        var batteries: [BatterySample] = []
        for tick in 0...60 {
            pressures.append(pressure(
                offsetSeconds: Int64(tick * 5),
                cpuTicksUsed: Int64(tick) * 10,
                cpuTicksIdle: Int64(tick) * 90
            ))
            batteries.append(battery(offsetSeconds: Int64(tick * 5), watts: 0, externalPower: true))
        }

        let slice = ActivityTimeline.build(window: window, pressure: pressures, battery: batteries).first
        XCTAssertNil(slice?.meanWatts, "watts while plugged in describe the charger, not the workload")
        XCTAssertNil(slice?.energyWh)
        XCTAssertFalse(slice?.hasBatteryData ?? true)
        XCTAssertNotNil(slice?.meanCPUCores, "CPU keeps working on AC, which is the point")
    }

    func testStallsAreMarkedOnTheSlicesTheyOverlap() {
        var pressures: [PressureSample] = []
        for tick in 0...120 {
            pressures.append(pressure(
                offsetSeconds: Int64(tick * 5),
                cpuTicksUsed: Int64(tick) * 10,
                cpuTicksIdle: Int64(tick) * 90
            ))
        }
        let stallStart = Date(timeIntervalSince1970: Double(baseMs) / 1000 + 60)
        let stall = StallEpisode(
            start: stallStart,
            end: stallStart.addingTimeInterval(90),
            severity: .critical,
            causes: [.memoryPressure],
            peakLoadPerCore: 4,
            peakMemoryUsedFraction: 0.98,
            swapGrowthBytes: 0,
            peakSwapUsedBytes: 0,
            peakPageInsPerSecond: nil,
            contributors: [],
            sampleCount: 18
        )

        let slices = ActivityTimeline.build(window: window, pressure: pressures, stalls: [stall])
        let marked = slices.filter { $0.stallSeverity != nil }

        XCTAssertFalse(marked.isEmpty, "the stall has to land on some slice")
        for slice in marked {
            XCTAssertLessThan(slice.start, stall.end)
            XCTAssertGreaterThan(slice.end, stall.start)
        }
        XCTAssertTrue(slices.contains { $0.stallSeverity == nil }, "and not on every slice")
    }

    // MARK: - Breakdown

    private func slice(offsetSeconds: TimeInterval = 0) -> ActivitySlice {
        let start = Date(timeIntervalSince1970: Double(baseMs) / 1000 + offsetSeconds)
        return ActivitySlice(
            start: start,
            end: start.addingTimeInterval(300),
            meanCPUCores: 3,
            peakCPUCores: 5,
            meanMemoryUsedFraction: 0.7,
            peakMemoryUsedFraction: 0.8,
            meanDiskBytesPerS: nil,
            peakDiskBytesPerS: nil,
            meanWatts: nil,
            energyWh: nil,
            dischargingSeconds: 0,
            externalPowerSeconds: 300,
            worstMemoryLevel: .nominal,
            worstThermalLevel: .nominal,
            peakSwapUsedBytes: 0,
            stallSeverity: nil,
            sampleCount: 60
        )
    }

    private func process(
        _ name: String,
        offsetSeconds: Int64,
        cores: Double,
        energy: Double = 0,
        residentGB: Double = 1,
        ppid: Int32 = 1,
        pid: Int32 = 500
    ) -> ProcessSample {
        ProcessSample(
            timestampMs: baseMs + offsetSeconds * 1000,
            pid: pid,
            name: name,
            energyImpact: energy,
            cpuMsPerS: cores * 1000,
            category: Categorizer.categorize(name: name, bundlePathHint: nil),
            ppid: ppid,
            residentBytes: Int64(residentGB * Double(gigabyte))
        )
    }

    func testBreakdownFallsBackToCPUWithoutTheRootSampler() {
        let target = slice()
        let tracked = [
            process("mds_stores", offsetSeconds: 30, cores: 5, pid: 500),
            process("claude", offsetSeconds: 30, cores: 1, pid: 501),
        ]

        let breakdown = ActivityTimeline.breakdown(
            slice: target,
            tracked: tracked,
            machine: MachineProfile(totalMemoryBytes: 24 * gigabyte, cpuCount: 10)
        )

        XCTAssertEqual(breakdown.basis, .cpuAndMemory)
        XCTAssertFalse(breakdown.isComplete, "a top-N list must not claim to be a full accounting")
        XCTAssertEqual(breakdown.rows.first?.name, "mds_stores")
        XCTAssertEqual(breakdown.rows.first?.sharePct ?? 0, 50, accuracy: 0.01, "5 of 10 cores")
    }

    func testBreakdownPrefersEnergyWhenPowermetricsDataExists() {
        let target = slice()
        let energyRows = [
            process("Google Chrome", offsetSeconds: 30, cores: 1, energy: 60, pid: 600),
            process("claude", offsetSeconds: 30, cores: 4, energy: 40, pid: 601),
        ]

        let breakdown = ActivityTimeline.breakdown(
            slice: target,
            tracked: [process("claude", offsetSeconds: 30, cores: 4, pid: 601)],
            processSamples: energyRows
        )

        XCTAssertEqual(breakdown.basis, .energyImpact)
        XCTAssertTrue(breakdown.isComplete)
        XCTAssertEqual(breakdown.rows.first?.name, "Google Chrome", "ranked by energy, not CPU")
        XCTAssertEqual(breakdown.rows.first?.sharePct ?? 0, 60, accuracy: 0.01)
    }

    func testBreakdownOnlyReadsTheSliceItWasAskedFor() {
        let target = slice()
        let tracked = [
            process("in-slice", offsetSeconds: 30, cores: 1, pid: 500),
            // Ten minutes later — a different slice entirely.
            process("out-of-slice", offsetSeconds: 600, cores: 8, pid: 501),
        ]

        let breakdown = ActivityTimeline.breakdown(slice: target, tracked: tracked)
        XCTAssertEqual(breakdown.rows.map(\.name), ["in-slice"])
    }

    func testBreakdownGroupsAgentSessions() {
        let target = slice()
        let tracked = [
            process("rudder-native", offsetSeconds: 30, cores: 0.1, ppid: 1, pid: 100),
            process("claude", offsetSeconds: 30, cores: 2, ppid: 100, pid: 101),
            process("claude", offsetSeconds: 30, cores: 2, ppid: 100, pid: 102),
        ]

        let breakdown = ActivityTimeline.breakdown(slice: target, tracked: tracked)
        XCTAssertEqual(breakdown.sessions.count, 1)
        XCTAssertEqual(breakdown.sessions.first?.label, "Rudder")
        XCTAssertEqual(breakdown.sessions.first?.peakAgentCount, 2)
    }

    func testEmptySliceProducesAnEmptyBreakdownRatherThanNothing() {
        let breakdown = ActivityTimeline.breakdown(slice: slice(), tracked: [])
        XCTAssertTrue(breakdown.rows.isEmpty)
        XCTAssertTrue(breakdown.sessions.isEmpty)
        XCTAssertEqual(breakdown.slice.start, slice().start)
    }
}
