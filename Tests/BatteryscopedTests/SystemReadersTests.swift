import BatteryCore
import Darwin
import XCTest
@testable import batteryscoped

/// The two readers that talk to the kernel directly.
///
/// These run against the real machine rather than a fixture, because the thing
/// worth verifying is exactly that the sysctl and libproc calls are wired up
/// correctly — a mocked version of them would only test the mock. Assertions
/// are therefore about shape and self-consistency, not specific values.
final class SystemReadersTests: XCTestCase {

    // MARK: - Process table

    func testSnapshotSeesThisProcessWithItsRealParent() {
        let snapshot = ProcessTableReader.snapshot()
        XCTAssertFalse(snapshot.isEmpty, "the process table is never empty")

        let me = snapshot[getpid()]
        XCTAssertNotNil(me, "the reader must at least see itself")
        XCTAssertEqual(me?.ppid, getppid())
    }

    func testSnapshotReadsResidentMemoryForOwnProcess() {
        // Own-process task info needs no privilege, so this must work whether
        // or not the suite is running as root.
        let resident = ProcessTableReader.residentBytes(ofPid: getpid())
        let value = try? XCTUnwrap(resident)
        XCTAssertGreaterThan(value ?? 0, 1024 * 1024, "a running test process holds at least a megabyte")
    }

    func testResidentMemoryOfImpossiblePidIsNil() {
        XCTAssertNil(
            ProcessTableReader.residentBytes(ofPid: Int32.max),
            "an unreadable pid reports nothing rather than zero"
        )
    }

    func testProcessListIsPlausible() {
        let processes = ProcessTableReader.kernelProcessList()
        let list = try? XCTUnwrap(processes)
        XCTAssertGreaterThan(list?.count ?? 0, 10)
        // launchd is pid 1 on every Mac, and is the sanity check that the
        // buffer was decoded at the right stride rather than garbage.
        XCTAssertTrue(list?.contains { $0.kp_proc.p_pid == 1 } ?? false)
    }

    // MARK: - Enrichment

    private func sample(pid: Int32) -> ProcessSample {
        ProcessSample(
            timestampMs: 1_700_000_000_000,
            pid: pid,
            name: "claude",
            energyImpact: 1,
            cpuMsPerS: 1,
            category: .devtools
        )
    }

    func testEnrichCopiesAncestryOntoMatchingPids() {
        let snapshot: [Int32: ProcessTableReader.Entry] = [
            101: .init(pid: 101, ppid: 100, name: "claude", residentBytes: 4096),
        ]
        let enriched = ProcessTableReader.enrich([sample(pid: 101)], with: snapshot)
        XCTAssertEqual(enriched.first?.ppid, 100)
        XCTAssertEqual(enriched.first?.residentBytes, 4096)
    }

    func testEnrichLeavesUnmatchedSamplesAlone() {
        let snapshot: [Int32: ProcessTableReader.Entry] = [
            101: .init(pid: 101, ppid: 100, name: "claude", residentBytes: 4096),
        ]
        // A process that exited between the powermetrics read and this one.
        let enriched = ProcessTableReader.enrich([sample(pid: 999)], with: snapshot)
        XCTAssertNil(enriched.first?.ppid)
        XCTAssertNil(enriched.first?.residentBytes)
    }

    func testEnrichWithEmptySnapshotIsIdentity() {
        let samples = [sample(pid: 101), sample(pid: 102)]
        XCTAssertEqual(ProcessTableReader.enrich(samples, with: [:]), samples)
    }

    // MARK: - Names

    func testNamesComeFromArgvZeroNotTheInterpreter() {
        // The case this exists for: tools shipped as Node scripts. The kernel's
        // p_comm calls them `node`; argv[0] calls them what they are. Verified
        // here against the test process itself, whose argv[0] is the test
        // runner rather than `swift`.
        //
        // `argumentZero` hands back the path as written — naming it is
        // `displayName(fromPath:)`'s job, because the last component is not
        // always the answer.
        var buffer = [UInt8](repeating: 0, count: ProcessTableReader.argumentMaximum())
        let path = ProcessTableReader.argumentZero(ofPid: getpid(), buffer: &buffer)
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)

        let name = ProcessTableReader.displayName(fromPath: path ?? "")
        XCTAssertFalse(name.contains("/"), "a name, not a path")
        XCTAssertFalse(name.isEmpty)
    }

    func testVersionNumberedExecutablesAreNamedAfterTheProgram() {
        // Claude Code installs itself as .../claude/versions/2.1.233, so the
        // last path component is a version number. It showed up in the power
        // list as "2.1.233" and was invisible to the agent roster.
        XCTAssertEqual(
            ProcessTableReader.displayName(
                fromPath: "/Users/viraat/.local/share/claude/versions/2.1.233"
            ),
            "claude"
        )
    }

    func testOrdinaryPathsKeepTheirLastComponent() {
        XCTAssertEqual(
            ProcessTableReader.displayName(fromPath: "/Applications/Arc.app/Contents/MacOS/Arc"),
            "Arc"
        )
        XCTAssertEqual(
            ProcessTableReader.displayName(
                fromPath: "/opt/homebrew/lib/node_modules/@viraatdas/rudder/dist/native/darwin-arm64/rudder-native"
            ),
            "rudder-native"
        )
        XCTAssertEqual(ProcessTableReader.displayName(fromPath: "/bin/zsh"), "zsh")
        XCTAssertEqual(ProcessTableReader.displayName(fromPath: "claude"), "claude")
    }

    func testAVersionedNameStillResolvesToSomething() {
        // Nothing informative anywhere in the path: keep the last component
        // rather than returning an empty label.
        XCTAssertEqual(ProcessTableReader.displayName(fromPath: "/bin/1.2.3"), "1.2.3")
    }

    func testArgumentMaximumIsSane() {
        XCTAssertGreaterThanOrEqual(ProcessTableReader.argumentMaximum(), 4096)
    }

    func testNamesAreNotTruncatedToSixteenCharacters() {
        // p_comm truncates at 16; argv[0] does not. On any real Mac at least
        // one process has a longer name than that.
        let names = ProcessTableReader.snapshot().values.map(\.name)
        XCTAssertTrue(
            names.contains { $0.count > 16 },
            "no name over 16 characters suggests everything fell back to p_comm"
        )
    }

    // MARK: - Agent samples

    private func entry(
        _ pid: Int32,
        ppid: Int32,
        name: String,
        residentMB: Int64 = 100,
        cpuNs: UInt64 = 0
    ) -> ProcessTableReader.Entry {
        .init(
            pid: pid,
            ppid: ppid,
            name: name,
            residentBytes: residentMB * 1024 * 1024,
            cpuNanoseconds: cpuNs
        )
    }

    private func snapshot(_ entries: [ProcessTableReader.Entry]) -> [Int32: ProcessTableReader.Entry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
    }

    func testTrackedSamplesKeepAgentSessionMembers() {
        let table = snapshot([
            entry(1, ppid: 0, name: "launchd", residentMB: 5),
            entry(100, ppid: 1, name: "rudder-native", residentMB: 20),
            entry(101, ppid: 100, name: "claude", residentMB: 600),
            entry(201, ppid: 101, name: "swift-frontend", residentMB: 900),
        ])

        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 1_700_000_000_000,
            snapshot: table,
            previous: nil
        )

        XCTAssertTrue(Set(samples.map(\.name)).isSuperset(of: ["rudder-native", "claude", "swift-frontend"]))
        XCTAssertEqual(samples.first { $0.name == "claude" }?.ppid, 100)
        XCTAssertEqual(samples.first { $0.name == "claude" }?.residentBytes, 600 * 1024 * 1024)
    }

    func testHeaviestProcessesAreKeptEvenWithNoAgentAnywhere() {
        // The gap this closes: a stall caused by Spotlight or a browser used to
        // be recorded with nothing to name.
        var entries = [entry(1, ppid: 0, name: "launchd", residentMB: 5)]
        for index in 0..<20 {
            entries.append(entry(
                Int32(300 + index),
                ppid: 1,
                name: "filler-\(index)",
                residentMB: Int64(10 + index)
            ))
        }
        entries.append(entry(500, ppid: 1, name: "mds_stores", residentMB: 4_000))

        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 1,
            snapshot: snapshot(entries),
            previous: nil
        )

        XCTAssertFalse(samples.isEmpty, "no agent running is not a reason to record nothing")
        XCTAssertTrue(samples.contains { $0.name == "mds_stores" }, "the heaviest process must survive")
        XCTAssertLessThanOrEqual(
            samples.count,
            ProcessTableReader.topProcessesPerResource * 3,
            "only the top few per resource are kept, not the whole table"
        )
    }

    func testProcessesAtRestAreNotRecorded() {
        // Everything idle and tiny: there is nothing worth a row.
        let table = snapshot([
            .init(pid: 1, ppid: 0, name: "launchd", residentBytes: nil, cpuNanoseconds: nil),
            .init(pid: 300, ppid: 1, name: "Safari", residentBytes: nil, cpuNanoseconds: nil),
        ])
        XCTAssertTrue(
            ProcessTableReader.trackedSamples(timestampMs: 1, snapshot: table, previous: nil).isEmpty
        )
    }

    func testDiskRatesAreDifferencedAgainstThePreviousTick() {
        var before = entry(500, ppid: 1, name: "backupd", residentMB: 50)
        before.diskReadBytes = 0
        before.diskWriteBytes = 1_000_000
        var now = entry(500, ppid: 1, name: "backupd", residentMB: 50)
        now.diskReadBytes = 300_000_000
        now.diskWriteBytes = 601_000_000

        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 30_000,
            snapshot: snapshot([now]),
            previous: .init(timestampMs: 0, entries: snapshot([before]))
        )

        let backupd = samples.first { $0.name == "backupd" }
        XCTAssertEqual(backupd?.diskReadBytesPerS ?? 0, 10_000_000, accuracy: 1)
        XCTAssertEqual(backupd?.diskWriteBytesPerS ?? 0, 20_000_000, accuracy: 1)
        XCTAssertEqual(backupd?.diskBytesPerS ?? 0, 30_000_000, accuracy: 1)
    }

    func testDiskRateIsNilRatherThanZeroOnTheFirstTick() {
        var only = entry(500, ppid: 1, name: "backupd", residentMB: 50)
        only.diskReadBytes = 9_000_000_000
        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 1,
            snapshot: snapshot([only]),
            previous: nil
        )
        XCTAssertNil(samples.first?.diskReadBytesPerS, "unmeasured must not read as idle")
    }

    func testCPURateIsDifferencedAgainstThePreviousTick() {
        let before = snapshot([
            entry(100, ppid: 1, name: "rudder-native", cpuNs: 0),
            entry(101, ppid: 100, name: "claude", cpuNs: 1_000_000_000),
        ])
        let now = snapshot([
            entry(100, ppid: 1, name: "rudder-native", cpuNs: 0),
            // 15 more CPU-seconds over a 30s wall-clock tick: half a core.
            entry(101, ppid: 100, name: "claude", cpuNs: 16_000_000_000),
        ])

        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 30_000,
            snapshot: now,
            previous: .init(timestampMs: 0, entries: before)
        )

        let claude = samples.first { $0.name == "claude" }
        XCTAssertEqual(claude?.cpuMsPerS ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(claude?.cpuCores ?? 0, 0.5, accuracy: 0.001)
    }

    func testFirstTickReportsNoCPURatherThanAFabricatedOne() {
        let table = snapshot([
            entry(100, ppid: 1, name: "rudder-native", cpuNs: 0),
            entry(101, ppid: 100, name: "claude", cpuNs: 900_000_000_000),
        ])
        let samples = ProcessTableReader.trackedSamples(timestampMs: 1, snapshot: table, previous: nil)
        XCTAssertEqual(samples.map(\.cpuMsPerS), samples.map { _ in 0 })
    }

    func testRecycledPidDoesNotProduceANegativeRate() {
        let before = snapshot([entry(101, ppid: 1, name: "claude", cpuNs: 900_000_000_000)])
        // Same pid, a brand new process: its counter starts over.
        let now = snapshot([entry(101, ppid: 1, name: "claude", cpuNs: 1_000_000)])
        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 30_000,
            snapshot: now,
            previous: .init(timestampMs: 0, entries: before)
        )
        XCTAssertEqual(samples.first?.cpuMsPerS, 0)
    }

    func testLiveSnapshotGroupsIntoSessionsWhenAgentsAreRunning() {
        // An integration check against the real machine. It asserts only that
        // whatever it finds is internally consistent, because whether an agent
        // happens to be running is not something a test can require.
        let samples = ProcessTableReader.trackedSamples(
            timestampMs: 1_700_000_000_000,
            snapshot: ProcessTableReader.snapshot(),
            previous: nil
        )
        guard !samples.isEmpty else { return }
        XCTAssertTrue(
            samples.contains { AgentSessions.isAgent(name: $0.name) },
            "a recorded session must contain at least one agent process"
        )
        for sample in samples {
            XCTAssertNotNil(sample.ppid, "every recorded member carries its ancestry")
        }
    }

    // MARK: - Pressure

    func testPressureReadIsSelfConsistent() {
        let sample = SystemPressureReader.read(timestampMs: 1_700_000_000_000)

        XCTAssertEqual(sample.timestampMs, 1_700_000_000_000)
        XCTAssertGreaterThan(sample.totalMemoryBytes, 0)
        XCTAssertGreaterThanOrEqual(sample.availableMemoryBytes, 0)
        XCTAssertLessThanOrEqual(
            sample.availableMemoryBytes, sample.totalMemoryBytes,
            "available memory can never exceed the memory installed"
        )
        XCTAssertGreaterThan(sample.cpuCount, 0)
        XCTAssertGreaterThanOrEqual(sample.loadAverage1m, 0)
        XCTAssertGreaterThanOrEqual(sample.swapUsedBytes, 0)
        XCTAssertGreaterThan(sample.pageIns, 0, "pageins since boot are always nonzero")

        let usedFraction = try? XCTUnwrap(sample.memoryUsedFraction)
        XCTAssertGreaterThan(usedFraction ?? 0, 0)
        XCTAssertLessThanOrEqual(usedFraction ?? 2, 1)
    }

    func testMemoryPressureLevelIsReadFromTheOS() {
        // Any of the four is a legitimate answer; what is verified is that the
        // sysctl is reachable and maps onto the shared scale at all.
        XCTAssertTrue(PressureLevel.allCases.contains(SystemPressureReader.memoryPressureLevel()))
    }

    func testTwoReadsAgreeOnTheMachineItself() {
        // Total memory and core count are properties of the hardware; if they
        // move between reads, something is being decoded wrong.
        let first = SystemPressureReader.read(timestampMs: 1)
        let second = SystemPressureReader.read(timestampMs: 2)
        XCTAssertEqual(first.totalMemoryBytes, second.totalMemoryBytes)
        XCTAssertEqual(first.cpuCount, second.cpuCount)
        XCTAssertGreaterThanOrEqual(
            second.pageIns, first.pageIns,
            "pageins is a cumulative counter and cannot go backwards"
        )
    }
}
