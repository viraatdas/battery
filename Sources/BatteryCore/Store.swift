import Foundation
import SQLite3

/// Well-known filesystem locations for BatteryScope.
public enum BatteryScopePaths {
    /// System-wide database written by the root daemon, readable by everyone.
    public static let defaultDBPath = "/Library/Application Support/BatteryScope/batteryscope.db"
}

public enum SQLiteStoreError: Error, CustomStringConvertible {
    case openFailed(path: String, code: Int32, message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case bindFailed(sql: String, message: String)
    case execFailed(sql: String, message: String)

    public var description: String {
        switch self {
        case .openFailed(let path, let code, let message):
            return "SQLite open failed for \(path) (code \(code)): \(message)"
        case .prepareFailed(let sql, let message):
            return "SQLite prepare failed (\(message)) for: \(sql)"
        case .stepFailed(let sql, let message):
            return "SQLite step failed (\(message)) for: \(sql)"
        case .bindFailed(let sql, let message):
            return "SQLite bind failed (\(message)) for: \(sql)"
        case .execFailed(let sql, let message):
            return "SQLite exec failed (\(message)) for: \(sql)"
        }
    }
}

/// SQLite-backed sample store over the system SQLite3 C API.
///
/// The database runs in WAL mode so a read-only client (the app/CLI) can read
/// while the daemon writes. All access on one connection is serialized with an
/// internal lock.
public final class SQLiteStore: @unchecked Sendable {

    public enum Mode: Sendable {
        /// Opens (creating file and parent directory if needed) for writing.
        case readWrite
        /// Opens an existing database read-only; throws if it does not exist.
        case readOnly
    }

    /// Current on-disk schema version, stored in `PRAGMA user_version`.
    public static let schemaVersion: Int32 = 1

    private let db: OpaquePointer
    private let lock = NSLock()

    // Destructor telling SQLite to copy bound text immediately.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, mode: Mode) throws {
        var handle: OpaquePointer?
        let flags: Int32
        switch mode {
        case .readWrite:
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }

        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate handle"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw SQLiteStoreError.openFailed(path: path, code: rc, message: message)
        }
        self.db = opened

        do {
            try exec("PRAGMA busy_timeout = 3000")
            if mode == .readWrite {
                try exec("PRAGMA journal_mode = WAL")
                try exec("PRAGMA synchronous = NORMAL")
                try migrateIfNeeded()
                // Make the DB readable by non-root clients (daemon runs as root).
                chmod(path, 0o644)
            }
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Schema

    private func migrateIfNeeded() throws {
        let version = try queryUserVersion()
        guard version < Self.schemaVersion else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            if version < 1 {
                try exec("""
                    CREATE TABLE IF NOT EXISTS battery_samples (
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
                try exec("""
                    CREATE TABLE IF NOT EXISTS process_samples (
                        timestamp_ms     INTEGER NOT NULL,
                        pid              INTEGER NOT NULL,
                        name             TEXT    NOT NULL,
                        bundle_path_hint TEXT,
                        category         TEXT    NOT NULL,
                        energy_impact    REAL    NOT NULL,
                        cpu_ms_per_s     REAL    NOT NULL
                    )
                    """)
                try exec("CREATE INDEX IF NOT EXISTS idx_process_samples_ts ON process_samples(timestamp_ms)")
                try exec("CREATE INDEX IF NOT EXISTS idx_process_samples_name_ts ON process_samples(name, timestamp_ms)")
            }
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func queryUserVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.stepFailed(sql: "PRAGMA user_version", message: errorMessage())
        }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: - Writes

    public func insert(batterySample sample: BatterySample) throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT OR REPLACE INTO battery_samples
                (timestamp_ms, percent, is_charging, external_power, watts_drawn,
                 voltage_mv, amperage_ma, cycle_count, max_capacity_pct, temperature_c)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sample.timestampMs)
        sqlite3_bind_double(statement, 2, sample.percent)
        sqlite3_bind_int(statement, 3, sample.isCharging ? 1 : 0)
        sqlite3_bind_int(statement, 4, sample.externalPower ? 1 : 0)
        sqlite3_bind_double(statement, 5, sample.wattsDrawn)
        sqlite3_bind_int64(statement, 6, Int64(sample.voltageMv))
        sqlite3_bind_int64(statement, 7, Int64(sample.amperageMa))
        sqlite3_bind_int64(statement, 8, Int64(sample.cycleCount))
        sqlite3_bind_double(statement, 9, sample.maxCapacityPct)
        if let temperature = sample.temperatureC {
            sqlite3_bind_double(statement, 10, temperature)
        } else {
            sqlite3_bind_null(statement, 10)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
        }
    }

    /// Inserts a batch of process samples inside a single transaction.
    public func insert(processSamples samples: [ProcessSample]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT INTO process_samples
                (timestamp_ms, pid, name, bundle_path_hint, category, energy_impact, cpu_ms_per_s)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try exec("BEGIN IMMEDIATE")
        do {
            for sample in samples {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, sample.timestampMs)
                sqlite3_bind_int64(statement, 2, Int64(sample.pid))
                sqlite3_bind_text(statement, 3, sample.name, -1, Self.transientDestructor)
                if let hint = sample.bundlePathHint {
                    sqlite3_bind_text(statement, 4, hint, -1, Self.transientDestructor)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                sqlite3_bind_text(statement, 5, sample.category.rawValue, -1, Self.transientDestructor)
                sqlite3_bind_double(statement, 6, sample.energyImpact)
                sqlite3_bind_double(statement, 7, sample.cpuMsPerS)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes all samples older than the given number of days (relative to `now`).
    public func prune(olderThanDays days: Int, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
        for table in ["battery_samples", "process_samples"] {
            let sql = "DELETE FROM \(table) WHERE timestamp_ms < ?"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, cutoffMs)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
            }
        }
    }

    // MARK: - Reads

    /// Battery samples with `from.timestampMs <= t <= to.timestampMs`, ascending.
    public func batterySamples(from: Date, to: Date) throws -> [BatterySample] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT timestamp_ms, percent, is_charging, external_power, watts_drawn,
                   voltage_mv, amperage_ma, cycle_count, max_capacity_pct, temperature_c
            FROM battery_samples
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
            ORDER BY timestamp_ms ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.millis(from))
        sqlite3_bind_int64(statement, 2, Self.millis(to))

        var results: [BatterySample] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
            }
            let temperature: Double?
            if sqlite3_column_type(statement, 9) == SQLITE_NULL {
                temperature = nil
            } else {
                temperature = sqlite3_column_double(statement, 9)
            }
            results.append(BatterySample(
                timestampMs: sqlite3_column_int64(statement, 0),
                percent: sqlite3_column_double(statement, 1),
                isCharging: sqlite3_column_int(statement, 2) != 0,
                externalPower: sqlite3_column_int(statement, 3) != 0,
                wattsDrawn: sqlite3_column_double(statement, 4),
                voltageMv: Int(sqlite3_column_int64(statement, 5)),
                amperageMa: Int(sqlite3_column_int64(statement, 6)),
                cycleCount: Int(sqlite3_column_int64(statement, 7)),
                maxCapacityPct: sqlite3_column_double(statement, 8),
                temperatureC: temperature
            ))
        }
        return results
    }

    /// Process samples with `from.timestampMs <= t <= to.timestampMs`, ascending by time then pid.
    public func processSamples(from: Date, to: Date) throws -> [ProcessSample] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            SELECT timestamp_ms, pid, name, bundle_path_hint, category, energy_impact, cpu_ms_per_s
            FROM process_samples
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
            ORDER BY timestamp_ms ASC, pid ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.millis(from))
        sqlite3_bind_int64(statement, 2, Self.millis(to))

        var results: [ProcessSample] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
            }
            let name = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let hint = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let categoryRaw = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            results.append(ProcessSample(
                timestampMs: sqlite3_column_int64(statement, 0),
                pid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
                name: name,
                bundlePathHint: hint,
                energyImpact: sqlite3_column_double(statement, 5),
                cpuMsPerS: sqlite3_column_double(statement, 6),
                category: ProcessCategory(rawValue: categoryRaw) ?? .other
            ))
        }
        return results
    }

    // MARK: - Helpers

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func errorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw SQLiteStoreError.prepareFailed(sql: sql, message: errorMessage())
        }
        return prepared
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.execFailed(sql: sql, message: errorMessage())
        }
    }
}
