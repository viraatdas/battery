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

    /// True when this failure carries SQLite's `SQLITE_CANTOPEN` (14) —
    /// the code `SQLiteStore.init` looks for to decide whether the
    /// immutable-URI read-only fallback applies.
    var isCantOpen: Bool {
        if case .openFailed(_, let code, _) = self {
            return code == SQLITE_CANTOPEN
        }
        return false
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
    ///
    /// v2 adds `raw_current_mah`/`raw_max_mah` to `battery_samples` for the
    /// high-resolution charge signal (see `BatterySample.preciseCharge`).
    /// Both columns are nullable so v1 rows migrate in with no data loss.
    ///
    /// v3 adds the stall-diagnosis signals: `ppid`/`resident_bytes` on
    /// `process_samples` (nullable, so pre-v3 rows keep their meaning — they
    /// genuinely did not record ancestry or memory) and a new
    /// `pressure_samples` table for machine-wide memory/CPU/thermal pressure.
    ///
    /// v4 adds `agent_samples`: the members of coding-agent process trees,
    /// sampled from the process table rather than from powermetrics. It is a
    /// separate table because it is collected on a different privilege level —
    /// no root needed — and answers a different question than
    /// `process_samples`, which stays the source of truth for energy.
    ///
    /// v5 generalises that table into `tracked_samples`: still the agent trees,
    /// plus the machine's heaviest processes by memory, CPU, and disk whether
    /// or not they belong to an agent. Recording only agents meant a stall
    /// caused by anything else — Spotlight, Time Machine, a runaway browser —
    /// was recorded with no culprit at all. Adds per-process disk rates, and
    /// widens `pressure_samples` with monotonic uptime, system-wide disk
    /// counters, and the sampler's intended cadence.
    ///
    /// v6 adds `sampler_start_uptime` to `pressure_samples`, identifying which
    /// sampler *run* wrote each row. Without it a sampler that was simply not
    /// running is indistinguishable from one the machine was too busy to
    /// schedule, and every restart reported as a stall.
    ///
    /// v7 adds `working_directory` to `tracked_samples`, which is what names a
    /// terminal tab — "Ghostty is using 40%" is useless with eight tabs open.
    public static let schemaVersion: Int32 = 7

    private let db: OpaquePointer
    private let lock = NSLock()
    /// Whether `battery_samples` currently has the v2 `raw_current_mah`/
    /// `raw_max_mah` columns. Detected at open time (not assumed from
    /// `schemaVersion`) so a `.readOnly` open of an old v1 file — which never
    /// runs `migrateIfNeeded` — reads the old, narrower row shape instead of
    /// throwing on missing columns.
    private var hasRawCapacityColumns = false
    /// Whether `process_samples` currently has the v3 `ppid`/`resident_bytes`
    /// columns. Detected at open time for the same reason as
    /// `hasRawCapacityColumns`: a `.readOnly` open of a v1/v2 file never runs
    /// `migrateIfNeeded`, and selecting a column that is not there is an error
    /// rather than a null.
    private var hasProcessAncestryColumns = false
    /// Whether the `pressure_samples` table exists on disk. Same rationale:
    /// against an older database the stall queries must return nothing, not
    /// throw "no such table".
    private var hasPressureTable = false
    /// Whether the v5 `tracked_samples` table exists on disk.
    private var hasTrackedTable = false
    /// Whether `tracked_samples` has the v7 `working_directory` column.
    private var hasWorkingDirectoryColumn = false
    /// Whether `pressure_samples` has the v5 uptime/disk/interval columns.
    private var hasPressureDetailColumns = false
    /// Whether `pressure_samples` has the v6 `sampler_start_uptime` column.
    private var hasSamplerRunColumn = false

    // Destructor telling SQLite to copy bound text immediately.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, mode: Mode) throws {
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

        let opened: OpaquePointer
        do {
            opened = try Self.openAndVerify(path, flags: flags)
        } catch let error as SQLiteStoreError {
            // A WAL-mode database whose writer shut down cleanly has no
            // -wal/-shm files left (SQLite checkpoints them into the main
            // file on close). Re-opening that file read-only from a process
            // that cannot write to its directory — the app/CLI against the
            // daemon's root-owned /Library/Application Support/BatteryScope,
            // mode 0755 — still fails with SQLITE_CANTOPEN: the read-only WAL
            // path probes for a -shm file it has no permission to create.
            // `sqlite3_open_v2` itself almost never surfaces this — SQLite
            // defers the real file access until the first statement, which is
            // why `openAndVerify` forces that access instead of trusting the
            // open call's return code. Retrying once via the URI form with
            // `immutable=1` tells SQLite the file is static and skips the
            // probe entirely, which is safe because the checkpoint already
            // happened. This is deliberately a fallback, never the first
            // attempt: while the daemon is running (or just left -wal/-shm
            // files behind) the plain open above already succeeds and sees
            // every write, exactly as it does today.
            guard mode == .readOnly, error.isCantOpen, let uri = Self.readOnlyImmutableURI(forPath: path) else {
                throw error
            }
            opened = try Self.openAndVerify(
                uri,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            )
        }
        self.db = opened

        do {
            if mode == .readWrite {
                try exec("PRAGMA journal_mode = WAL")
                try exec("PRAGMA synchronous = NORMAL")
                try migrateIfNeeded()
                // Make the DB readable by non-root clients (daemon runs as root).
                chmod(path, 0o644)
            }
            // Read the actual on-disk shape rather than trusting schemaVersion:
            // a .readOnly open never migrates, so an old v1 file legitimately
            // lacks the v2 columns even though this binary knows about them.
            hasRawCapacityColumns = try detectRawCapacityColumns()
            let processColumns = try columnNames(of: "process_samples")
            hasProcessAncestryColumns =
                processColumns.contains("ppid") && processColumns.contains("resident_bytes")
            hasPressureTable = try !columnNames(of: "pressure_samples").isEmpty
            let trackedColumns = try columnNames(of: "tracked_samples")
            hasTrackedTable = !trackedColumns.isEmpty
            hasWorkingDirectoryColumn = trackedColumns.contains("working_directory")
            let pressureColumns = try columnNames(of: "pressure_samples")
            hasPressureDetailColumns = pressureColumns
                .isSuperset(of: ["uptime_seconds", "disk_read_bytes", "disk_write_bytes", "interval_seconds"])
            hasSamplerRunColumn = pressureColumns
                .isSuperset(of: ["sampler_start_uptime", "cpu_ticks_used", "cpu_ticks_idle"])
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    /// Opens `pathOrURI` and immediately forces the lazy VFS open SQLite
    /// otherwise defers until the first statement that actually touches a
    /// page. `sqlite3_open_v2` alone almost never fails — even for a file
    /// this process cannot really read — so `init` cannot tell a broken
    /// read-only open from a working one just from its return code.
    ///
    /// The probe has to be `PRAGMA schema_version`, not `PRAGMA
    /// busy_timeout`: `busy_timeout` is a purely connection-local setting
    /// that never reads the database file, so it sails through silently even
    /// against a directory this process cannot write to — confirmed by hand
    /// against exactly that broken-directory case. `schema_version` reads
    /// page 1, which is what actually forces the real access and lets a
    /// genuine `SQLITE_CANTOPEN` surface here, in time for `init` to retry
    /// with the immutable URI form instead of failing outright.
    private static func openAndVerify(_ pathOrURI: String, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(pathOrURI, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate handle"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteStoreError.openFailed(path: pathOrURI, code: rc, message: message)
        }
        guard sqlite3_exec(opened, "PRAGMA schema_version", nil, nil, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(opened)
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close_v2(opened)
            throw SQLiteStoreError.openFailed(path: pathOrURI, code: code, message: message)
        }
        guard sqlite3_exec(opened, "PRAGMA busy_timeout = 3000", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(opened))
            sqlite3_close_v2(opened)
            throw SQLiteStoreError.execFailed(sql: "PRAGMA busy_timeout = 3000", message: message)
        }
        return opened
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
                        temperature_c    REAL,
                        raw_current_mah  REAL,
                        raw_max_mah      REAL
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
            if version < 2 {
                // A pre-v2 database already has battery_samples but without the
                // raw mAh columns; a fresh v1-or-later CREATE above already has
                // them, so this is a no-op there. Checked via table_info rather
                // than assumed, so re-running the migration (e.g. two processes
                // racing to open the same file) stays idempotent.
                try addColumnIfMissing(table: "battery_samples", column: "raw_current_mah", type: "REAL")
                try addColumnIfMissing(table: "battery_samples", column: "raw_max_mah", type: "REAL")
            }
            if version < 3 {
                // Nullable on purpose, and never backfilled: a pre-v3 row did
                // not record ancestry or memory, and inventing a zero there
                // would make an unmeasured process look like an idle one.
                try addColumnIfMissing(table: "process_samples", column: "ppid", type: "INTEGER")
                try addColumnIfMissing(table: "process_samples", column: "resident_bytes", type: "INTEGER")
                try exec("""
                    CREATE TABLE IF NOT EXISTS pressure_samples (
                        timestamp_ms      INTEGER PRIMARY KEY,
                        memory_level      TEXT    NOT NULL,
                        thermal_level     TEXT    NOT NULL,
                        total_memory      INTEGER NOT NULL,
                        available_memory  INTEGER NOT NULL,
                        compressed_bytes  INTEGER NOT NULL,
                        swap_used_bytes   INTEGER NOT NULL,
                        page_ins          INTEGER NOT NULL,
                        load_average_1m   REAL    NOT NULL,
                        cpu_count         INTEGER NOT NULL
                    )
                    """)
            }
            if version < 4 {
                try exec("""
                    CREATE TABLE IF NOT EXISTS agent_samples (
                        timestamp_ms   INTEGER NOT NULL,
                        pid            INTEGER NOT NULL,
                        ppid           INTEGER NOT NULL,
                        name           TEXT    NOT NULL,
                        category       TEXT    NOT NULL,
                        resident_bytes INTEGER,
                        cpu_ms_per_s   REAL    NOT NULL
                    )
                    """)
                try exec("CREATE INDEX IF NOT EXISTS idx_agent_samples_ts ON agent_samples(timestamp_ms)")
            }
            if version < 5 {
                try exec("""
                    CREATE TABLE IF NOT EXISTS tracked_samples (
                        timestamp_ms      INTEGER NOT NULL,
                        pid               INTEGER NOT NULL,
                        ppid              INTEGER NOT NULL,
                        name              TEXT    NOT NULL,
                        category          TEXT    NOT NULL,
                        resident_bytes    INTEGER,
                        cpu_ms_per_s      REAL    NOT NULL,
                        disk_read_bps     REAL,
                        disk_write_bps    REAL
                    )
                    """)
                try exec("CREATE INDEX IF NOT EXISTS idx_tracked_samples_ts ON tracked_samples(timestamp_ms)")
                // Carry over anything a v4 sampler already collected: it is the
                // same shape, minus the disk columns that did not exist yet.
                if try !columnNames(of: "agent_samples").isEmpty {
                    try exec("""
                        INSERT INTO tracked_samples
                            (timestamp_ms, pid, ppid, name, category, resident_bytes, cpu_ms_per_s)
                        SELECT timestamp_ms, pid, ppid, name, category, resident_bytes, cpu_ms_per_s
                        FROM agent_samples
                        """)
                    try exec("DROP TABLE agent_samples")
                }
                for column in ["uptime_seconds", "disk_read_bytes", "disk_write_bytes", "interval_seconds"] {
                    try addColumnIfMissing(table: "pressure_samples", column: column, type: "REAL")
                }
            }
            if version < 6 {
                for column in ["sampler_start_uptime", "cpu_ticks_used", "cpu_ticks_idle"] {
                    try addColumnIfMissing(table: "pressure_samples", column: column, type: "REAL")
                }
            }
            if version < 7 {
                try addColumnIfMissing(
                    table: "tracked_samples", column: "working_directory", type: "TEXT"
                )
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

    /// Column names currently on `table`, via `PRAGMA table_info`. Works even
    /// when `table` does not exist (yields zero rows rather than an error).
    private func columnNames(of table: String) throws -> Set<String> {
        // `table` is always one of our own hard-coded table names, never
        // user input, so string interpolation into the pragma is safe —
        // PRAGMA statements do not support `?` parameter binding for
        // identifiers anyway.
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: name))
            }
        }
        return names
    }

    private func addColumnIfMissing(table: String, column: String, type: String) throws {
        guard try !columnNames(of: table).contains(column) else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }

    private func detectRawCapacityColumns() throws -> Bool {
        let columns = try columnNames(of: "battery_samples")
        return columns.contains("raw_current_mah") && columns.contains("raw_max_mah")
    }

    // MARK: - Writes

    public func insert(batterySample sample: BatterySample) throws {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT OR REPLACE INTO battery_samples
                (timestamp_ms, percent, is_charging, external_power, watts_drawn,
                 voltage_mv, amperage_ma, cycle_count, max_capacity_pct, temperature_c,
                 raw_current_mah, raw_max_mah)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        if let rawCurrentMah = sample.rawCurrentMah {
            sqlite3_bind_double(statement, 11, rawCurrentMah)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        if let rawMaxMah = sample.rawMaxMah {
            sqlite3_bind_double(statement, 12, rawMaxMah)
        } else {
            sqlite3_bind_null(statement, 12)
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

        // A `.readWrite` open always migrates, so the v3 columns are present
        // here; the flag is still consulted rather than assumed, because an
        // INSERT naming a missing column fails the whole batch and this daemon
        // is expected to keep collecting through surprises.
        let ancestryColumns = hasProcessAncestryColumns ? ", ppid, resident_bytes" : ""
        let ancestryPlaceholders = hasProcessAncestryColumns ? ", ?, ?" : ""
        let sql = """
            INSERT INTO process_samples
                (timestamp_ms, pid, name, bundle_path_hint, category, energy_impact, cpu_ms_per_s\(ancestryColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?\(ancestryPlaceholders))
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
                if hasProcessAncestryColumns {
                    if let ppid = sample.ppid {
                        sqlite3_bind_int64(statement, 8, Int64(ppid))
                    } else {
                        sqlite3_bind_null(statement, 8)
                    }
                    if let residentBytes = sample.residentBytes {
                        sqlite3_bind_int64(statement, 9, residentBytes)
                    } else {
                        sqlite3_bind_null(statement, 9)
                    }
                }

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

    /// Inserts a batch of tracked-process samples in one transaction.
    ///
    /// Silently does nothing against a pre-v5 database, matching the rest of
    /// the store: an old file collects less, it does not fail.
    public func insert(trackedSamples samples: [ProcessSample]) throws {
        guard hasTrackedTable, !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let directoryColumn = hasWorkingDirectoryColumn ? ", working_directory" : ""
        let directoryPlaceholder = hasWorkingDirectoryColumn ? ", ?" : ""
        let sql = """
            INSERT INTO tracked_samples
                (timestamp_ms, pid, ppid, name, category, resident_bytes, cpu_ms_per_s,
                 disk_read_bps, disk_write_bps\(directoryColumn))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?\(directoryPlaceholder))
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
                sqlite3_bind_int64(statement, 3, Int64(sample.ppid ?? 0))
                sqlite3_bind_text(statement, 4, sample.name, -1, Self.transientDestructor)
                sqlite3_bind_text(statement, 5, sample.category.rawValue, -1, Self.transientDestructor)
                bind(statement, 6, sample.residentBytes)
                sqlite3_bind_double(statement, 7, sample.cpuMsPerS)
                bind(statement, 8, sample.diskReadBytesPerS)
                bind(statement, 9, sample.diskWriteBytesPerS)
                if hasWorkingDirectoryColumn {
                    if let directory = sample.workingDirectory {
                        sqlite3_bind_text(statement, 10, directory, -1, Self.transientDestructor)
                    } else {
                        sqlite3_bind_null(statement, 10)
                    }
                }

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

    /// Tracked-process samples in `[from, to]`, ascending. Empty against a
    /// database with no `tracked_samples` table.
    public func trackedSamples(from: Date, to: Date) throws -> [ProcessSample] {
        guard hasTrackedTable else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let directoryColumn = hasWorkingDirectoryColumn ? ", working_directory" : ""
        let sql = """
            SELECT timestamp_ms, pid, ppid, name, category, resident_bytes, cpu_ms_per_s,
                   disk_read_bps, disk_write_bps\(directoryColumn)
            FROM tracked_samples
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
            let name = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let categoryRaw = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            results.append(ProcessSample(
                timestampMs: sqlite3_column_int64(statement, 0),
                pid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
                name: name,
                energyImpact: 0,
                cpuMsPerS: sqlite3_column_double(statement, 6),
                category: ProcessCategory(rawValue: categoryRaw) ?? .other,
                ppid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 2)),
                residentBytes: sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 5),
                diskReadBytesPerS: sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 7),
                diskWriteBytesPerS: sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 8),
                workingDirectory: hasWorkingDirectoryColumn
                    ? sqlite3_column_text(statement, 9).map { String(cString: $0) } : nil
            ))
        }
        return results
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    /// Inserts one machine-wide pressure reading.
    ///
    /// `INSERT OR REPLACE` on the timestamp primary key, matching
    /// `battery_samples`: a re-run tick for the same instant corrects the row
    /// rather than doubling it.
    public func insert(pressureSample sample: PressureSample) throws {
        guard hasPressureTable else { return }
        lock.lock()
        defer { lock.unlock() }

        var detailColumns = hasPressureDetailColumns
            ? ", uptime_seconds, disk_read_bytes, disk_write_bytes, interval_seconds" : ""
        var detailPlaceholders = hasPressureDetailColumns ? ", ?, ?, ?, ?" : ""
        if hasSamplerRunColumn {
            detailColumns += ", sampler_start_uptime, cpu_ticks_used, cpu_ticks_idle"
            detailPlaceholders += ", ?, ?, ?"
        }
        let sql = """
            INSERT OR REPLACE INTO pressure_samples
                (timestamp_ms, memory_level, thermal_level, total_memory, available_memory,
                 compressed_bytes, swap_used_bytes, page_ins, load_average_1m, cpu_count\(detailColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?\(detailPlaceholders))
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sample.timestampMs)
        sqlite3_bind_text(statement, 2, sample.memoryLevel.rawValue, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 3, sample.thermalLevel.rawValue, -1, Self.transientDestructor)
        sqlite3_bind_int64(statement, 4, sample.totalMemoryBytes)
        sqlite3_bind_int64(statement, 5, sample.availableMemoryBytes)
        sqlite3_bind_int64(statement, 6, sample.compressedBytes)
        sqlite3_bind_int64(statement, 7, sample.swapUsedBytes)
        sqlite3_bind_int64(statement, 8, sample.pageIns)
        sqlite3_bind_double(statement, 9, sample.loadAverage1m)
        sqlite3_bind_int64(statement, 10, Int64(sample.cpuCount))
        if hasPressureDetailColumns {
            sqlite3_bind_double(statement, 11, sample.uptimeSeconds)
            sqlite3_bind_double(statement, 12, Double(sample.diskReadBytes))
            sqlite3_bind_double(statement, 13, Double(sample.diskWriteBytes))
            sqlite3_bind_double(statement, 14, sample.intervalSeconds)
        }
        if hasSamplerRunColumn {
            let base: Int32 = hasPressureDetailColumns ? 15 : 11
            sqlite3_bind_double(statement, base, sample.samplerStartUptime)
            sqlite3_bind_double(statement, base + 1, Double(sample.cpuTicksUsed))
            sqlite3_bind_double(statement, base + 2, Double(sample.cpuTicksIdle))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
        }
    }

    /// Deletes all samples older than the given number of days (relative to `now`).
    public func prune(olderThanDays days: Int, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
        var tables = ["battery_samples", "process_samples"]
        if hasPressureTable { tables.append("pressure_samples") }
        if hasTrackedTable { tables.append("tracked_samples") }
        for table in tables {
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

        // Column list depends on what this file actually has on disk: a
        // `.readOnly` open of a pre-migration v1 file never runs
        // `migrateIfNeeded`, so selecting raw_current_mah/raw_max_mah there
        // would fail with "no such column" instead of just yielding nils.
        let rawColumns = hasRawCapacityColumns ? ", raw_current_mah, raw_max_mah" : ""
        let sql = """
            SELECT timestamp_ms, percent, is_charging, external_power, watts_drawn,
                   voltage_mv, amperage_ma, cycle_count, max_capacity_pct, temperature_c\(rawColumns)
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
            var rawCurrentMah: Double?
            var rawMaxMah: Double?
            if hasRawCapacityColumns {
                rawCurrentMah = sqlite3_column_type(statement, 10) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 10)
                rawMaxMah = sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 11)
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
                temperatureC: temperature,
                rawCurrentMah: rawCurrentMah,
                rawMaxMah: rawMaxMah
            ))
        }
        return results
    }

    /// Whether the database holds any process sample at all, at any time.
    ///
    /// Exists so a caller can tell "the sampler daemon has never run" apart
    /// from "nothing used power in the window I asked about" without paying
    /// for the rows. `process_samples` is by far the larger table — one row
    /// per process per tick, and `PowermetricsParser` filters nothing, so at
    /// the 30s default interval with ~700 live processes and 30-day retention
    /// it reaches tens of millions of rows. Answering this question with a
    /// range fetch would decode all of them; `LIMIT 1` stops at the first.
    public func hasAnyProcessSamples() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT 1 FROM process_samples LIMIT 1"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
        }
    }

    /// Process samples with `from.timestampMs <= t <= to.timestampMs`, ascending by time then pid.
    public func processSamples(from: Date, to: Date) throws -> [ProcessSample] {
        lock.lock()
        defer { lock.unlock() }

        let ancestryColumns = hasProcessAncestryColumns ? ", ppid, resident_bytes" : ""
        let sql = """
            SELECT timestamp_ms, pid, name, bundle_path_hint, category, energy_impact, cpu_ms_per_s\(ancestryColumns)
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
            var ppid: Int32?
            var residentBytes: Int64?
            if hasProcessAncestryColumns {
                if sqlite3_column_type(statement, 7) != SQLITE_NULL {
                    ppid = Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 7))
                }
                if sqlite3_column_type(statement, 8) != SQLITE_NULL {
                    residentBytes = sqlite3_column_int64(statement, 8)
                }
            }
            results.append(ProcessSample(
                timestampMs: sqlite3_column_int64(statement, 0),
                pid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
                name: name,
                bundlePathHint: hint,
                energyImpact: sqlite3_column_double(statement, 5),
                cpuMsPerS: sqlite3_column_double(statement, 6),
                category: ProcessCategory(rawValue: categoryRaw) ?? .other,
                ppid: ppid,
                residentBytes: residentBytes
            ))
        }
        return results
    }

    /// Pressure samples with `from.timestampMs <= t <= to.timestampMs`, ascending.
    ///
    /// Returns an empty array — never throws — against a pre-v3 database that
    /// has no `pressure_samples` table at all, so an app built against the new
    /// schema still runs over an old daemon's file.
    public func pressureSamples(from: Date, to: Date) throws -> [PressureSample] {
        guard hasPressureTable else { return [] }
        lock.lock()
        defer { lock.unlock() }

        var detailColumns = hasPressureDetailColumns
            ? ", uptime_seconds, disk_read_bytes, disk_write_bytes, interval_seconds" : ""
        if hasSamplerRunColumn {
            detailColumns += ", sampler_start_uptime, cpu_ticks_used, cpu_ticks_idle"
        }
        let sql = """
            SELECT timestamp_ms, memory_level, thermal_level, total_memory, available_memory,
                   compressed_bytes, swap_used_bytes, page_ins, load_average_1m, cpu_count\(detailColumns)
            FROM pressure_samples
            WHERE timestamp_ms >= ? AND timestamp_ms <= ?
            ORDER BY timestamp_ms ASC
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.millis(from))
        sqlite3_bind_int64(statement, 2, Self.millis(to))

        var results: [PressureSample] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteStoreError.stepFailed(sql: sql, message: errorMessage())
            }
            let memoryRaw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let thermalRaw = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            results.append(PressureSample(
                timestampMs: sqlite3_column_int64(statement, 0),
                memoryLevel: PressureLevel(rawValue: memoryRaw) ?? .nominal,
                thermalLevel: PressureLevel(rawValue: thermalRaw) ?? .nominal,
                totalMemoryBytes: sqlite3_column_int64(statement, 3),
                availableMemoryBytes: sqlite3_column_int64(statement, 4),
                compressedBytes: sqlite3_column_int64(statement, 5),
                swapUsedBytes: sqlite3_column_int64(statement, 6),
                pageIns: sqlite3_column_int64(statement, 7),
                loadAverage1m: sqlite3_column_double(statement, 8),
                cpuCount: Int(sqlite3_column_int64(statement, 9)),
                uptimeSeconds: hasPressureDetailColumns ? sqlite3_column_double(statement, 10) : 0,
                diskReadBytes: hasPressureDetailColumns
                    ? Int64(sqlite3_column_double(statement, 11)) : 0,
                diskWriteBytes: hasPressureDetailColumns
                    ? Int64(sqlite3_column_double(statement, 12)) : 0,
                intervalSeconds: hasPressureDetailColumns ? sqlite3_column_double(statement, 13) : 0,
                samplerStartUptime: hasSamplerRunColumn
                    ? sqlite3_column_double(statement, hasPressureDetailColumns ? 14 : 10) : 0,
                cpuTicksUsed: hasSamplerRunColumn
                    ? Int64(sqlite3_column_double(statement, hasPressureDetailColumns ? 15 : 11)) : 0,
                cpuTicksIdle: hasSamplerRunColumn
                    ? Int64(sqlite3_column_double(statement, hasPressureDetailColumns ? 16 : 12)) : 0
            ))
        }
        return results
    }

    // MARK: - Helpers

    /// Builds a `file:` URI for `sqlite3_open_v2(..., SQLITE_OPEN_URI)` that
    /// opens `path` read-only and `immutable`, bypassing the writable-
    /// directory probe a plain read-only WAL open performs when there is no
    /// live writer. Percent-encodes per RFC 3986 (the real system path,
    /// under "Application Support", contains spaces).
    private static func readOnlyImmutableURI(forPath path: String) -> String? {
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let absolute = escaped.hasPrefix("/") ? escaped : "/" + escaped
        return "file:\(absolute)?mode=ro&immutable=1"
    }

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
