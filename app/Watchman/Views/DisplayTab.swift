import SwiftUI

struct DisplayTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section(
                header: Text("Menu-bar sparkline"),
                footer: Text("A 60-sample trend drawn next to each worker's number. Choose which metric to plot.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                Picker("Metric", selection: $settings.sparklineMetricRaw) {
                    ForEach(SparklineMetric.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.sparklineMetricRaw) { _, _ in
                    SparklineHistory.shared.clear()
                }
            }
        }
        .formStyle(.grouped)
    }
}
