import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var alerts: AlertsEngine
    let workers: [WorkerEntry]

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkersTab(settings: settings)
                .tabItem { Label("Workers", systemImage: "server.rack") }
            ThresholdsTab(settings: settings)
                .tabItem { Label("Thresholds", systemImage: "gauge.with.dots.needle.67percent") }
            DisplayTab(settings: settings)
                .tabItem { Label("Display", systemImage: "chart.xyaxis.line") }
            AlertsTab(settings: settings, alerts: alerts)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
        }
        .frame(width: 520, height: 560)
        .background(Theme.panelBg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section(
                header: Text("Energy cost"),
                footer: Text("Shown next to total kWh in the Power History window. Set to 0 to hide.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                HStack {
                    Text("$ / kWh")
                        .frame(width: 100, alignment: .leading)
                    TextField("0.00", value: $settings.costPerKwh, format: .number.precision(.fractionLength(0...4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Workers

private struct WorkersTab: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var browser = BonjourBrowser()

    @State private var draftId = ""
    @State private var draftHost = ""
    @State private var draftPort = "8085"
    @State private var draftAlias = ""

    var body: some View {
        Form {
            Section(
                header: Text("Configured workers"),
                footer: Text("Changes apply immediately. Disable a worker to stop polling without removing it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                if settings.workers.isEmpty {
                    Text("No workers configured. Add one below.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(settings.workers) { config in
                        WorkerRow(
                            config: config,
                            onUpdate: { settings.updateWorker($0) },
                            onRemove: { settings.removeWorker(id: config.id) }
                        )
                    }
                }
            }

            Section(
                header: Text("Discovered on network"),
                footer: Text("Agents advertising `_watchman._tcp` via Bonjour. Click + to add one to the configured list.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            ) {
                let undiscovered = browser.discovered.filter { disc in
                    !settings.workers.contains(where: { $0.host == disc.host })
                }
                if undiscovered.isEmpty {
                    Text(browser.discovered.isEmpty
                         ? "Scanning…"
                         : "All discovered workers are already configured.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(undiscovered) { disc in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(disc.name)
                                    .font(.system(size: 12, design: .monospaced))
                                Text("\(disc.host):\(disc.port)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button {
                                addDiscovered(disc)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            Section("Add worker") {
                HStack {
                    TextField("id (e.g. worker-2, rog)", text: $draftId)
                        .textFieldStyle(.roundedBorder)
                    TextField("host", text: $draftHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("port", text: $draftPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                HStack {
                    TextField("alias (optional)", text: $draftAlias)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                    Button("Add") { addDraft() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!canAdd)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func addDiscovered(_ disc: BonjourBrowser.DiscoveredWorker) {
        // Pick an id derived from the service name; fall back to the host
        // with dots stripped if a collision occurs.
        var id = disc.name.replacingOccurrences(of: "watchman-", with: "")
        if id.isEmpty || settings.workers.contains(where: { $0.id == id }) {
            id = disc.host.replacingOccurrences(of: ".local.", with: "")
                          .replacingOccurrences(of: ".local", with: "")
        }
        settings.addWorker(WorkerConfig(
            id: id,
            host: disc.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            port: disc.port,
            alias: "",
            enabled: true
        ))
    }

    private var canAdd: Bool {
        let id = draftId.trimmingCharacters(in: .whitespaces)
        let host = draftHost.trimmingCharacters(in: .whitespaces)
        let port = Int(draftPort.trimmingCharacters(in: .whitespaces)) ?? 0
        return !id.isEmpty
            && !host.isEmpty
            && port > 0 && port < 65_536
            && !settings.workers.contains(where: { $0.id == id })
    }

    private func addDraft() {
        guard canAdd, let port = Int(draftPort) else { return }
        settings.addWorker(WorkerConfig(
            id: draftId.trimmingCharacters(in: .whitespaces),
            host: draftHost.trimmingCharacters(in: .whitespaces),
            port: port,
            alias: draftAlias.trimmingCharacters(in: .whitespaces),
            enabled: true
        ))
        draftId = ""
        draftHost = ""
        draftPort = "8085"
        draftAlias = ""
    }
}

private struct WorkerRow: View {
    let config: WorkerConfig
    let onUpdate: (WorkerConfig) -> Void
    let onRemove: () -> Void

    @State private var host: String
    @State private var port: String
    @State private var alias: String
    @State private var enabled: Bool

    init(config: WorkerConfig, onUpdate: @escaping (WorkerConfig) -> Void, onRemove: @escaping () -> Void) {
        self.config = config
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        _host = State(initialValue: config.host)
        _port = State(initialValue: "\(config.port)")
        _alias = State(initialValue: config.alias)
        _enabled = State(initialValue: config.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(config.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 90, alignment: .leading)
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, _ in commit() }
                Spacer()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                TextField("host", text: $host, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                TextField("port", text: $port, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                TextField("alias", text: $alias, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 4)
    }

    private func commit() {
        guard let portInt = Int(port), portInt > 0 else { return }
        onUpdate(WorkerConfig(
            id: config.id,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            alias: alias.trimmingCharacters(in: .whitespaces),
            enabled: enabled
        ))
    }
}
