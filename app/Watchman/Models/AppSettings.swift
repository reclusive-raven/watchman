import Foundation
import ServiceManagement
import SwiftUI

/// A single worker's configuration. Persisted as an ordered list in
/// `AppSettings.workers` so that workers can be added, removed, and renamed
/// without rebuilding the app.
struct WorkerConfig: Codable, Identifiable, Hashable {
    var id: String
    var host: String
    var port: Int
    var alias: String
    var enabled: Bool

    var url: URL? {
        URL(string: "http://\(host):\(port)/metrics")
    }

    var displayAlias: String {
        alias.isEmpty ? id : alias
    }
}

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }

    // MARK: - Alert settings (populated in the preferences tab)

    @AppStorage("notificationsEnabled")    var notificationsEnabled:    Bool = true
    @AppStorage("alertUnreachableEnabled") var alertUnreachableEnabled: Bool = true
    @AppStorage("unreachableMissesTrigger") var unreachableMissesTrigger: Int = 5

    @AppStorage("alertGpuTempEnabled") var alertGpuTempEnabled: Bool   = true
    @AppStorage("gpuTempTrigger")      var gpuTempTrigger:      Double = 85
    @AppStorage("gpuTempClear")        var gpuTempClear:        Double = 80

    @AppStorage("alertGpuCrashEnabled")    var alertGpuCrashEnabled:    Bool   = true
    @AppStorage("gpuCrashHighPct")         var gpuCrashHighPct:         Double = 70
    @AppStorage("gpuCrashLowPct")          var gpuCrashLowPct:          Double = 5
    @AppStorage("gpuCrashSustainedSec")    var gpuCrashSustainedSec:    Double = 60

    @AppStorage("alertVramEnabled") var alertVramEnabled: Bool   = true
    @AppStorage("vramTrigger")      var vramTrigger:      Double = 95
    @AppStorage("vramClear")        var vramClear:        Double = 90

    @AppStorage("alertDiskEnabled") var alertDiskEnabled: Bool   = true
    @AppStorage("diskTrigger")      var diskTrigger:      Double = 95
    @AppStorage("diskClear")        var diskClear:        Double = 90

    // MARK: - Display thresholds (menu bar + detail view colors)

    @AppStorage("usageRedPct")    var usageRedPct:    Double = 85
    @AppStorage("usageYellowPct") var usageYellowPct: Double = 70
    @AppStorage("tempRedC")       var tempRedC:       Double = 85
    @AppStorage("tempOrangeC")    var tempOrangeC:    Double = 75
    @AppStorage("tempYellowC")    var tempYellowC:    Double = 60
    @AppStorage("ramWarningPct")  var ramWarningPct:  Double = 90

    // MARK: - Menu-bar sparkline

    @AppStorage("sparklineMetric") var sparklineMetricRaw: String = SparklineMetric.gpuUsage.rawValue

    var sparklineMetric: SparklineMetric {
        get { SparklineMetric(rawValue: sparklineMetricRaw) ?? .gpuUsage }
        set { sparklineMetricRaw = newValue.rawValue }
    }

    // MARK: - Cost

    @AppStorage("costPerKwh") var costPerKwh: Double = 0

    // MARK: - Worker list

    /// Ordered list of worker configurations. Persisted as JSON under
    /// `workerConfigs` in UserDefaults. Observing views and `MetricsPoller`
    /// receive updates via `$workers`.
    @Published var workers: [WorkerConfig] = [] {
        didSet { persistWorkers() }
    }

    private let workersKey = "workerConfigs"

    init() {
        self.workers = Self.loadWorkers(workersKey: workersKey)
    }

    /// Alias lookup used by views that still key by worker id.
    func alias(for workerId: String) -> String {
        workers.first(where: { $0.id == workerId })?.displayAlias ?? workerId
    }

    // MARK: - Worker mutations

    func addWorker(_ config: WorkerConfig) {
        var next = workers
        // De-dupe by id; replace if present.
        if let idx = next.firstIndex(where: { $0.id == config.id }) {
            next[idx] = config
        } else {
            next.append(config)
        }
        workers = next
    }

    func removeWorker(id: String) {
        workers.removeAll { $0.id == id }
    }

    func moveWorkers(from source: IndexSet, to destination: Int) {
        var next = workers
        next.move(fromOffsets: source, toOffset: destination)
        workers = next
    }

    func updateWorker(_ config: WorkerConfig) {
        guard let idx = workers.firstIndex(where: { $0.id == config.id }) else { return }
        var next = workers
        next[idx] = config
        workers = next
    }

    // MARK: - Persistence

    private static func loadWorkers(workersKey: String) -> [WorkerConfig] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: workersKey),
           let list = try? JSONDecoder().decode([WorkerConfig].self, from: data)
        {
            return list
        }
        return []
    }

    private func persistWorkers() {
        guard let data = try? JSONEncoder().encode(workers) else { return }
        UserDefaults.standard.set(data, forKey: workersKey)
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}

/// Metric plotted in the menu-bar sparkline.
enum SparklineMetric: String, CaseIterable, Identifiable {
    case off
    case gpuUsage
    case gpuTemp
    case cpuUsage
    case cpuTemp
    case ramPct
    case vramPct
    case diskReadBps
    case netRxBps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:         return "Off"
        case .gpuUsage:    return "GPU usage"
        case .gpuTemp:     return "GPU temperature"
        case .cpuUsage:    return "CPU usage"
        case .cpuTemp:     return "CPU temperature"
        case .ramPct:      return "RAM usage"
        case .vramPct:     return "VRAM usage"
        case .diskReadBps: return "Disk read"
        case .netRxBps:    return "Network receive"
        }
    }

    /// Extract the sample value from a `WorkerMetrics` payload. Returns `nil`
    /// when the metric isn't available on this worker (e.g. GPU metrics on a
    /// CPU-only host).
    func value(from m: WorkerMetrics) -> Double? {
        switch self {
        case .off:         return nil
        case .gpuUsage:    return m.gpu.map { Double($0.usage_percent) }
        case .gpuTemp:     return m.gpu.map { Double($0.temp_c) }
        case .cpuUsage:    return Double(m.cpu.usage_percent)
        case .cpuTemp:     return m.temps.cpu_temp_c.map(Double.init)
        case .ramPct:
            guard m.memory.total_mb > 0 else { return nil }
            return 100.0 * Double(m.memory.used_mb) / Double(m.memory.total_mb)
        case .vramPct:
            guard let gpu = m.gpu, gpu.vram_total_mb > 0 else { return nil }
            return 100.0 * Double(gpu.vram_used_mb) / Double(gpu.vram_total_mb)
        case .diskReadBps: return m.io.map { Double($0.disk_read_bps) }
        case .netRxBps:    return m.io.map { Double($0.net_rx_bps) }
        }
    }
}
