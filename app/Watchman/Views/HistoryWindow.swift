import Charts
import SwiftUI

// MARK: - View model

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var powerBuckets:  [PowerAggregate]  = []
    @Published var gpuBuckets:    [GpuAggregate]    = []
    @Published var systemBuckets: [SystemAggregate] = []
    @Published var diskBuckets:   [DiskAggregate]   = []
    @Published var summary: PowerSummary = .empty
    @Published var isLoading = false

    @Published var window: PowerWindow = .day {
        didSet { Task { await reload() } }
    }
    @Published var selectedHost: String? = nil {
        didSet { Task { await reload() } }
    }

    private var refreshTimer: Timer?

    func start() {
        Task { await reload() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func reload() async {
        isLoading = true
        let host = selectedHost
        let win = window
        async let p = MetricStore.shared.reader.aggregate(hostname: host, window: win)
        async let g = MetricStore.shared.reader.gpuAggregate(hostname: host, window: win)
        async let s = MetricStore.shared.reader.systemAggregate(hostname: host, window: win)
        async let d = MetricStore.shared.reader.diskAggregate(hostname: host, window: win)
        async let sum = MetricStore.shared.reader.summary(hostname: host, window: win)
        let (pb, gb, sb, db, sm) = await (p, g, s, d, sum)
        powerBuckets = pb
        gpuBuckets = gb
        systemBuckets = sb
        diskBuckets = db
        summary = sm
        isLoading = false
    }
}

// MARK: - Window scene host

struct HistoryWindow: View {
    @ObservedObject var poller: MetricsPoller
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HistoryHeaderView(vm: vm, hosts: hostnames)
            TabView {
                PowerTab(vm: vm)
                    .tabItem { Label("Power", systemImage: "bolt.fill") }
                GpuTab(vm: vm)
                    .tabItem { Label("GPU", systemImage: "cpu") }
                SystemTab(vm: vm)
                    .tabItem { Label("System", systemImage: "memorychip") }
                DiskTab(vm: vm)
                    .tabItem { Label("Disk", systemImage: "internaldrive") }
            }
        }
        .padding(16)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .frame(minWidth: 680, minHeight: 480)
        .background(Theme.panelBg)
        .preferredColorScheme(.dark)
    }

    private var hostnames: [String] {
        poller.workers.compactMap { $0.metrics?.hostname }
    }
}

// MARK: - Shared header

struct HistoryHeaderView: View {
    @ObservedObject var vm: HistoryViewModel
    let hosts: [String]

    @State private var showingExport = false

    var body: some View {
        HStack(spacing: 12) {
            Text("History")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Picker("Worker", selection: $vm.selectedHost) {
                Text("All").tag(String?.none)
                ForEach(hosts, id: \.self) { h in
                    Text(h).tag(String?.some(h))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            Picker("Window", selection: $vm.window) {
                ForEach(PowerWindow.allCases) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Button {
                showingExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showingExport) {
            ExportView(availableHosts: hosts) { showingExport = false }
        }
    }
}
