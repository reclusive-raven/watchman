import Foundation
import SwiftUI
import UserNotifications

/// Owns per-worker alert state, runs edge-detection on each poll result, and
/// dispatches notifications via `UNUserNotificationCenter`. Updated live
/// from `MetricsPoller` after every fetch cycle.
@MainActor
final class AlertsEngine: ObservableObject {
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var states: [String: LastAlertState] = [:]
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        authorizationStatus = current.authorizationStatus
        if current.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            authorizationStatus = (await center.notificationSettings()).authorizationStatus
        }
    }

    /// Opens System Settings' Notifications pane so the user can re-grant
    /// permission after denying (macOS does not re-prompt once denied).
    func openSystemNotificationsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Evaluation

    /// Called by `MetricsPoller` once per worker after each poll. `metrics`
    /// is nil when the worker was unreachable in the most recent cycle.
    func evaluate(workerId: String, alias: String, host: String?, metrics: WorkerMetrics?) {
        guard settings.notificationsEnabled else { return }
        var s = states[workerId] ?? LastAlertState()
        defer { states[workerId] = s }

        guard let m = metrics else {
            s.consecutiveUnreachable += 1
            evaluateUnreachable(state: &s, workerId: workerId, alias: alias, host: host)
            return
        }

        s.hadEverReachable = true
        s.isUnreachable = false
        s.consecutiveUnreachable = 0

        evaluateGpuTemp(state: &s, metrics: m, workerId: workerId, alias: alias)
        evaluateVram(state: &s, metrics: m, workerId: workerId, alias: alias)
        evaluateDisk(state: &s, metrics: m, workerId: workerId, alias: alias)
        evaluateGpuCrash(state: &s, metrics: m, workerId: workerId, alias: alias)
    }

    // MARK: - Individual rules

    private func evaluateUnreachable(
        state s: inout LastAlertState, workerId: String, alias: String, host: String?
    ) {
        guard settings.alertUnreachableEnabled,
              s.hadEverReachable,
              !s.isUnreachable,
              s.consecutiveUnreachable >= max(1, settings.unreachableMissesTrigger)
        else { return }
        fire(
            .unreachable,
            workerId: workerId,
            alias: alias,
            detail: "No response from \(host ?? alias) for \(s.consecutiveUnreachable) polls."
        )
        s.isUnreachable = true
    }

    private func evaluateGpuTemp(
        state s: inout LastAlertState, metrics: WorkerMetrics, workerId: String, alias: String
    ) {
        guard settings.alertGpuTempEnabled, let gpu = metrics.gpu else { return }
        let temp = Double(gpu.temp_c)
        if !s.isGpuTempCritical, temp > settings.gpuTempTrigger {
            fire(.gpuTempCritical, workerId: workerId, alias: alias,
                 detail: String(format: "GPU at %.0f °C (threshold %.0f °C).",
                                temp, settings.gpuTempTrigger))
            s.isGpuTempCritical = true
        } else if s.isGpuTempCritical, temp < settings.gpuTempClear {
            s.isGpuTempCritical = false
        }
    }

    private func evaluateVram(
        state s: inout LastAlertState, metrics: WorkerMetrics, workerId: String, alias: String
    ) {
        guard settings.alertVramEnabled,
              let gpu = metrics.gpu,
              gpu.vram_total_mb > 0
        else { return }
        let pct = 100.0 * Double(gpu.vram_used_mb) / Double(gpu.vram_total_mb)
        if !s.isVramCritical, pct > settings.vramTrigger {
            fire(.vramCritical, workerId: workerId, alias: alias,
                 detail: String(format: "VRAM %.0f%% (%@ / %@).",
                                pct, gpu.vramUsedFormatted, gpu.vramTotalFormatted))
            s.isVramCritical = true
        } else if s.isVramCritical, pct < settings.vramClear {
            s.isVramCritical = false
        }
    }

    private func evaluateDisk(
        state s: inout LastAlertState, metrics: WorkerMetrics, workerId: String, alias: String
    ) {
        guard settings.alertDiskEnabled, metrics.disk.total_gb > 0 else { return }
        let pct = 100.0 * Double(metrics.disk.used_gb) / Double(metrics.disk.total_gb)
        if !s.isDiskCritical, pct > settings.diskTrigger {
            fire(.diskCritical, workerId: workerId, alias: alias,
                 detail: String(format: "Disk %.0f%% (%@ / %@).",
                                pct, metrics.disk.usedFormatted, metrics.disk.totalFormatted))
            s.isDiskCritical = true
        } else if s.isDiskCritical, pct < settings.diskClear {
            s.isDiskCritical = false
        }
    }

    /// Detects the pattern "GPU was clearly training, then idled for a
    /// sustained window" — a training crash signature. State machine:
    ///
    /// - above HIGH   → remember `gpuAboveSince`, clear below-timer, re-arm.
    /// - below LOW    → start `gpuBelowSince` once; fire after `sustainedSec`
    ///                  has elapsed since the drop. Clear above/below after
    ///                  firing so the detector re-arms only when util climbs
    ///                  back above HIGH.
    /// - in between   → reset only the below-timer; preserve "was training"
    ///                  memory in `gpuAboveSince`.
    private func evaluateGpuCrash(
        state s: inout LastAlertState, metrics: WorkerMetrics, workerId: String, alias: String
    ) {
        guard settings.alertGpuCrashEnabled, let gpu = metrics.gpu else { return }
        let util = Double(gpu.usage_percent)
        let now = Date()

        if util > settings.gpuCrashHighPct {
            if s.gpuAboveSince == nil { s.gpuAboveSince = now }
            s.gpuBelowSince = nil
            s.gpuCrashFired = false
            return
        }

        if util < settings.gpuCrashLowPct, s.gpuAboveSince != nil {
            if s.gpuBelowSince == nil { s.gpuBelowSince = now }
            if let below = s.gpuBelowSince,
               !s.gpuCrashFired,
               now.timeIntervalSince(below) >= settings.gpuCrashSustainedSec
            {
                fire(
                    .gpuUtilCrash, workerId: workerId, alias: alias,
                    detail: String(
                        format: "GPU dropped from >%.0f%% to <%.0f%% for %.0f s.",
                        settings.gpuCrashHighPct, settings.gpuCrashLowPct,
                        settings.gpuCrashSustainedSec
                    )
                )
                s.gpuCrashFired = true
                s.gpuAboveSince = nil
                s.gpuBelowSince = nil
            }
            return
        }

        // In between HIGH and LOW — don't treat as "recently idle".
        s.gpuBelowSince = nil
    }

    // MARK: - Dispatch

    func fire(_ type: AlertType, workerId: String, alias: String, detail: String) {
        let content = UNMutableNotificationContent()
        switch type {
        case .unreachable:
            content.title = "\(alias) unreachable"
            content.body = detail
        case .gpuTempCritical:
            content.title = "\(alias) GPU temperature critical"
            content.body = detail
        case .gpuUtilCrash:
            content.title = "\(alias) GPU idle — training may have crashed"
            content.body = detail
        case .vramCritical:
            content.title = "\(alias) VRAM nearly full"
            content.body = detail
        case .diskCritical:
            content.title = "\(alias) disk nearly full"
            content.body = detail
        }
        content.sound = .default

        let id = "\(workerId).\(type.rawValue)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
