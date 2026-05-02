import Foundation

/// Public façade over `MetricStore.exportCsv(...)` for ExportView. Kept as
/// a separate type so view layer doesn't reach into the store actor's API
/// and so the export can later grow (JSON, gzipped, aggregated) without
/// touching the store.
enum MetricsExporter {
    enum Failure: LocalizedError {
        case storeUnavailable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable:
                return "Metric store is unavailable."
            case .writeFailed(let reason):
                return "Export failed: \(reason)"
            }
        }
    }

    static func exportRawCsv(
        workers: [String]?,
        from: Date,
        to: Date,
        destination: URL
    ) async throws -> Int {
        try await MetricStore.shared.reader.exportRawCsv(
            workers: workers,
            from: from,
            to: to,
            destination: destination
        )
    }
}
