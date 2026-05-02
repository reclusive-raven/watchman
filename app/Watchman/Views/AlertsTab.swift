import SwiftUI
import UserNotifications

struct AlertsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var alerts: AlertsEngine

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                if alerts.authorizationStatus == .denied {
                    permissionDeniedBanner
                }
            }

            Section("Worker unreachable") {
                Toggle("Alert when a worker becomes unreachable",
                       isOn: $settings.alertUnreachableEnabled)
                intField("Trigger after N consecutive missed polls",
                         value: $settings.unreachableMissesTrigger)
            }

            Section("GPU temperature") {
                Toggle("Alert on high GPU temp",
                       isOn: $settings.alertGpuTempEnabled)
                numericField("Trigger (°C)", value: $settings.gpuTempTrigger)
                numericField("Clear (°C)",   value: $settings.gpuTempClear)
            }

            Section("GPU utilisation crash") {
                Toggle("Alert when training appears to have crashed",
                       isOn: $settings.alertGpuCrashEnabled)
                numericField("High threshold (%)",  value: $settings.gpuCrashHighPct)
                numericField("Low threshold (%)",   value: $settings.gpuCrashLowPct)
                numericField("Sustained for (s)",   value: $settings.gpuCrashSustainedSec)
            }

            Section("VRAM") {
                Toggle("Alert on high VRAM usage",
                       isOn: $settings.alertVramEnabled)
                numericField("Trigger (%)", value: $settings.vramTrigger)
                numericField("Clear (%)",   value: $settings.vramClear)
            }

            Section("Disk") {
                Toggle("Alert on high disk usage",
                       isOn: $settings.alertDiskEnabled)
                numericField("Trigger (%)", value: $settings.diskTrigger)
                numericField("Clear (%)",   value: $settings.diskClear)
            }
        }
        .formStyle(.grouped)
    }

    private var permissionDeniedBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are blocked in System Settings.")
                    .font(.caption)
                Text("Watchman cannot deliver alerts until you re-enable them.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Open System Settings") {
                alerts.openSystemNotificationsSettings()
            }
            .controlSize(.small)
        }
    }

    private func numericField(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }

    private func intField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}
