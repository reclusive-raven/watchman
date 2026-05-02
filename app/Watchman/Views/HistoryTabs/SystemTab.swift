import Charts
import SwiftUI

struct SystemTab: View {
    @ObservedObject var vm: HistoryViewModel

    private var axis: HistoryAxis { HistoryAxis(window: vm.window) }

    private var meanCpu: Double {
        guard !vm.systemBuckets.isEmpty else { return 0 }
        return vm.systemBuckets.map(\.meanCpuPct).reduce(0, +) / Double(vm.systemBuckets.count)
    }
    private var peakRam: Double { vm.systemBuckets.map(\.peakRamPct).max() ?? 0 }
    private var peakCpuTemp: Double { vm.systemBuckets.map(\.peakCpuTemp).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards
            HistoryChartCard(caption: "CPU utilisation, RAM, and CPU temperature") {
                if vm.systemBuckets.isEmpty {
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
                title: "Mean CPU",
                primary: String(format: "%.0f%%", meanCpu),
                secondary: vm.window.label
            )
            SummaryCard(
                title: "Peak RAM",
                primary: String(format: "%.0f%%", peakRam),
                secondary: "max in window"
            )
            SummaryCard(
                title: "Peak CPU temp",
                primary: String(format: "%.0f°C", peakCpuTemp),
                secondary: "max in window"
            )
        }
    }

    private var chart: some View {
        Chart {
            ForEach(vm.systemBuckets) { b in
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanCpuPct)
                )
                .foregroundStyle(by: .value("series", "CPU %"))
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanRamPct)
                )
                .foregroundStyle(by: .value("series", "RAM %"))
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("value", b.meanCpuTemp)
                )
                .foregroundStyle(by: .value("series", "CPU temp °C"))
            }
        }
        .chartForegroundStyleScale([
            "CPU %":       Color(red: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0),
            "RAM %":       Color(red: 0xA0/255.0, green: 0x80/255.0, blue: 0xFF/255.0),
            "CPU temp °C": Color(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0),
        ])
        .historyXAxis(axis)
    }
}
