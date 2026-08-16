import SQLite3
import XCTest
@testable import BatteryCore

/// The v3 schema: process ancestry and memory on `process_samples`, and the
/// `pressure_samples` table.
///
/// The migration cases matter more than the round trips: this app is expected
/// to be pointed at a database an older daemon has been filling for weeks.
final class StoreStallSchemaTests: XCTestCase {

    private var tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    private var dbPath = ""

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BatteryScopeStallTests-\(UUID().uuidString)", isDirectory: true)
        dbPath = tempDir.appendingPathComponent("test.db").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func date(_ offsetSeconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds)
    }

    private func pressureSample(tick: Int64) -> PressureSample {
        PressureSample(
            timestampMs: 1_700_000_000_000 + tick * 30_000,
            memoryLevel: .moderate,
            thermalLevel: .serious,
            totalMemoryBytes: 24 * 1024 * 1024 * 1024,
            availableMemoryBytes: 2 * 1024 * 1024 * 1024,
            compressedBytes: 5 * 1024 * 1024 * 1024,
            swapUsedBytes: 3 * 1024 * 1024 * 1024,
            pageIns: 12_345_678,
            loadAverage1m: 27.5,
            cpuCount: 14
        )
    }

    // MARK: - Round trips

    func testProcessAncestryAndMemoryRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let sample = ProcessSample(
            timestampMs: 1_700_000_000_000,
            pid: 101,
            name: "claude",
            bundlePathHint: nil,
            energyImpact: 42,
            cpuMsPerS: 1500,
            category: .devtools,
            ppid: 100,
            residentBytes: 734_003_200
        )
        try store.insert(processSamples: [sample])

        let read = try store.processSamples(from: date(-60), to: date(60))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.ppid, 100)
        XCTAssertEqual(read.first?.residentBytes, 734_003_200)
    }

    func testUnmeasuredAncestryStaysNull() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(processSamples: [
            ProcessSample(
                timestampMs: 1_700_000_000_000,
                pid: 101,
                name: "claude",
                energyImpact: 1,
                cpuMsPerS: 1,
                category: .devtools
            ),
        ])

        let read = try store.processSamples(from: date(-60), to: date(60))
        XCTAssertNil(read.first?.ppid, "unmeasured must not come back as 0")
        XCTAssertNil(read.first?.residentBytes)
    }

    func testPressureSamplesRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(pressureSample: pressureSample(tick: 0))

        let read = try store.pressureSamples(from: date(-60), to: date(60))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first, pressureSample(tick: 0))
    }

    func testPressureSampleIsReplacedNotDuplicated() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(pressureSample: pressureSample(tick: 0))
        try store.insert(pressureSample: pressureSample(tick: 0))
        XCTAssertEqual(try store.pressureSamples(from: date(-60), to: date(60)).count, 1)
    }

    func testPressureSamplesAreOrderedAndWindowed() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        for tick in [Int64(4), 0, 2] {
            try store.insert(pressureSample: pressureSample(tick: tick))
        }
        let read = try store.pressureSamples(from: date(0), to: date(90))
        XCTAssertEqual(read.map(\.timestampMs), [
            1_700_000_000_000,
            1_700_000_000_000 + 60_000,
        ])
    }

    func testPruneRemovesOldPressureSamples() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var old = pressureSample(tick: 0)
        old.timestampMs = Int64((now.timeIntervalSince1970 - 40 * 86_400) * 1000)
        try store.insert(pressureSample: old)
        try store.insert(pressureSample: pressureSample(tick: 0))

        try store.prune(olderThanDays: 30, now: now)

        let read = try store.pressureSamples(from: date(-60 * 86_400), to: date(60))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.timestampMs, 1_700_000_000_000)
    }

    // MARK: - Agent samples

    private func agentSample(pid: Int32, ppid: Int32, name: String, tick: Int64 = 0) -> ProcessSample {
        ProcessSample(
            timestampMs: 1_700_000_000_000 + tick * 30_000,
            pid: pid,
            name: name,
            energyImpact: 0,
            cpuMsPerS: 750,
            category: .devtools,
            ppid: ppid,
            residentBytes: 600 * 1024 * 1024
        )
    }

    func testTrackedSamplesRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(trackedSamples: [
            agentSample(pid: 100, ppid: 1, name: "rudder-native"),
            agentSample(pid: 101, ppid: 100, name: "claude"),
        ])

        let read = try store.trackedSamples(from: date(-60), to: date(60))
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.map(\.name), ["rudder-native", "claude"])
        XCTAssertEqual(read.last?.ppid, 100)
        XCTAssertEqual(read.last?.residentBytes, 600 * 1024 * 1024)
        XCTAssertEqual(read.last?.cpuMsPerS, 750)
    }

    func testTrackedSamplesGroupIntoSessionsAfterRoundTrip() throws {
        // The round trip has to preserve exactly what the grouping needs.
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(trackedSamples: [
            agentSample(pid: 100, ppid: 1, name: "rudder-native"),
            agentSample(pid: 101, ppid: 100, name: "claude"),
            agentSample(pid: 102, ppid: 100, name: "claude"),
        ])

        let sessions = AgentSessions.sessions(
            samples: try store.trackedSamples(from: date(-60), to: date(60))
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.label, "Rudder")
        XCTAssertEqual(sessions.first?.peakAgentCount, 2)
    }

    func testPruneRemovesOldTrackedSamples() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var old = agentSample(pid: 101, ppid: 100, name: "claude")
        old.timestampMs = Int64((now.timeIntervalSince1970 - 40 * 86_400) * 1000)
        try store.insert(trackedSamples: [old, agentSample(pid: 102, ppid: 100, name: "claude")])

        try store.prune(olderThanDays: 30, now: now)

        XCTAssertEqual(try store.trackedSamples(from: date(-60 * 86_400), to: date(60)).count, 1)
    }

    func testUnmeasuredMemorySurvivesAsNull() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        var sample = agentSample(pid: 101, ppid: 100, name: "claude")
        sample.residentBytes = nil
        try store.insert(trackedSamples: [sample])
        XCTAssertNil(try store.trackedSamples(from: date(-60), to: date(60)).first?.residentBytes)
    }

    // MARK: - Migration from older schemas

    /// Builds a v2 database by hand — the shape a daemon from the previous
    /// release leaves behind.
    private func makeV2Database() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close_v2(handle) }
        let statements = [
            """
            CREATE TABLE battery_samples (
                timestamp_ms INTEGER PRIMARY KEY, percent REAL NOT NULL,
                is_charging INTEGER NOT NULL, external_power INTEGER NOT NULL,
                watts_drawn REAL NOT NULL, voltage_mv INTEGER NOT NULL,
                amperage_ma INTEGER NOT NULL, cycle_count INTEGER NOT NULL,
                max_capacity_pct REAL NOT NULL, temperature_c REAL,
                raw_current_mah REAL, raw_max_mah REAL)
            """,
            """
            CREATE TABLE process_samples (
                timestamp_ms INTEGER NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL,
                bundle_path_hint TEXT, category TEXT NOT NULL,
                energy_impact REAL NOT NULL, cpu_ms_per_s REAL NOT NULL)
            """,
            """
            INSERT INTO process_samples VALUES
                (1700000000000, 101, 'claude', NULL, 'devtools', 42.0, 1500.0)
            """,
            "PRAGMA user_version = 2",
        ]
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, "failed: \(sql)")
        }
    }

    func testOpeningAV2DatabaseReadWriteMigratesItInPlace() throws {
        try makeV2Database()
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)

        // The pre-existing row survives, with its unrecorded fields null.
        let existing = try store.processSamples(from: date(-60), to: date(60))
        XCTAssertEqual(existing.count, 1)
        XCTAssertNil(existing.first?.ppid)

        // And the new columns and table now work.
        try store.insert(processSamples: [
            ProcessSample(
                timestampMs: 1_700_000_030_000,
                pid: 102,
                name: "claude",
                energyImpact: 1,
                cpuMsPerS: 1,
                category: .devtools,
                ppid: 100,
                residentBytes: 1024
            ),
        ])
        try store.insert(pressureSample: pressureSample(tick: 0))
        XCTAssertEqual(try store.pressureSamples(from: date(-60), to: date(60)).count, 1)
        let migrated = try store.processSamples(from: date(20), to: date(60))
        XCTAssertEqual(migrated.first?.ppid, 100)
    }

    func testReadingAV2DatabaseReadOnlyDegradesInsteadOfThrowing() throws {
        // The case that matters in the field: a new app against an old daemon's
        // file, which it cannot migrate because it opened read-only.
        try makeV2Database()
        let store = try SQLiteStore(path: dbPath, mode: .readOnly)

        let samples = try store.processSamples(from: date(-60), to: date(60))
        XCTAssertEqual(samples.count, 1, "battery attribution keeps working")
        XCTAssertNil(samples.first?.ppid)
        XCTAssertEqual(
            try store.pressureSamples(from: date(-60), to: date(60)), [],
            "no pressure table means no stalls, not an error"
        )
        XCTAssertEqual(try store.trackedSamples(from: date(-60), to: date(60)), [])
    }

    func testAnalyticsFallsBackToProcessSamplesWhenAgentTableIsEmpty() throws {
        // A database written by a sampler that recorded ancestry on the process
        // rows but had no dedicated agent table yet.
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(processSamples: [
            ProcessSample(
                timestampMs: 1_700_000_000_000,
                pid: 100,
                name: "rudder-native",
                energyImpact: 5,
                cpuMsPerS: 50,
                category: .devtools,
                ppid: 1,
                residentBytes: 16 * 1024 * 1024
            ),
            ProcessSample(
                timestampMs: 1_700_000_000_000,
                pid: 101,
                name: "claude",
                energyImpact: 90,
                cpuMsPerS: 1000,
                category: .devtools,
                ppid: 100,
                residentBytes: 700 * 1024 * 1024
            ),
        ])

        let analytics = Analytics(store: store)
        let sessions = try analytics.agentSessions(
            window: TimeWindow(start: date(-60), end: date(60))
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.label, "Rudder")
    }

    func testAgentTableWinsOverProcessSamplesWhenBothExist() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(processSamples: [
            ProcessSample(
                timestampMs: 1_700_000_000_000,
                pid: 101,
                name: "claude",
                energyImpact: 90,
                cpuMsPerS: 1000,
                category: .devtools,
                ppid: 1,
                residentBytes: 700 * 1024 * 1024
            ),
        ])
        // The agent table is written every tick and is the better source, so a
        // session only it knows about must still appear.
        try store.insert(trackedSamples: [
            agentSample(pid: 200, ppid: 1, name: "rudder-native"),
            agentSample(pid: 201, ppid: 200, name: "codex"),
        ])

        let sessions = try Analytics(store: store).agentSessions(
            window: TimeWindow(start: date(-60), end: date(60))
        )
        XCTAssertEqual(sessions.map(\.label), ["Rudder"])
    }
}
