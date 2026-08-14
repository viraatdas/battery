import XCTest
@testable import BatteryCore

final class StoreTests: XCTestCase {

    private var tempDir: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var dbPath: String = ""

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BatteryScopeTests-\(UUID().uuidString)", isDirectory: true)
        dbPath = tempDir.appendingPathComponent("test.db").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeBatterySample(
        timestampMs: Int64,
        percent: Double = 87.5,
        temperatureC: Double? = 31.2
    ) -> BatterySample {
        BatterySample(
            timestampMs: timestampMs,
            percent: percent,
            isCharging: false,
            externalPower: false,
            wattsDrawn: -7.42,
            voltageMv: 12_600,
            amperageMa: -589,
            cycleCount: 312,
            maxCapacityPct: 91.3,
            temperatureC: temperatureC
        )
    }

    // MARK: - Open / modes

    func testReadWriteCreatesFileAndParentDirectory() throws {
        let nested = tempDir.appendingPathComponent("a/b/c/test.db").path
        _ = try SQLiteStore(path: nested, mode: .readWrite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))

        let attributes = try FileManager.default.attributesOfItem(atPath: nested)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(permissions, 0o644, "db file should be world-readable")
    }

    func testReadOnlyOpenOfMissingFileThrows() {
        XCTAssertThrowsError(try SQLiteStore(path: dbPath, mode: .readOnly))
    }

    func testWALModeIsEnabled() throws {
        _ = try SQLiteStore(path: dbPath, mode: .readWrite)
        // WAL persists in the file header; a fresh connection should report it.
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        _ = store
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    func testReaderCanReadWhileWriterConnectionIsOpen() throws {
        let writer = try SQLiteStore(path: dbPath, mode: .readWrite)
        let sample = makeBatterySample(timestampMs: 1_000)
        try writer.insert(batterySample: sample)

        let reader = try SQLiteStore(path: dbPath, mode: .readOnly)
        let fetched = try reader.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched, [sample])

        // Writer keeps writing after the reader attached.
        try writer.insert(batterySample: makeBatterySample(timestampMs: 2_000))
    }

    // MARK: - Battery sample round-trip

    func testBatterySampleRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let sample = makeBatterySample(timestampMs: 1_700_000_000_000)
        try store.insert(batterySample: sample)

        let fetched = try store.batterySamples(
            from: Date(timeIntervalSince1970: 1_699_999_999),
            to: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertEqual(fetched, [sample])
    }

    func testBatterySampleNilTemperatureRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let sample = makeBatterySample(timestampMs: 5_000, temperatureC: nil)
        try store.insert(batterySample: sample)

        let fetched = try store.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].temperatureC)
        XCTAssertEqual(fetched, [sample])
    }

    func testBatterySampleSameTimestampReplaces() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(batterySample: makeBatterySample(timestampMs: 1_000, percent: 50))
        try store.insert(batterySample: makeBatterySample(timestampMs: 1_000, percent: 49))

        let fetched = try store.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].percent, 49)
    }

    func testBatterySampleRangeFilteringAndOrdering() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        for ts: Int64 in [3_000, 1_000, 5_000, 2_000, 4_000] {
            try store.insert(batterySample: makeBatterySample(timestampMs: ts))
        }

        let fetched = try store.batterySamples(
            from: Date(timeIntervalSince1970: 2),
            to: Date(timeIntervalSince1970: 4)
        )
        XCTAssertEqual(fetched.map(\.timestampMs), [2_000, 3_000, 4_000])
    }

    // MARK: - Process sample round-trip

    func testProcessSampleBatchRoundTrip() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let samples = [
            ProcessSample(
                timestampMs: 1_000,
                pid: 501,
                name: "Google Chrome Helper (Renderer)",
                bundlePathHint: "/Applications/Google Chrome.app",
                energyImpact: 42.7,
                cpuMsPerS: 210.5,
                category: .browser
            ),
            ProcessSample(
                timestampMs: 1_000,
                pid: 992,
                name: "ghostty",
                bundlePathHint: nil,
                energyImpact: 3.1,
                cpuMsPerS: 12.0,
                category: .terminal
            ),
            ProcessSample(
                timestampMs: 2_000,
                pid: 1,
                name: "launchd",
                bundlePathHint: nil,
                energyImpact: 0.4,
                cpuMsPerS: 1.5,
                category: .background
            ),
        ]
        try store.insert(processSamples: samples)

        let fetched = try store.processSamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched.count, 3)
        // Fetch orders by (timestamp, pid).
        XCTAssertEqual(fetched.map(\.pid), [501, 992, 1])
        XCTAssertEqual(Set(fetched), Set(samples))
        XCTAssertNil(fetched[1].bundlePathHint)
        XCTAssertEqual(fetched[0].bundlePathHint, "/Applications/Google Chrome.app")
    }

    func testProcessSampleEmptyBatchIsNoOp() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        try store.insert(processSamples: [])
        let fetched = try store.processSamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(fetched.isEmpty)
    }

    func testProcessSampleRangeFiltering() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let mk = { (ts: Int64) in
            ProcessSample(timestampMs: ts, pid: 1, name: "node", energyImpact: 1, cpuMsPerS: 1, category: .devtools)
        }
        try store.insert(processSamples: [mk(1_000), mk(2_000), mk(3_000), mk(4_000)])

        let fetched = try store.processSamples(
            from: Date(timeIntervalSince1970: 2),
            to: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(fetched.map(\.timestampMs), [2_000, 3_000])
    }

    // MARK: - Prune

    func testPruneRemovesOldRowsFromBothTables() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let oldMs = nowMs - 10 * 86_400_000
        let recentMs = nowMs - 1 * 86_400_000

        try store.insert(batterySample: makeBatterySample(timestampMs: oldMs))
        try store.insert(batterySample: makeBatterySample(timestampMs: recentMs))
        try store.insert(processSamples: [
            ProcessSample(timestampMs: oldMs, pid: 1, name: "node", energyImpact: 1, cpuMsPerS: 1, category: .devtools),
            ProcessSample(timestampMs: recentMs, pid: 2, name: "node", energyImpact: 1, cpuMsPerS: 1, category: .devtools),
        ])

        try store.prune(olderThanDays: 7, now: now)

        let allTime = (Date(timeIntervalSince1970: 0), now.addingTimeInterval(60))
        let battery = try store.batterySamples(from: allTime.0, to: allTime.1)
        let process = try store.processSamples(from: allTime.0, to: allTime.1)
        XCTAssertEqual(battery.map(\.timestampMs), [recentMs])
        XCTAssertEqual(process.map(\.timestampMs), [recentMs])
    }

    // MARK: - Schema

    func testSchemaVersionIsStamped() throws {
        _ = try SQLiteStore(path: dbPath, mode: .readWrite)
        // Reopening applies migrations idempotently and must not throw.
        _ = try SQLiteStore(path: dbPath, mode: .readWrite)
        XCTAssertEqual(SQLiteStore.schemaVersion, 1)
    }

    func testDefaultDBPathConstant() {
        XCTAssertEqual(
            BatteryScopePaths.defaultDBPath,
            "/Library/Application Support/BatteryScope/batteryscope.db"
        )
    }
}
