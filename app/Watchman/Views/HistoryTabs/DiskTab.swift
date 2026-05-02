import Charts
import SwiftUI

struct DiskTab: View {
    @ObservedObject var vm: HistoryViewModel

    private var axis: HistoryAxis { HistoryAxis(window: vm.window) }

    private var currentPct: Double { vm.diskBuckets.last?.meanDiskPct ?? 0 }
    private var currentFreeGb: Double {
        guard let b = vm.diskBuckets.last else { return 0 }
        return max(0, b.meanTotalGb - b.meanUsedGb)
    }
    private var peakPct: Double { vm.diskBuckets.map(\.peakDiskPct).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards
            HistoryChartCard(caption: "Disk usage") {
                if vm.diskBuckets.isEmpty {
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
                title: "Current",
                primary: String(format: "%.0f%%", currentPct),
                secondary: "disk used"
            )
            SummaryCard(
                title: "Free",
                primary: formatGb(currentFreeGb),
                secondary: "available"
            )
            SummaryCard(
                title: "Peak",
                primary: String(format: "%.0f%%", peakPct),
                secondary: vm.window.label
            )
        }
    }

    private var chart: some View {
        Chart {
            ForEach(vm.diskBuckets) { b in
                AreaMark(
                    x: .value("time", b.bucketStart),
                    y: .value("disk %", b.meanDiskPct)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0xA0/255.0, green: 0x80/255.0, blue: 0xFF/255.0, opacity: 0.6),
                            Color(red: 0xA0/255.0, green: 0x80/255.0, blue: 0xFF/255.0, opacity: 0.1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("time", b.bucketStart),
                    y: .value("disk %", b.meanDiskPct)
                )
                .foregroundStyle(Color(red: 0xA0/255.0, green: 0x80/255.0, blue: 0xFF/255.0))
            }
        }
        .chartYAxisLabel("%")
        .chartYScale(domain: 0...100)
        .historyXAxis(axis)
    }

    private func formatGb(_ gb: Double) -> String {
        if gb >= 1024 {
            return String(format: "%.1f TB", gb / 1024.0)
        }
        return String(format: "%.0f GB", gb)
    }
}
