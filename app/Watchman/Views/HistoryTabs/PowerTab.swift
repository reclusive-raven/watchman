import Charts
import SwiftUI

struct PowerTab: View {
    @ObservedObject var vm: HistoryViewModel
    @ObservedObject private var settings = AppSettings.shared

    private var axis: HistoryAxis { HistoryAxis(window: vm.window) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards
            HistoryChartCard(caption: "Instantaneous CPU + GPU power") {
                if vm.powerBuckets.isEmpty {
                    HistoryEmptyState(isLoading: vm.isLoading)
                } else {
                    chart
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    /// Secondary line under total kWh. Shows the dollar cost when the user
    /// has set a `$/kWh` rate in General settings.
    private var totalSecondary: String {
        if settings.costPerKwh > 0 {
            let dollars = vm.summary.totalKwh * settings.costPerKwh
            return String(format: "$%.2f  ·  %@", dollars, vm.window.label)
        }
        return vm.window.label
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            SummaryCard(
                title: "Total",
                primary: String(format: "%.3f kWh", vm.summary.totalKwh),
                secondary: totalSecondary
            )
            SummaryCard(
                title: "Mean",
                primary: String(format: "%.0f W", vm.summary.meanW),
                secondary: "avg instantaneous"
            )
            SummaryCard(
                title: "Peak",
                primary: String(format: "%.0f W", vm.summary.peakW),
                secondary: "max instantaneous"
            )
            SummaryCard(
                title: "Min",
                primary: String(format: "%.0f W", vm.summary.minW),
                secondary: "idle floor"
            )
            IdleActiveCard(
                idleKwh: vm.summary.idleKwh,
                activeKwh: vm.summary.activeKwh
            )
        }
    }

    private var chart: some View {
        Chart {
            ForEach(vm.powerBuckets) { b in
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("watts", b.meanCpuW)
                )
                .foregroundStyle(by: .value("series", "CPU"))
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("watts", b.meanGpuW)
                )
                .foregroundStyle(by: .value("series", "GPU"))
            }
        }
        .chartForegroundStyleScale([
            "CPU": Color(red: 0x00/255.0, green: 0xD4/255.0, blue: 0xFF/255.0),
            "GPU": Color(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0),
        ])
        .chartYAxisLabel("W")
        .historyXAxis(axis)
    }
}
