import Charts
import SwiftUI

struct GpuTab: View {
    @ObservedObject var vm: HistoryViewModel

    private var axis: HistoryAxis { HistoryAxis(window: vm.window) }

    private var meanUtil: Double {
        guard !vm.gpuBuckets.isEmpty else { return 0 }
        return vm.gpuBuckets.map(\.meanGpuPct).reduce(0, +) / Double(vm.gpuBuckets.count)
    }
    private var peakTemp: Double { vm.gpuBuckets.map(\.peakGpuTemp).max() ?? 0 }
    private var peakVram: Double { vm.gpuBuckets.map(\.peakVramPct).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards
            HistoryChartCard(caption: "GPU utilisation, temperature, and VRAM") {
                if vm.gpuBuckets.isEmpty {
                    HistoryEmptyState(isLoading: vm.isLoading)
                } else {
                    chart
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            SummaryCard(
                title: "Mean util",
                primary: String(format: "%.0f%%", meanUtil),
                secondary: vm.window.label
            )
            SummaryCard(
                title: "Peak temp",
                primary: String(format: "%.0f°C", peakTemp),
                secondary: "max in window"
            )
            SummaryCard(
                title: "Peak VRAM",
                primary: String(format: "%.0f%%", peakVram),
                secondary: "max in window"
            )
        }
    }

    private var chart: some View {
        Chart {
            ForEach(vm.gpuBuckets) { b in
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanGpuPct)
                )
                .foregroundStyle(by: .value("series", "Util %"))
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanVramPct)
                )
                .foregroundStyle(by: .value("series", "VRAM %"))
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanGpuTemp)
                )
                .foregroundStyle(by: .value("series", "Temp °C"))
            }
        }
        .chartForegroundStyleScale([
            "Util %":  Color(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0),
            "VRAM %":  Color(red: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0),
            "Temp °C": Color(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0),
        ])
        .historyXAxis(axis)
    }
}
