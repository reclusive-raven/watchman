import Charts
import SwiftUI

// MARK: - X-axis helpers shared by all four tabs

struct HistoryAxis {
    let window: PowerWindow

    var stride: (component: Calendar.Component, count: Int) {
        switch window {
        case .hour:  return (.minute, 10)
        case .day:   return (.hour, 3)
        case .week:  return (.day, 1)
        case .month: return (.day, 5)
        }
    }

    var format: Date.FormatStyle {
        switch window {
        case .hour:  return .dateTime.hour().minute()
        case .day:   return .dateTime.hour()
        case .week:  return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day().month(.abbreviated)
        }
    }

    var domain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-window.lookback)...now
    }
}

extension View {
    /// Applies the window-wide X-axis settings to any `Chart` view. All four
    /// history tabs render with identical time axes so charts stay visually
    /// comparable.
    func historyXAxis(_ axis: HistoryAxis) -> some View {
        self
            .chartXScale(domain: axis.domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: axis.stride.component, count: axis.stride.count)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: axis.format)
                }
            }
    }
}

// MARK: - Shared small components

struct SummaryCard: View {
    let title: String
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Text(primary)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(secondary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
    }
}

struct IdleActiveCard: View {
    let idleKwh: Double
    let activeKwh: Double

    private var total: Double { max(idleKwh + activeKwh, 0.0001) }
    private var idleFraction: Double { idleKwh / total }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Idle / Active")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x44/255.0))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color(red: 0x4A/255.0, green: 0x4A/255.0, blue: 0x5C/255.0))
                            .frame(width: geo.size.width * idleFraction)
                        Rectangle()
                            .fill(Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                Text(String(format: "idle %.3f", idleKwh))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text(String(format: "active %.3f", activeKwh))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
    }
}

/// Empty-state placeholder shown inside a chart container when no samples
/// fall within the selected window.
struct HistoryEmptyState: View {
    let isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Text("No samples in this window")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 12, design: .monospaced))
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
        }
    }
}

/// Rounded card shell that each tab wraps its chart in, matching the
/// existing `cardBg` styling.
struct HistoryChartCard<Content: View>: View {
    let caption: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            content()
                .frame(minHeight: 220)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.cardBg))
        }
    }
}
