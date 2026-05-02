import SwiftUI

// MARK: - Neon Noir Accent Colors

private let neonGreen = Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0)    // #00FF88
private let neonYellow = Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0)   // #FFE500
private let neonRed = Color(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0)      // #FF0050
private let neonOrange = Color(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0)   // #FF7A00
private let neonGray = Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x44/255.0)     // #333344

// MARK: - Color Helpers

@MainActor
private func usageColor(_ percent: Int) -> Color {
    let s = AppSettings.shared
    if Double(percent) >= s.usageRedPct    { return neonRed }
    if Double(percent) >= s.usageYellowPct { return neonYellow }
    return neonGreen
}

@MainActor
private func tempColor(_ temp: Int) -> Color {
    let s = AppSettings.shared
    if Double(temp) >= s.tempRedC    { return neonRed }
    if Double(temp) >= s.tempOrangeC { return neonOrange }
    if Double(temp) >= s.tempYellowC { return neonYellow }
    return neonGray
}

// MARK: - MetricRow

private struct MetricRow: View {
    let label: String
    let percent: Int
    var temp: Int? = nil

    private var barColor: Color { usageColor(percent) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text("\(percent)%")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(width: 48, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.trackGray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100.0)
                }
            }
            .frame(height: 6)
            if let temp {
                Text("\(temp)°C")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(temp))
                    .frame(width: 48, alignment: .trailing)
            } else {
                Color.clear.frame(width: 48)
            }
        }
    }
}

// MARK: - CapacityRow

// MARK: - PowerRow

/// Single-line row showing instantaneous watts with a bar scaled against a
/// nominal TDP budget. `watts == nil` renders a muted placeholder.
private struct PowerRow: View {
    let label: String
    let watts: Float?
    let tdpBudget: Double  // watts; bar fills to 100% here

    private var displayPercent: Double {
        guard let w = watts, tdpBudget > 0 else { return 0 }
        return min(max(Double(w) / tdpBudget, 0), 1.2) * 100
    }

    private var barColor: Color {
        let pct = Int(displayPercent)
        if pct >= 95 { return Color(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0) }
        if pct >= 75 { return Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0) }
        return Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            if let w = watts {
                Text(String(format: "%.0f W", w))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                    .frame(width: 48, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.trackGray)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(min(displayPercent, 100)) / 100.0)
                    }
                }
                .frame(height: 6)
            } else {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 48, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.trackGray)
                    .frame(height: 6)
            }
            Color.clear.frame(width: 48)
        }
    }
}

// MARK: - CapacityRow

private struct CapacityRow: View {
    let label: String
    let percent: Int
    let summary: String  // e.g. "16/64"; unit implied by label (RAM/VRAM → GB)

    private var barColor: Color { usageColor(percent) }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text("\(percent)%")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(width: 48, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.trackGray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100.0)
                }
            }
            .frame(height: 6)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private func compactGB(usedMB: UInt64, totalMB: UInt64) -> String {
    let u = Int((Double(usedMB) / 1024.0).rounded())
    let t = Int((Double(totalMB) / 1024.0).rounded())
    return "\(u)/\(t)"
}

/// Format a bytes-per-second rate using the most-readable unit.
private func formatRate(_ bps: UInt64) -> String {
    let b = Double(bps)
    if b >= 1_000_000_000 { return String(format: "%.1f GB/s", b / 1_000_000_000) }
    if b >= 1_000_000     { return String(format: "%.1f MB/s", b / 1_000_000) }
    if b >= 1_000         { return String(format: "%.0f KB/s", b / 1_000) }
    return "\(bps) B/s"
}

/// Compact two-direction throughput row: `↓ 12 MB/s   ↑ 5 MB/s`.
private struct IoRow: View {
    let label: String
    let rx: UInt64
    let tx: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9))
                Text(formatRate(rx))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                Text(formatRate(tx))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }
}

// MARK: - WorkerDetailView

struct WorkerDetailView: View {
    let worker: WorkerEntry
    var alias: String?

    private var displayAlias: String {
        if let alias, !alias.isEmpty { return alias }
        return worker.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: status dot + name
            HStack(spacing: 6) {
                Circle()
                    .fill(worker.state.systemColor)
                    .frame(width: 8, height: 8)
                Text(displayAlias)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                if worker.state == .unreachable {
                    Text("unreachable")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let m = worker.metrics {
                VStack(alignment: .leading, spacing: 10) {
                    // CPU group (usage + temp, power)
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(
                            label: "CPU",
                            percent: Int(m.cpu.usage_percent),
                            temp: m.temps.cpu_temp_c.map { Int($0) }
                        )
                        PowerRow(
                            label: "CPU W",
                            watts: m.power?.cpu_w,
                            tdpBudget: PowerLimits.cpu(for: m.hardware?.cpu_model)
                        )
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                    // GPU group (usage + temp, VRAM capacity, power) — if present
                    VStack(alignment: .leading, spacing: 5) {
                        if let gpu = m.gpu {
                            MetricRow(label: "GPU", percent: Int(gpu.usage_percent), temp: Int(gpu.temp_c))
                            CapacityRow(
                                label: "VRAM",
                                percent: Int((gpu.vramFraction * 100).rounded()),
                                summary: compactGB(usedMB: gpu.vram_used_mb, totalMB: gpu.vram_total_mb)
                            )
                            PowerRow(
                                label: "GPU W",
                                watts: m.power?.gpu_w,
                                tdpBudget: PowerLimits.gpu(for: m.hardware?.gpu_model)
                            )
                        } else {
                            HStack(spacing: 6) {
                                Text("GPU")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
                                Text("—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                    // RAM (standalone, no group box)
                    CapacityRow(
                        label: "RAM",
                        percent: Int((m.memory.fraction * 100).rounded()),
                        summary: compactGB(usedMB: m.memory.used_mb, totalMB: m.memory.total_mb)
                    )
                    .padding(.horizontal, 6)

                    // I/O: disk + network throughput
                    if let io = m.io {
                        VStack(alignment: .leading, spacing: 5) {
                            IoRow(label: "Disk", rx: io.disk_read_bps, tx: io.disk_write_bps)
                            IoRow(label: "Net",  rx: io.net_rx_bps,    tx: io.net_tx_bps)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
        .opacity(worker.state == .unreachable ? 0.5 : 1.0)
    }
}
