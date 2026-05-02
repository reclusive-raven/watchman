import Foundation
import SQLite3

/// SQLite-backed writer for per-worker metric samples.
///
/// Ingestion is fire-and-forget from `MetricsPoller`. All read-side queries
/// (History aggregates, CSV export) live on `reader`, which holds a separate
/// read-only connection so a slow read can never block a 1 Hz ingest.
actor MetricStore {
    static let shared = MetricStore()

    /// Separate read path. Owns its own SQLite connection so aggregate
    /// queries don't serialize against `ingest(_:)` on this actor.
    nonisolated let reader: MetricReader

    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?

    private let dbURL: URL
    private static let retentionDays: Double = 90

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? fm.temporaryDirectory)
            .appendingPathComponent("Watchman", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("power.sqlite")
        self.dbURL = url
        // `reader` opens lazily on first use, so it's fine to construct
        // it before `openAndMigrate` has created the DB file.
        self.reader = MetricReader(dbURL: url)

        openAndMigrate()
        schedulePurge()
    }

    deinit {
        if let stmt = insertStmt { sqlite3_finalize(stmt) }
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Ingest

    func ingest(_ sample: MetricSample) {
        guard let stmt = insertStmt else { return }

        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(sample.timestamp.timeIntervalSince1970))
        sample.hostname.withCString { ptr in
            sqlite3_bind_text(stmt, 2, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        bindOptionalDouble(stmt, 3, sample.cpuW)
        bindOptionalDouble(stmt, 4, sample.gpuW)
        sqlite3_bind_double(stmt, 5, sample.cpuUsagePct)
        sqlite3_bind_double(stmt, 6, sample.gpuUsagePct)
        bindOptionalDouble(stmt, 7, sample.gpuTempC)
        bindOptionalDouble(stmt, 8, sample.cpuTempC)
        bindOptionalUInt64(stmt, 9, sample.vramUsedMb)
        bindOptionalUInt64(stmt, 10, sample.vramTotalMb)
        bindOptionalUInt64(stmt, 11, sample.memUsedMb)
        bindOptionalUInt64(stmt, 12, sample.memTotalMb)
        bindOptionalUInt64(stmt, 13, sample.diskUsedGb)
        bindOptionalUInt64(stmt, 14, sample.diskTotalGb)
        bindOptionalUInt64(stmt, 15, sample.diskReadBps)
        bindOptionalUInt64(stmt, 16, sample.diskWriteBps)
        bindOptionalUInt64(stmt, 17, sample.netRxBps)
        bindOptionalUInt64(stmt, 18, sample.netTxBps)
        sqlite3_step(stmt)
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, idx, v) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindOptionalUInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: UInt64?) {
        if let v = value { sqlite3_bind_int64(stmt, idx, Int64(bitPattern: v)) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    // MARK: - Schema

    private func openAndMigrate() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            db = nil
            return
        }
        runRaw("PRAGMA journal_mode=WAL;")
        runRaw("PRAGMA synchronous=NORMAL;")

        // Also re-enter migration when user_version claims an older schema
        // but a stray `power_samples` table is still around — early builds
        // of this feature could leave the DB in that state.
        let version = readUserVersion()
        if version < 4 || tableExists("power_samples") {
            migrate(from: version)
        }

        let insertSQL = """
        INSERT OR REPLACE INTO metric_samples
            (timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct,
             gpu_temp_c, cpu_temp_c, vram_used_mb, vram_total_mb,
             mem_used_mb, mem_total_mb, disk_used_gb, disk_total_gb,
             disk_read_bps, disk_write_bps, net_rx_bps, net_tx_bps)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)
    }

    private func readUserVersion() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Brings the DB to the current version (v4) regardless of the previous
    /// state. Driven by table presence rather than `user_version` alone, so
    /// we can recover from an earlier buggy migration that created an empty
    /// `metric_samples` next to the legacy `power_samples` table without
    /// merging them.
    private func migrate(from version: Int) {
        runRaw("BEGIN;")
        defer { runRaw("COMMIT;") }

        let legacy = tableExists("power_samples")
        let modern = tableExists("metric_samples")

        if legacy && modern {
            // Recovery path: merge legacy rows into the new table (using
            // NULL for the new columns) and drop the legacy table. Stale
            // rows already present in `metric_samples` are preserved via
            // INSERT OR IGNORE, since (hostname, timestamp) is the key.
            runRaw("""
            INSERT OR IGNORE INTO metric_samples
                (timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct)
            SELECT timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct
            FROM power_samples;
            """)
            runRaw("DROP TABLE power_samples;")
        } else if legacy {
            // v1 upgrade: rename the table, then add the new columns.
            runRaw("ALTER TABLE power_samples RENAME TO metric_samples;")
        } else if !modern {
            // Fresh install.
            runRaw("""
            CREATE TABLE metric_samples (
                timestamp      INTEGER NOT NULL,
                hostname       TEXT    NOT NULL,
                cpu_w          REAL,
                gpu_w          REAL,
                cpu_pct        REAL    NOT NULL,
                gpu_pct        REAL    NOT NULL,
                gpu_temp_c     REAL,
                cpu_temp_c     REAL,
                vram_used_mb   INTEGER,
                vram_total_mb  INTEGER,
                mem_used_mb    INTEGER,
                mem_total_mb   INTEGER,
                disk_used_gb   INTEGER,
                disk_total_gb  INTEGER,
                disk_read_bps  INTEGER,
                disk_write_bps INTEGER,
                net_rx_bps     INTEGER,
                net_tx_bps     INTEGER,
                PRIMARY KEY (hostname, timestamp)
            );
            """)
        }

        // ADD COLUMN on an already-present column is a no-op here because
        // runRaw swallows the error. Safe to call on every migration path.
        for col in [
            "gpu_temp_c     REAL",
            "cpu_temp_c     REAL",
            "vram_used_mb   INTEGER",
            "vram_total_mb  INTEGER",
            "mem_used_mb    INTEGER",
            "mem_total_mb   INTEGER",
            "disk_used_gb   INTEGER",
            "disk_total_gb  INTEGER",
            "disk_read_bps  INTEGER",
            "disk_write_bps INTEGER",
            "net_rx_bps     INTEGER",
            "net_tx_bps     INTEGER",
        ] {
            runRaw("ALTER TABLE metric_samples ADD COLUMN \(col);")
        }

        runRaw("DROP INDEX IF EXISTS idx_host_ts;")
        runRaw("CREATE INDEX IF NOT EXISTS idx_host_ts ON metric_samples(hostname, timestamp);")
        // idx_ts covers the "All workers" History queries (`WHERE timestamp >= ?`
        // with no hostname predicate), which can't use the composite index
        // above because its leading column is unconstrained.
        runRaw("CREATE INDEX IF NOT EXISTS idx_ts ON metric_samples(timestamp);")
        runRaw("PRAGMA user_version = 4;")
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        name.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func runRaw(_ sql: String) {
        guard let db = db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func schedulePurge() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                await self?.purgeOldSamples()
            }
        }
    }

    private func purgeOldSamples() {
        guard let db = db else { return }
        let cutoff = Int64(
            Date().addingTimeInterval(-Self.retentionDays * 86400).timeIntervalSince1970
        )
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "DELETE FROM metric_samples WHERE timestamp < ?;", -1, &stmt, nil
        ) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
