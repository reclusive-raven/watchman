import Foundation

/// Ring-buffer store of recent numeric samples per worker, feeding the
/// menu-bar sparkline. One entry is appended per poll (≈ 1 Hz) — a capacity
/// of 60 therefore holds a 1-minute trend.
@MainActor
final class SparklineHistory {
    static let shared = SparklineHistory()

    private let capacity: Int
    private var buffers: [String: [Double]] = [:]

    init(capacity: Int = 60) {
        self.capacity = capacity
    }

    /// Append a sample for `workerId`. A `nil` value is recorded as a gap
    /// (the buffer is cleared) so stale data from a metric switch or an
    /// unreachable worker doesn't bleed into the next reading.
    func append(workerId: String, value: Double?) {
        guard let value else {
            buffers[workerId] = []
            return
        }
        var samples = buffers[workerId] ?? []
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        buffers[workerId] = samples
    }

    func values(workerId: String) -> [Double] {
        buffers[workerId] ?? []
    }

    /// Drop all cached samples. Called when the user picks a different
    /// sparkline metric so the plot doesn't mix units.
    func clear() {
        buffers.removeAll(keepingCapacity: true)
    }
}
