import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet-style export dialog. Offers date range + worker filter, then
/// streams the raw `metric_samples` table to the CSV file the user picks.
struct ExportView: View {
    let availableHosts: [String]
    let onClose: () -> Void

    @State private var fromDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var toDate: Date = Date()
    @State private var selectedHosts: Set<String> = []
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export raw samples")
                .font(.title3.bold())
                .foregroundStyle(Theme.textPrimary)

            Form {
                Section("Date range") {
                    DatePicker("From", selection: $fromDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("To",   selection: $toDate,   displayedComponents: [.date, .hourAndMinute])
                }

                Section(
                    header: Text("Workers"),
                    footer: Text(footerText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                ) {
                    if availableHosts.isEmpty {
                        Text("No workers have reported yet.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(availableHosts, id: \.self) { host in
                            Toggle(host, isOn: Binding(
                                get: { selectedHosts.contains(host) },
                                set: { isOn in
                                    if isOn { selectedHosts.insert(host) }
                                    else    { selectedHosts.remove(host) }
                                }
                            ))
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let lastResult {
                    Section {
                        Text(lastResult)
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
                    .disabled(isExporting)
                Button {
                    Task { await runExport() }
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Export…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(isExporting || fromDate > toDate)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .background(Theme.panelBg)
        .preferredColorScheme(.dark)
    }

    @MainActor
    private func runExport() async {
        errorMessage = nil
        lastResult = nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName()
        panel.title = "Export raw samples"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        defer { isExporting = false }

        let workers = selectedHosts.isEmpty ? nil : Array(selectedHosts)
        do {
            let count = try await MetricsExporter.exportRawCsv(
                workers: workers,
                from: fromDate,
                to: toDate,
                destination: url
            )
            lastResult = "Wrote \(count) row\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "watchman_\(f.string(from: fromDate))_\(f.string(from: toDate)).csv"
    }

    private var footerText: String {
        if selectedHosts.isEmpty {
            return "No workers selected means export everything."
        }
        let list = selectedHosts.sorted().joined(separator: ", ")
        return "Selected: \(list)"
    }
}
