import SwiftUI

struct ThresholdsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section(
                header: Text("Usage (CPU / GPU / RAM)"),
                footer: Text("Percent. Red above the high mark; yellow between marks; green below.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                pctField("Red at / above",    value: $settings.usageRedPct)
                pctField("Yellow at / above", value: $settings.usageYellowPct)
            }

            Section(
                header: Text("Temperature"),
                footer: Text("Degrees Celsius. Red, orange, yellow thresholds applied in that order.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                degField("Red at / above",    value: $settings.tempRedC)
                degField("Orange at / above", value: $settings.tempOrangeC)
                degField("Yellow at / above", value: $settings.tempYellowC)
            }

            Section(
                header: Text("Worker state"),
                footer: Text("Used for the overall OK/WARN/CRIT status. GPU temp uses the Red (critical) and Orange (warning) thresholds above.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                pctField("RAM warning at %", value: $settings.ramWarningPct)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults", action: resetDefaults)
                        .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pctField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 180, alignment: .leading)
            TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("%").foregroundStyle(Theme.textSecondary)
            Stepper("", value: value, in: 0...100, step: 1)
                .labelsHidden()
            Spacer()
        }
    }

    private func degField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 180, alignment: .leading)
            TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("°C").foregroundStyle(Theme.textSecondary)
            Stepper("", value: value, in: 0...130, step: 1)
                .labelsHidden()
            Spacer()
        }
    }

    private func resetDefaults() {
        settings.usageRedPct = 85
        settings.usageYellowPct = 70
        settings.tempRedC = 85
        settings.tempOrangeC = 75
        settings.tempYellowC = 60
        settings.ramWarningPct = 90
    }
}
