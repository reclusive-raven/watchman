import Foundation
import SQLite3

/// Read-only view over the Watchman metrics DB. Owns its own SQLite
/// connection so aggregation queries (and large CSV exports) never
/// serialize against `MetricStore`'s writer actor and back up 1 Hz ingest.
///
/// Safe because `MetricStore.openAndMigrate` puts the DB into WAL mode, which
/// lets many readers run concurrently with a single writer on the same file.
actor MetricReader {
    private let dbURL: URL
    private var db: OpaquePointer?

    private static let idleThresholdPct: Double = 5.0
    /// Treat gaps larger than this as missing data (ignore their energy
    /// contribution) — avoids inflating totals after suspend/reboot.
    private static let maxGapSeconds: Double = 30.0

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    init(dbURL: URL) {
        self.dbURL = dbURL
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    /// Lazy open. The writer (`MetricStore.openAndMigrate`) creates and
    /// migrates the file at app launch; deferring the read-only open to
    /// first use keeps `MetricStore.init` free to construct the reader
    /// before migration has run on a fresh install.
    private func connection() -> OpaquePointer? {
        if let db = db { return db }
        var conn: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &conn, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = conn
        }
        return db
    }

    // MARK: - Power aggregate + summary

    /// Returns bucketed aggregates for the selected host and window.
    /// If `hostname` is nil, sums across all hosts.
    func aggregate(hostname: String?, window: PowerWindow) -> [PowerAggregate] {
        guard let db = connection() else { return [] }
        let since = Date().addingTimeInterval(-window.lookback)
        let sinceTs = Int64(since.timeIntervalSince1970)

        let hostFilter = hostname == nil ? "" : "AND hostname = ?"
        let sql = """
        WITH filtered AS (
            SELECT timestamp, hostname,
                   COALESCE(cpu_w, 0) AS cpu_w,
                   COALESCE(gpu_w, 0) AS gpu_w,
                   cpu_w IS NULL AS cpu_null,
                   gpu_w IS NULL AS gpu_null,
                   cpu_pct, gpu_pct
            FROM metric_samples
            WHERE timestamp >= ? \(hostFilter)
        ),
        windowed AS (
            SELECT *,
                   timestamp - LAG(timestamp) OVER (PARTITION BY hostname ORDER BY timestamp) AS dt
            FROM filtered
        )
        SELECT
            strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
            MIN(timestamp) AS bucket_ts,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     ELSE (cpu_w + gpu_w) * dt / 3600.0 END) AS energy_wh,
            AVG(CASE WHEN cpu_null THEN NULL ELSE cpu_w END) AS mean_cpu_w,
            AVG(CASE WHEN gpu_null THEN NULL ELSE gpu_w END) AS mean_gpu_w,
            MAX(cpu_w + gpu_w) AS peak_w,
            MIN(cpu_w + gpu_w) AS min_w,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     WHEN cpu_pct < ? AND gpu_pct < ? THEN (cpu_w + gpu_w) * dt / 3600.0
                     ELSE 0 END) AS idle_wh,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     WHEN NOT (cpu_pct < ? AND gpu_pct < ?) THEN (cpu_w + gpu_w) * dt / 3600.0
                     ELSE 0 END) AS active_wh
        FROM windowed
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        sqlite3_bind_int64(stmt, idx, sinceTs); idx += 1
        if let host = hostname {
            host.withCString { ptr in
                sqlite3_bind_text(stmt, idx, ptr, -1, Self.SQLITE_TRANSIENT)
            }
            idx += 1
        }
        window.bucketFormat.withCString { ptr in
            sqlite3_bind_text(stmt, idx, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1

        var rows: [PowerAggregate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucketTs = sqlite3_column_int64(stmt, 1)
            let energyWh = sqlite3_column_double(stmt, 2)
            let meanCpuW = sqlite3_column_double(stmt, 3)
            let meanGpuW = sqlite3_column_double(stmt, 4)
            let peakW = sqlite3_column_double(stmt, 5)
            let minW = sqlite3_column_double(stmt, 6)
            let idleWh = sqlite3_column_double(stmt, 7)
            let activeWh = sqlite3_column_double(stmt, 8)
            rows.append(PowerAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(bucketTs)),
                energyWh: energyWh,
                meanCpuW: meanCpuW,
                meanGpuW: meanGpuW,
                peakW: peakW,
                minW: minW,
                idleWh: idleWh,
                activeWh: activeWh
            ))
        }
        return rows
    }

    func summary(hostname: String?, window: PowerWindow) -> PowerSummary {
        let buckets = aggregate(hostname: hostname, window: window)
        if buckets.isEmpty { return .empty }
        let totalWh = buckets.reduce(0.0) { $0 + $1.energyWh }
        let idleWh = buckets.reduce(0.0) { $0 + $1.idleWh }
        let activeWh = buckets.reduce(0.0) { $0 + $1.activeWh }
        let meanW = buckets.reduce(0.0) { $0 + $1.meanTotalW } / Double(buckets.count)
        let peakW = buckets.map(\.peakW).max() ?? 0
        let minW = buckets.map(\.minW).min() ?? 0
        return PowerSummary(
            totalKwh: totalWh / 1000.0,
            meanW: meanW,
            peakW: peakW,
            minW: minW,
            idleKwh: idleWh / 1000.0,
            activeKwh: activeWh / 1000.0
        )
    }

    // MARK: - Gauge aggregates

    func gpuAggregate(hostname: String?, window: PowerWindow) -> [GpuAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(gpu_pct)    AS mean_gpu_pct,
               MAX(gpu_pct)    AS peak_gpu_pct,
               AVG(gpu_temp_c) AS mean_gpu_temp,
               MAX(gpu_temp_c) AS peak_gpu_temp,
               AVG(CASE WHEN vram_total_mb > 0 THEN 100.0 * vram_used_mb / vram_total_mb END) AS mean_vram_pct,
               MAX(CASE WHEN vram_total_mb > 0 THEN 100.0 * vram_used_mb / vram_total_mb END) AS peak_vram_pct
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            GpuAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanGpuPct: sqlite3_column_double(stmt, 2),
                peakGpuPct: sqlite3_column_double(stmt, 3),
                meanGpuTemp: sqlite3_column_double(stmt, 4),
                peakGpuTemp: sqlite3_column_double(stmt, 5),
                meanVramPct: sqlite3_column_double(stmt, 6),
                peakVramPct: sqlite3_column_double(stmt, 7)
            )
        }
    }

    func systemAggregate(hostname: String?, window: PowerWindow) -> [SystemAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(cpu_pct) AS mean_cpu_pct,
               MAX(cpu_pct) AS peak_cpu_pct,
               AVG(CASE WHEN mem_total_mb > 0 THEN 100.0 * mem_used_mb / mem_total_mb END) AS mean_ram_pct,
               MAX(CASE WHEN mem_total_mb > 0 THEN 100.0 * mem_used_mb / mem_total_mb END) AS peak_ram_pct,
               AVG(cpu_temp_c) AS mean_cpu_temp,
               MAX(cpu_temp_c) AS peak_cpu_temp
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            SystemAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanCpuPct: sqlite3_column_double(stmt, 2),
                peakCpuPct: sqlite3_column_double(stmt, 3),
                meanRamPct: sqlite3_column_double(stmt, 4),
                peakRamPct: sqlite3_column_double(stmt, 5),
                meanCpuTemp: sqlite3_column_double(stmt, 6),
                peakCpuTemp: sqlite3_column_double(stmt, 7)
            )
        }
    }

    func diskAggregate(hostname: String?, window: PowerWindow) -> [DiskAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(CASE WHEN disk_total_gb > 0 THEN 100.0 * disk_used_gb / disk_total_gb END) AS mean_disk_pct,
               MAX(CASE WHEN disk_total_gb > 0 THEN 100.0 * disk_used_gb / disk_total_gb END) AS peak_disk_pct,
               AVG(disk_used_gb)  AS mean_used_gb,
               AVG(disk_total_gb) AS mean_total_gb
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            DiskAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanDiskPct: sqlite3_column_double(stmt, 2),
                peakDiskPct: sqlite3_column_double(stmt, 3),
                meanUsedGb: sqlite3_column_double(stmt, 4),
                meanTotalGb: sqlite3_column_double(stmt, 5)
            )
        }
    }

    // MARK: - Raw CSV export

    /// Stream every row in the selected range to `destination` as CSV. The
    /// file is written through a `FileHandle` so a 90-day export (millions
    /// of rows) doesn't materialise in memory. Returns the number of data
    /// rows written (excluding the header).
    func exportRawCsv(
        workers: [String]?,
        from: Date,
        to: Date,
        destination: URL
    ) throws -> Int {
        guard let db = connection() else {
            throw MetricsExporter.Failure.storeUnavailable
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw MetricsExporter.Failure.writeFailed("could not create file")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // Header
        let header = "timestamp,hostname,cpu_w,gpu_w,cpu_pct,gpu_pct,gpu_temp_c,cpu_temp_c,vram_used_mb,vram_total_mb,mem_used_mb,mem_total_mb,disk_used_gb,disk_total_gb,disk_read_bps,disk_write_bps,net_rx_bps,net_tx_bps\n"
        try handle.write(contentsOf: Data(header.utf8))

        // Build the SELECT with optional IN (...) filter for hostnames.
        var sql = """
        SELECT timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct,
               gpu_temp_c, cpu_temp_c, vram_used_mb, vram_total_mb,
               mem_used_mb, mem_total_mb, disk_used_gb, disk_total_gb,
               disk_read_bps, disk_write_bps, net_rx_bps, net_tx_bps
        FROM metric_samples
        WHERE timestamp BETWEEN ? AND ?
        """
        if let workers, !workers.isEmpty {
            let placeholders = Array(repeating: "?", count: workers.count).joined(separator: ",")
            sql += " AND hostname IN (\(placeholders))"
        }
        sql += " ORDER BY hostname, timestamp;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MetricsExporter.Failure.writeFailed("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
        if let workers {
            for (i, w) in workers.enumerated() {
                w.withCString { ptr in
                    sqlite3_bind_text(stmt, Int32(3 + i), ptr, -1, Self.SQLITE_TRANSIENT)
                }
            }
        }

        // 16 KiB batch buffer: flushing after each row shows up as a
        // noticeable syscall cost on big exports.
        var buffer = Data()
        buffer.reserveCapacity(16 * 1024)
        var rowCount = 0

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let hostPtr = sqlite3_column_text(stmt, 1)
            let host = hostPtr.map { String(cString: $0) } ?? ""

            var fields: [String] = []
            fields.reserveCapacity(18)
            fields.append(iso.string(from: date))
            fields.append(csvEscape(host))
            // cpu_w, gpu_w (nullable REAL)
            fields.append(nullableRealColumn(stmt, 2))
            fields.append(nullableRealColumn(stmt, 3))
            // cpu_pct, gpu_pct (non-null REAL)
            fields.append(realColumn(stmt, 4))
            fields.append(realColumn(stmt, 5))
            // gpu_temp_c, cpu_temp_c (nullable REAL)
            fields.append(nullableRealColumn(stmt, 6))
            fields.append(nullableRealColumn(stmt, 7))
            // vram_used_mb .. net_tx_bps (nullable INTEGER)
            for col: Int32 in 8...17 {
                fields.append(nullableIntColumn(stmt, col))
            }

            let line = fields.joined(separator: ",") + "\n"
            buffer.append(contentsOf: line.utf8)
            rowCount += 1

            if buffer.count >= 16 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        return rowCount
    }

    private func realColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        let v = sqlite3_column_double(stmt, idx)
        return formatReal(v)
    }

    private func nullableRealColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        return formatReal(sqlite3_column_double(stmt, idx))
    }

    private func nullableIntColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        return String(sqlite3_column_int64(stmt, idx))
    }

    private func formatReal(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.3f", v)
    }

    /// Quote a CSV field if it contains commas, quotes, or newlines.
    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Aggregate helper

    /// Shared runner for the three gauge aggregates. Binds the bucket format,
    /// timestamp lower bound, and optional hostname — all gauge queries share
    /// this exact binding order.
    private func runAggregate<T>(
        sql: String,
        hostname: String?,
        window: PowerWindow,
        decode: (OpaquePointer?) -> T
    ) -> [T] {
        guard let db = connection() else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let sinceTs = Int64(Date().addingTimeInterval(-window.lookback).timeIntervalSince1970)
        window.bucketFormat.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 2, sinceTs)
        if let host = hostname {
            host.withCString { ptr in
                sqlite3_bind_text(stmt, 3, ptr, -1, Self.SQLITE_TRANSIENT)
            }
        }

        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(decode(stmt))
        }
        return rows
    }

    private func hostFilter(_ hostname: String?) -> String {
        hostname == nil ? "" : "AND hostname = ?"
    }
}
