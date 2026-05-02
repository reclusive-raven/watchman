import Foundation

struct WorkerMetrics: Codable, Identifiable {
    var id: String { hostname }

    let hostname: String
    let cpu: CpuMetrics
    let gpu: GpuMetrics?
    let memory: MemoryMetrics
    let disk: DiskMetrics
    let io: IoMetrics?
    let temps: TempMetrics
    let power: PowerMetrics?
    let hardware: HardwareInfo?
    let timestamp: String

    struct CpuMetrics: Codable {
        let usage_percent: Float
        let core_count: Int
        let per_core: [Float]
    }

    struct GpuMetrics: Codable {
        let usage_percent: UInt32
        let vram_used_mb: UInt64
        let vram_total_mb: UInt64
        let temp_c: UInt32
        let fan_speed_percent: UInt32
    }

    struct MemoryMetrics: Codable {
        let used_mb: UInt64
        let total_mb: UInt64
    }

    struct DiskMetrics: Codable {
        let used_gb: UInt64
        let total_gb: UInt64
    }

    struct IoMetrics: Codable {
        let disk_read_bps: UInt64
        let disk_write_bps: UInt64
        let net_rx_bps: UInt64
        let net_tx_bps: UInt64
    }

    struct TempMetrics: Codable {
        let cpu_temp_c: Float?
    }

    struct PowerMetrics: Codable {
        let cpu_w: Float?
        let gpu_w: Float?
    }

    struct HardwareInfo: Codable {
        let cpu_model: String?
        let gpu_model: String?
    }
}

enum WorkerState {
    case ok
    case warning
    case critical
    case unreachable

    var color: String {
        switch self {
        case .ok: return "green"
        case .warning: return "yellow"
        case .critical: return "red"
        case .unreachable: return "gray"
        }
    }

    var systemColor: SwiftUI.Color {
        switch self {
        case .ok: return Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0)         // #00FF88
        case .warning: return Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0)    // #FFE500
        case .critical: return Color(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0)    // #FF0050
        case .unreachable: return Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x44/255.0) // #333344
        }
    }
}

import SwiftUI

struct WorkerEntry: Identifiable {
    let id: String
    var url: URL
    var enabled: Bool = true
    var metrics: WorkerMetrics?
    var state: WorkerState = .unreachable
    var lastUpdated: Date?

    var displayName: String {
        metrics?.hostname ?? id
    }

    /// Worker index extracted from id (e.g. "worker-0" → 0)
    var index: Int? {
        id.split(separator: "-").last.flatMap { Int($0) }
    }

    var staleness: String? {
        guard let lastUpdated else { return nil }
        let elapsed = Int(-lastUpdated.timeIntervalSinceNow)
        if elapsed < 5 { return nil }
        if elapsed < 60 { return "\(elapsed)s ago" }
        return "\(elapsed / 60)m ago"
    }

    var peakUsage: Int? {
        guard let m = metrics else { return nil }
        var vals = [Int(m.cpu.usage_percent)]
        if let gpu = m.gpu { vals.append(Int(gpu.usage_percent)) }
        let ramPct = m.memory.total_mb > 0
            ? Int(100 * m.memory.used_mb / m.memory.total_mb) : 0
        vals.append(ramPct)
        return vals.max()
    }

    var maxTemp: Int? {
        guard let m = metrics else { return nil }
        var temps: [Int] = []
        if let t = m.temps.cpu_temp_c { temps.append(Int(t)) }
        if let gpu = m.gpu { temps.append(Int(gpu.temp_c)) }
        return temps.max()
    }

    @MainActor
    mutating func update(with metrics: WorkerMetrics, settings: AppSettings) {
        self.metrics = metrics
        self.state = Self.evaluateState(metrics, settings: settings)
        self.lastUpdated = Date()
    }

    mutating func markUnreachable() {
        self.metrics = nil
        self.state = .unreachable
        // lastUpdated intentionally kept for staleness display
    }

    @MainActor
    private static func evaluateState(_ m: WorkerMetrics, settings: AppSettings) -> WorkerState {
        if let gpu = m.gpu {
            if Double(gpu.temp_c) >= settings.tempRedC    { return .critical }
            if Double(gpu.temp_c) >= settings.tempOrangeC { return .warning }
        }
        let ramPercent = m.memory.total_mb > 0
            ? 100.0 * Double(m.memory.used_mb) / Double(m.memory.total_mb)
            : 0
        if ramPercent >= settings.ramWarningPct { return .warning }
        return .ok
    }
}

// MARK: - Formatting Extensions

private func formatBytes(mb: UInt64) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", Double(mb) / 1024.0)
    }
    return "\(mb) MB"
}

extension WorkerMetrics.GpuMetrics {
    var vramUsedFormatted: String { formatBytes(mb: vram_used_mb) }
    var vramTotalFormatted: String { formatBytes(mb: vram_total_mb) }
    var vramFraction: Double {
        vram_total_mb > 0 ? Double(vram_used_mb) / Double(vram_total_mb) : 0
    }
}

extension WorkerMetrics.MemoryMetrics {
    var usedFormatted: String { formatBytes(mb: used_mb) }
    var totalFormatted: String { formatBytes(mb: total_mb) }
    var fraction: Double {
        total_mb > 0 ? Double(used_mb) / Double(total_mb) : 0
    }
}

extension WorkerMetrics.DiskMetrics {
    var usedFormatted: String {
        if used_gb >= 1024 {
            return String(format: "%.1f TB", Double(used_gb) / 1024.0)
        }
        return "\(used_gb) GB"
    }
    var totalFormatted: String {
        if total_gb >= 1024 {
            return String(format: "%.1f TB", Double(total_gb) / 1024.0)
        }
        return "\(total_gb) GB"
    }
    var fraction: Double {
        total_gb > 0 ? Double(used_gb) / Double(total_gb) : 0
    }
}

enum OverallStatus {
    case allGood
    case someWarning
    case someCritical
    case allUnreachable

    var label: String {
        switch self {
        case .allGood: return "OK"
        case .someWarning: return "WARN"
        case .someCritical: return "CRIT"
        case .allUnreachable: return "OFF"
        }
    }
}
