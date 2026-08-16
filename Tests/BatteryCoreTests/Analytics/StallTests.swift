import XCTest
@testable import BatteryCore

/// Stall detection and attribution. Each rule is exercised on a scenario built
/// to trigger it and on one built to keep it quiet, so a rule cannot pass by
/// always firing.
final class StallTests: XCTestCase {

    private let baseMs: Int64 = 1_700_000_000_000
    private let gigabyte: Int64 = 1024 * 1024 * 1024

    private func pressure(
        tick: Int64,
        memory: PressureLevel = .nominal,
        thermal: PressureLevel = .nominal,
        availableGB: Double = 12,
        swapGB: Double = 0,
        pageIns: Int64 = 0,
        load: Double = 2,
        cpuCount: Int = 10,
        intervalSeconds: Int64 = 30,
        diskReadBytes: Int64 = 0,
        diskWriteBytes: Int64 = 0,
        uptimeOffset: Double? = nil,
        declaredInterval: Double? = nil
    ) -> PressureSample {
        PressureSample(
            timestampMs: baseMs + tick * intervalSeconds * 1000,
            memoryLevel: memory,
            thermalLevel: thermal,
            totalMemoryBytes: 24 * gigabyte,
            availableMemoryBytes: Int64(availableGB * Double(gigabyte)),
            compressedBytes: 0,
            swapUsedBytes: Int64(swapGB * Double(gigabyte)),
            pageIns: pageIns,
            loadAverage1m: load,
            cpuCount: cpuCount,
            // Uptime tracks the wall clock unless a test deliberately breaks
            // the correspondence to simulate sleep.
            uptimeSeconds: uptimeOffset ?? Double(tick * intervalSeconds) + 10_000,
            diskReadBytes: diskReadBytes,
            diskWriteBytes: diskWriteBytes,
            intervalSeconds: declaredInterval ?? Double(intervalSeconds)
        )
    }

    // MARK: - Per-sample verdicts

    func testCalmSampleIsNotAStall() {
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1),
            previous: pressure(tick: 0),
            thresholds: StallThresholds()
        )
        XCTAssertFalse(verdict.isStalled)
        XCTAssertTrue(verdict.causes.isEmpty)
    }

    func testMacOSMemoryPressureIsTakenAtFaceValue() {
        let warning = StallAnalyzer.verdict(
            for: pressure(tick: 1, memory: .moderate),
            previous: nil,
            thresholds: StallThresholds()
        )
        XCTAssertEqual(warning.severity, .serious)
        XCTAssertEqual(warning.causes, [.memoryPressure])

        let critical = StallAnalyzer.verdict(
            for: pressure(tick: 1, memory: .critical),
            previous: nil,
            thresholds: StallThresholds()
        )
        XCTAssertEqual(critical.severity, .critical)
    }

    func testSaturatedCPUIsAStall() {
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1, load: 40, cpuCount: 10),
            previous: nil,
            thresholds: StallThresholds()
        )
        XCTAssertEqual(verdict.severity, .critical)
        XCTAssertEqual(verdict.causes, [.cpuSaturation])
        XCTAssertEqual(verdict.loadPerCore ?? 0, 4, accuracy: 0.001)
    }

    func testSwapGrowthCountsAsThrash() {
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1, swapGB: 1),
            previous: pressure(tick: 0, swapGB: 0),
            thresholds: StallThresholds()
        )
        XCTAssertTrue(verdict.causes.contains(.swapThrash))
        XCTAssertEqual(verdict.swapGrowthBytes, gigabyte)
    }

    func testSwapShrinkingIsRecoveryNotAStall() {
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1, swapGB: 0),
            previous: pressure(tick: 0, swapGB: 4),
            thresholds: StallThresholds()
        )
        XCTAssertFalse(verdict.causes.contains(.swapThrash))
        XCTAssertEqual(verdict.swapGrowthBytes, 0, "negative growth is clamped, never counted")
    }

    func testCountersAreNotDifferencedAcrossASleepGap() {
        // 40 minutes apart: the Mac slept. The page-in counter climbed the
        // whole time, but that is not a rate anyone can act on.
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1, pageIns: 50_000_000, intervalSeconds: 2400),
            previous: pressure(tick: 0, pageIns: 0, intervalSeconds: 2400),
            thresholds: StallThresholds()
        )
        XCTAssertFalse(verdict.isStalled)
        XCTAssertNil(verdict.pageInsPerSecond, "no rate is computed across a gap that wide")
    }

    func testThermalThrottlingIsAStall() {
        let verdict = StallAnalyzer.verdict(
            for: pressure(tick: 1, thermal: .serious),
            previous: nil,
            thresholds: StallThresholds()
        )
        XCTAssertEqual(verdict.causes, [.thermalThrottle])
        // `fair` is warm, not throttled, and must stay quiet.
        let fair = StallAnalyzer.verdict(
            for: pressure(tick: 1, thermal: .moderate),
            previous: nil,
            thresholds: StallThresholds()
        )
        XCTAssertFalse(fair.isStalled)
    }

    // MARK: - Episode assembly

    func testConsecutiveStalledSamplesBecomeOneEpisode() {
        let samples = (0..<8).map { pressure(tick: $0, memory: $0 >= 2 && $0 <= 6 ? .critical : .nominal) }
        let episodes = StallAnalyzer.episodes(pressure: samples)

        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.severity, .critical)
        XCTAssertEqual(episodes.first?.duration, 120, "ticks 2 through 6, 30s apart")
        XCTAssertEqual(episodes.first?.causes, [.memoryPressure])
    }

    func testShortCalmStretchDoesNotSplitOneEpisode() {
        // Pressure oscillates around the threshold; that is one stall, not three.
        let levels: [PressureLevel] = [
            .nominal, .critical, .critical, .nominal, .critical, .critical, .critical, .nominal,
        ]
        let samples = levels.enumerated().map { pressure(tick: Int64($0.offset), memory: $0.element) }
        let episodes = StallAnalyzer.episodes(pressure: samples)

        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.duration, 150, "ticks 1 through 6")
    }

    func testLongCalmStretchSplitsEpisodes() {
        let levels: [PressureLevel] = [
            .critical, .critical, .critical,
            .nominal, .nominal, .nominal, .nominal,
            .critical, .critical, .critical,
        ]
        let samples = levels.enumerated().map { pressure(tick: Int64($0.offset), memory: $0.element) }
        XCTAssertEqual(StallAnalyzer.episodes(pressure: samples).count, 2)
    }

    func testBriefBlipIsDroppedAsNoise() {
        let levels: [PressureLevel] = [.nominal, .critical, .nominal, .nominal, .nominal, .nominal]
        let samples = levels.enumerated().map { pressure(tick: Int64($0.offset), memory: $0.element) }
        // A lone sample spans no time at all, so it can never clear the floor.
        XCTAssertTrue(StallAnalyzer.episodes(pressure: samples).isEmpty)
    }

    func testCalmWindowProducesNoEpisodes() {
        let samples = (0..<20).map { pressure(tick: $0) }
        XCTAssertTrue(StallAnalyzer.episodes(pressure: samples).isEmpty)
    }

    func testDominantCauseIsListedFirst() {
        // Memory fires on every stalled sample, thermal on only one.
        let samples: [PressureSample] = [
            pressure(tick: 0),
            pressure(tick: 1, memory: .critical),
            pressure(tick: 2, memory: .critical, thermal: .serious),
            pressure(tick: 3, memory: .critical),
            pressure(tick: 4),
        ]
        let episode = StallAnalyzer.episodes(pressure: samples).first
        XCTAssertEqual(episode?.causes.first, .memoryPressure)
        XCTAssertEqual(episode?.causes.count, 2)
    }

    // MARK: - Attribution

    private func agentTick(_ tick: Int64, agents: Int, residentGBEach: Double) -> [ProcessSample] {
        var samples: [ProcessSample] = [
            ProcessSample(
                timestampMs: baseMs + tick * 30_000,
                pid: 100,
                name: "rudder-native",
                energyImpact: 0,
                cpuMsPerS: 50,
                category: .devtools,
                ppid: 1,
                residentBytes: 16 * 1024 * 1024
            ),
        ]
        for index in 0..<agents {
            samples.append(ProcessSample(
                timestampMs: baseMs + tick * 30_000,
                pid: Int32(101 + index),
                name: "claude",
                energyImpact: 10,
                cpuMsPerS: 1000,
                category: .devtools,
                ppid: 100,
                residentBytes: Int64(residentGBEach * Double(gigabyte))
            ))
        }
        return samples
    }

    func testStallNamesTheSessionThatWasHoldingTheMachine() {
        let samples = (0..<6).map { pressure(tick: $0, memory: $0 >= 1 && $0 <= 4 ? .critical : .nominal) }
        let agents = (0..<6).flatMap { agentTick($0, agents: 6, residentGBEach: 1.5) }

        let episodes = StallAnalyzer.episodes(
            pressure: samples,
            tracked: agents
        )

        let culprit = episodes.first?.primaryContributor
        XCTAssertEqual(culprit?.label, "Rudder")
        XCTAssertEqual(culprit?.peakAgentCount, 6)
        XCTAssertEqual(culprit?.peakResidentBytes, 9 * gigabyte + 16 * 1024 * 1024)
        XCTAssertEqual(culprit?.memoryShareOfMachine ?? 0, 0.376, accuracy: 0.01)
        XCTAssertEqual(culprit?.cpuShareOfMachine ?? 0, 0.605, accuracy: 0.01)
    }

    func testStallWithNoAgentsRunningHasNoContributors() {
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        let episodes = StallAnalyzer.episodes(pressure: samples, tracked: [])
        XCTAssertEqual(episodes.count, 1)
        XCTAssertTrue(
            episodes[0].contributors.isEmpty,
            "a stall with nothing to blame reports no culprit rather than inventing one"
        )
    }

    func testContributorsAreRankedByMemoryHeld() {
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        var agents: [ProcessSample] = []
        for tick in Int64(0)..<6 {
            agents += agentTick(tick, agents: 2, residentGBEach: 0.5)
            // A second, much larger standalone session.
            agents.append(ProcessSample(
                timestampMs: baseMs + tick * 30_000,
                pid: 500,
                name: "codex",
                energyImpact: 5,
                cpuMsPerS: 200,
                category: .devtools,
                ppid: 1,
                residentBytes: 8 * gigabyte
            ))
        }

        let episodes = StallAnalyzer.episodes(
            pressure: samples,
            tracked: agents
        )

        XCTAssertEqual(episodes.first?.contributors.count, 2)
        XCTAssertEqual(episodes.first?.primaryContributor?.label, "Codex")
    }

    func testAttributionToleratesTimestampSkewBetweenReaders() {
        // Pressure and process samples are written by separate readers, so
        // their timestamps differ slightly even within one tick.
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        let agents = (0..<6).flatMap { agentTick($0, agents: 3, residentGBEach: 1) }
            .map { sample -> ProcessSample in
                var shifted = sample
                shifted.timestampMs += 1_200
                return shifted
            }

        let episodes = StallAnalyzer.episodes(
            pressure: samples,
            tracked: agents
        )
        XCTAssertEqual(episodes.first?.primaryContributor?.label, "Rudder")
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(StallAnalyzer.episodes(pressure: []).isEmpty)
    }

    // MARK: - Sampler starvation

    func testSamplerNotGettingScheduledIsItselfAStall() {
        // A five-minute hole where the sampler should have run every 5s, with
        // the monotonic clock advancing right along with the wall clock: the
        // machine was awake and too busy to spare four milliseconds.
        let before = pressure(tick: 0, intervalSeconds: 5, declaredInterval: 5)
        let after = pressure(tick: 60, intervalSeconds: 5, declaredInterval: 5)

        let verdict = StallAnalyzer.verdict(for: after, previous: before, thresholds: StallThresholds())

        XCTAssertEqual(verdict.severity, .critical)
        XCTAssertTrue(verdict.causes.contains(.samplerStarved))
        XCTAssertEqual(verdict.starvedSeconds, 300, accuracy: 0.001)
    }

    func testSleepIsNotStarvation() {
        // The same hole in the data, but the monotonic clock barely moved —
        // the Mac was asleep, which is not a hang.
        let before = pressure(tick: 0, intervalSeconds: 5, uptimeOffset: 10_000, declaredInterval: 5)
        let after = pressure(tick: 60, intervalSeconds: 5, uptimeOffset: 10_012, declaredInterval: 5)

        let verdict = StallAnalyzer.verdict(for: after, previous: before, thresholds: StallThresholds())

        XCTAssertFalse(verdict.causes.contains(.samplerStarved))
        XCTAssertEqual(verdict.starvedSeconds, 0)
    }

    func testOrdinarySchedulingJitterIsNotStarvation() {
        // One skipped 5s tick is timer coalescing on a laptop, not a stall.
        let before = pressure(tick: 0, intervalSeconds: 5, declaredInterval: 5)
        let after = pressure(tick: 2, intervalSeconds: 5, declaredInterval: 5)
        let verdict = StallAnalyzer.verdict(for: after, previous: before, thresholds: StallThresholds())
        XCTAssertFalse(verdict.causes.contains(.samplerStarved))
    }

    func testStarvationSurvivesOntoTheEpisode() {
        var samples = (0..<4).map { pressure(tick: $0, intervalSeconds: 5, declaredInterval: 5) }
        // A 90-second hole (t=15s to t=105s), then recovery.
        samples.append(pressure(tick: 21, intervalSeconds: 5, declaredInterval: 5))
        samples.append(pressure(tick: 22, intervalSeconds: 5, declaredInterval: 5))
        samples.append(pressure(tick: 23, intervalSeconds: 5, declaredInterval: 5))
        samples.append(pressure(tick: 24, intervalSeconds: 5, declaredInterval: 5))

        let episode = StallAnalyzer.episodes(pressure: samples).first
        XCTAssertEqual(episode?.causes.first, .samplerStarved)
        XCTAssertEqual(episode?.longestStarvedSeconds ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(
            episode?.duration ?? 0, 90, accuracy: 0.001,
            "the episode covers the hole itself, not just the sample that ended it"
        )
        XCTAssertEqual(episode?.severity, .critical)
    }

    // MARK: - Disk

    func testSustainedDiskTrafficIsAStall() {
        // 15 GB read across a 30s tick — 500 MB/s, past the threshold.
        let before = pressure(tick: 0, diskReadBytes: 0)
        let after = pressure(tick: 1, diskReadBytes: 15 * gigabyte)

        let verdict = StallAnalyzer.verdict(for: after, previous: before, thresholds: StallThresholds())

        XCTAssertTrue(verdict.causes.contains(.diskSaturation))
        XCTAssertEqual(verdict.diskBytesPerSecond ?? 0, Double(15 * gigabyte) / 30, accuracy: 1)
    }

    func testOrdinaryDiskTrafficIsNotAStall() {
        let before = pressure(tick: 0, diskReadBytes: 0)
        let after = pressure(tick: 1, diskReadBytes: 100 * 1024 * 1024)
        let verdict = StallAnalyzer.verdict(for: after, previous: before, thresholds: StallThresholds())
        XCTAssertFalse(verdict.isStalled)
        XCTAssertFalse(verdict.causes.contains(.diskSaturation))
    }

    // MARK: - Non-agent attribution

    private func heavyTick(_ tick: Int64, name: String, residentGB: Double, cores: Double) -> ProcessSample {
        ProcessSample(
            timestampMs: baseMs + tick * 30_000,
            pid: 900,
            name: name,
            energyImpact: 0,
            cpuMsPerS: cores * 1000,
            category: Categorizer.categorize(name: name, bundlePathHint: nil),
            ppid: 1,
            residentBytes: Int64(residentGB * Double(gigabyte))
        )
    }

    func testStallWithNoAgentStillNamesTheHeaviestProcess() {
        // The gap this closes: previously this stall reported no culprit at all.
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        let tracked = (0..<6).map { heavyTick($0, name: "mds_stores", residentGB: 9, cores: 6) }

        let episode = StallAnalyzer.episodes(pressure: samples, tracked: tracked).first

        XCTAssertTrue(episode?.contributors.isEmpty ?? false, "Spotlight is not an agent session")
        XCTAssertEqual(episode?.heavyProcesses.first?.name, "mds_stores")
        XCTAssertEqual(episode?.heavyProcesses.first?.peakResidentBytes, 9 * gigabyte)
        XCTAssertEqual(episode?.heavyProcesses.first?.memoryShareOfMachine ?? 0, 0.375, accuracy: 0.01)
        XCTAssertEqual(episode?.heavyProcesses.first?.isAgentMember, false)
        XCTAssertEqual(episode?.culpritLabel, "mds_stores")
    }

    func testAgentSessionStillOutranksALoneProcessAsTheCulprit() {
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        var tracked = (0..<6).flatMap { agentTick($0, agents: 6, residentGBEach: 1.5) }
        tracked += (0..<6).map { heavyTick($0, name: "mds_stores", residentGB: 2, cores: 1) }

        let episode = StallAnalyzer.episodes(pressure: samples, tracked: tracked).first

        XCTAssertEqual(episode?.culpritLabel, "Rudder", "a session is more actionable than one process")
        XCTAssertTrue(episode?.heavyProcesses.contains { $0.name == "mds_stores" } ?? false)
    }

    func testAgentMembersAreMarkedSoTheyAreNotListedTwice() {
        let samples = (0..<6).map { pressure(tick: $0, memory: .critical) }
        let tracked = (0..<6).flatMap { agentTick($0, agents: 2, residentGBEach: 3) }

        let episode = StallAnalyzer.episodes(pressure: samples, tracked: tracked).first
        let claude = episode?.heavyProcesses.first { $0.name == "claude" }
        XCTAssertEqual(claude?.isAgentMember, true)
    }
}
