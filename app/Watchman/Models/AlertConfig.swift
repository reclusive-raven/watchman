import Foundation

/// Categories of alert Watchman can raise. The raw value is used as part of
/// the `UNNotificationRequest` identifier so each type collapses to one
/// pending notification per worker.
enum AlertType: String, CaseIterable {
    case unreachable
    case gpuTempCritical
    case gpuUtilCrash
    case vramCritical
    case diskCritical
}

/// Per-worker edge-detection state. In-memory only — on app restart, the
/// engine re-fires at most one notification per still-bad metric.
struct LastAlertState {
    var isUnreachable = false
    /// Consecutive failed polls since the last successful one. Used to gate
    /// the unreachable alert so a single transient miss (e.g. a brief mDNS
    /// stall) does not fire a notification. Resets to 0 on any success.
    var consecutiveUnreachable: Int = 0
    /// Guards against spam on cold-start when a worker is unreachable but
    /// has never been reached this process lifetime.
    var hadEverReachable = false
    var isGpuTempCritical = false
    var isVramCritical = false
    var isDiskCritical = false

    // GPU-util crash sub-state: track when the worker was last clearly
    // training (above `highPct`) and when it first dropped below `lowPct`,
    // so we can fire after the drop has been sustained for `sustainedSec`.
    var gpuAboveSince: Date? = nil
    var gpuBelowSince: Date? = nil
    var gpuCrashFired = false
}
