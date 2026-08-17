import SQLite3
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

    /// The shape that broke in practice: the daemon writes, shuts down
    /// cleanly (WAL checkpointed away, `-wal`/`-shm` gone), and the app then
    /// opens the database read-only from a process that cannot write to the
    /// containing directory — exactly `/Library/Application Support/
    /// BatteryScope` at mode 0755 root:wheel for a non-root reader. A plain
    /// `SQLITE_OPEN_READONLY` open fails there with `SQLITE_CANTOPEN`
    /// because the read-only WAL path still probes for a `-shm` file it has
    /// no permission to create; `SQLiteStore` must fall back to the
    /// `immutable=1` URI form and still return every row.
    func testReadOnlyOpenSucceedsAfterCleanCloseInAnUnwritableDirectory() throws {
        var writer: SQLiteStore? = try SQLiteStore(path: dbPath, mode: .readWrite)
        let sample = makeBatterySample(timestampMs: 1_000)
        try writer?.insert(batterySample: sample)
        writer = nil // deinit closes the connection, checkpointing the WAL.

        // Force the exact on-disk shape regardless of whether this SQLite
        // build already cleaned these up on close: no WAL/SHM siblings left.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }

        XCTAssertEqual(chmod(tempDir.path, 0o555), 0, "failed to lock down the fixture directory")
        // Restore write access unconditionally so tearDown can remove tempDir.
        defer { chmod(tempDir.path, 0o755) }

        let reader = try SQLiteStore(path: dbPath, mode: .readOnly)
        let fetched = try reader.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched, [sample])
    }

    /// Same fallback, but against a path with the sharper edges: `?` and `#`
    /// are legal in a macOS filename but have syntactic meaning inside a
    /// sqlite `file:` URI if left unescaped (a bare `?` would truncate the
    /// path there; a bare `#` would start a fragment) — either would break
    /// the immutable-URI fallback silently instead of loudly. The real
    /// system path already has two spaces (".../Application Support/..."),
    /// which this also re-covers alongside the sharper characters.
    func testReadOnlyOpenFallbackHandlesSpacesQuestionMarksAndHashesInThePath() throws {
        let trickyPath = tempDir.path + "/weird test?db#1.db"
        var writer: SQLiteStore? = try SQLiteStore(path: trickyPath, mode: .readWrite)
        let sample = makeBatterySample(timestampMs: 1_000)
        try writer?.insert(batterySample: sample)
        writer = nil

        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: trickyPath + suffix)
        }

        XCTAssertEqual(chmod(tempDir.path, 0o555), 0, "failed to lock down the fixture directory")
        defer { chmod(tempDir.path, 0o755) }

        let reader = try SQLiteStore(path: trickyPath, mode: .readOnly)
        let fetched = try reader.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(fetched, [sample])
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

    /// The app uses this to tell "the sampler daemon has never run" apart
    /// from "this window happens to be quiet", and it must answer without
    /// decoding rows: `process_samples` reaches tens of millions of rows at
    /// full retention, so the range-fetch-and-check-isEmpty version of this
    /// question could hang the app.
    func testHasAnyProcessSamples() throws {
        let store = try SQLiteStore(path: dbPath, mode: .readWrite)
        XCTAssertFalse(try store.hasAnyProcessSamples())

        // A battery sample alone is not a process sample: an unprivileged
        // `batteryscoped` run writes the former and never the latter, which
        // is exactly the state this predicate has to detect.
        try store.insert(batterySample: makeBatterySample(timestampMs: 1_000))
        XCTAssertFalse(try store.hasAnyProcessSamples())

        try store.insert(processSamples: [
            ProcessSample(timestampMs: 1_000, pid: 1, name: "node", energyImpact: 1, cpuMsPerS: 1, category: .devtools)
        ])
        XCTAssertTrue(try store.hasAnyProcessSamples())

        // Answers for a read-only reader too — that is the app's own mode.
        let reader = try SQLiteStore(path: dbPath, mode: .readOnly)
        XCTAssertTrue(try reader.hasAnyProcessSamples())
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
        XCTAssertEqual(SQLiteStore.schemaVersion, 6)
    }

    func testDefaultDBPathConstant() {
        XCTAssertEqual(
            BatteryScopePaths.defaultDBPath,
            "/Library/Application Support/BatteryScope/batteryscope.db"
        )
    }

    // MARK: - v1 -> v2 migration

    /// Hand-builds a v1-shaped `battery_samples` table (no raw mAh columns,
    /// `user_version` left at 1) the way a database written before this
    /// change would look on disk, so the migration path can be exercised
    /// without depending on the app's own v1 schema staying reachable.
    private func createV1Database(at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db = handle else {
            // A broken fixture must fail loudly, not skip: this is the exact
            // migration path the user's live database has to survive, so a
            // silently-skipped test here is worse than no test at all.
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate handle"
            if let handle { sqlite3_close_v2(handle) }
            XCTFail("could not open a raw sqlite3 handle for the v1 fixture at \(path) (code \(rc)): \(message)")
            throw SQLiteStoreError.openFailed(path: path, code: rc, message: message)
        }
        defer { sqlite3_close_v2(db) }

        func run(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        run("""
            CREATE TABLE battery_samples (
                timestamp_ms     INTEGER PRIMARY KEY,
                percent          REAL    NOT NULL,
                is_charging      INTEGER NOT NULL,
                external_power   INTEGER NOT NULL,
                watts_drawn      REAL    NOT NULL,
                voltage_mv       INTEGER NOT NULL,
                amperage_ma      INTEGER NOT NULL,
                cycle_count      INTEGER NOT NULL,
                max_capacity_pct REAL    NOT NULL,
                temperature_c    REAL
            )
            """)
        run("""
            CREATE TABLE process_samples (
                timestamp_ms     INTEGER NOT NULL,
                pid              INTEGER NOT NULL,
                name             TEXT    NOT NULL,
                bundle_path_hint TEXT,
                category         TEXT    NOT NULL,
                energy_impact    REAL    NOT NULL,
                cpu_ms_per_s     REAL    NOT NULL
            )
            """)
        run("""
            INSERT INTO battery_samples
                (timestamp_ms, percent, is_charging, external_power, watts_drawn,
                 voltage_mv, amperage_ma, cycle_count, max_capacity_pct, temperature_c)
            VALUES (1000, 52, 0, 0, -7.42, 12600, -589, 312, 91.3, 31.2)
            """)
        run("PRAGMA user_version = 1")
    }

    func testMigrationAddsRawCapacityColumnsAndPreservesV1Rows() throws {
        try createV1Database(at: dbPath)

        let store = try SQLiteStore(path: dbPath, mode: .readWrite)

        // The pre-existing v1 row survived, and its new columns are NULL.
        let rows = try store.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].timestampMs, 1000)
        XCTAssertEqual(rows[0].percent, 52)
        XCTAssertNil(rows[0].rawCurrentMah)
        XCTAssertNil(rows[0].rawMaxMah)

        // A fresh insert round-trips both new fields.
        let sample = makeBatterySample(timestampMs: 2000)
        var withRaw = sample
        withRaw.rawCurrentMah = 4000
        withRaw.rawMaxMah = 8033
        try store.insert(batterySample: withRaw)

        let fetched = try store.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        let inserted = try XCTUnwrap(fetched.first { $0.timestampMs == 2000 })
        XCTAssertEqual(inserted.rawCurrentMah, 4000)
        XCTAssertEqual(inserted.rawMaxMah, 8033)

        // Re-opening (migration re-run) is idempotent: no throw, same data.
        let reopened = try SQLiteStore(path: dbPath, mode: .readWrite)
        let reopenedRows = try reopened.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(reopenedRows.count, 2)
    }

    func testReadOnlyOpenOfV1DatabaseDoesNotThrow() throws {
        try createV1Database(at: dbPath)

        // No migration runs on a .readOnly open, so the columns genuinely
        // are not there yet — the store must still read the row cleanly.
        let store = try SQLiteStore(path: dbPath, mode: .readOnly)
        let rows = try store.batterySamples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].rawCurrentMah)
        XCTAssertNil(rows[0].rawMaxMah)
    }
}
