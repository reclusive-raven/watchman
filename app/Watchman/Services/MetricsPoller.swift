import Combine
import Foundation
import SwiftUI

@MainActor
class MetricsPoller: ObservableObject {
    @Published var workers: [WorkerEntry] = []
    @Published var lastPollTime: Date?

    private var timer: Timer?
    private let session: URLSession
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    weak var alertsEngine: AlertsEngine?

    var overallStatus: OverallStatus {
        let states = workers.map(\.state)
        if states.allSatisfy({ $0 == .unreachable }) { return .allUnreachable }
        if states.contains(where: { $0 == .critical }) { return .someCritical }
        if states.contains(where: { $0 == .warning }) { return .someWarning }
        return .allGood
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: config)

        self.workers = Self.buildEntries(from: settings.workers, existing: [])

        settings.$workers
            .dropFirst()
            .sink { [weak self] configs in
                guard let self else { return }
                self.workers = Self.buildEntries(from: configs, existing: self.workers)
            }
            .store(in: &cancellables)

        startPolling()
    }

    /// Diff-by-id merge: preserve `WorkerEntry.state`/`metrics`/`lastUpdated`
    /// for unchanged ids; create fresh entries for new ids; drop removed ids.
    /// Entries for disabled workers are still created (so they show up in the
    /// detail list as "disabled") but are skipped at poll time.
    private static func buildEntries(from configs: [WorkerConfig], existing: [WorkerEntry]) -> [WorkerEntry] {
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return configs.compactMap { cfg -> WorkerEntry? in
            guard let url = cfg.url else { return nil }
            if var prior = byId[cfg.id] {
                prior.url = url
                prior.enabled = cfg.enabled
                return prior
            }
            return WorkerEntry(id: cfg.id, url: url, enabled: cfg.enabled)
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.fetchAll()
            }
        }
        // Fire immediately
        Task { await fetchAll() }
    }

    private func fetchAll() async {
        await withTaskGroup(of: (Int, WorkerMetrics?).self) { group in
            for (index, worker) in workers.enumerated() where worker.enabled {
                let url = worker.url
                let session = self.session
                group.addTask {
                    do {
                        let (data, _) = try await session.data(from: url)
                        let metrics = try JSONDecoder().decode(WorkerMetrics.self, from: data)
                        return (index, metrics)
                    } catch {
                        return (index, nil)
                    }
                }
            }

            for await (index, metrics) in group {
                guard index < workers.count else { continue }
                let worker = workers[index]
                if let metrics {
                    workers[index].update(with: metrics, settings: settings)
                    ingestSample(metrics)
                    SparklineHistory.shared.append(
                        workerId: worker.id,
                        value: settings.sparklineMetric.value(from: metrics)
                    )
                } else {
                    workers[index].markUnreachable()
                }
                alertsEngine?.evaluate(
                    workerId: worker.id,
                    alias: settings.alias(for: worker.id),
                    host: worker.url.host,
                    metrics: metrics
                )
            }
            lastPollTime = Date()
        }
    }

    private func ingestSample(_ m: WorkerMetrics) {
        let sample = MetricSample(
            timestamp: Date(),
            hostname: m.hostname,
            cpuW: m.power?.cpu_w.map(Double.init) ?? nil,
            gpuW: m.power?.gpu_w.map(Double.init) ?? nil,
            cpuUsagePct: Double(m.cpu.usage_percent),
            gpuUsagePct: Double(m.gpu?.usage_percent ?? 0),
            gpuTempC: m.gpu.map { Double($0.temp_c) },
            cpuTempC: m.temps.cpu_temp_c.map(Double.init),
            vramUsedMb: m.gpu?.vram_used_mb,
            vramTotalMb: m.gpu?.vram_total_mb,
            memUsedMb: m.memory.used_mb,
            memTotalMb: m.memory.total_mb,
            diskUsedGb: m.disk.used_gb,
            diskTotalGb: m.disk.total_gb,
            diskReadBps: m.io?.disk_read_bps,
            diskWriteBps: m.io?.disk_write_bps,
            netRxBps: m.io?.net_rx_bps,
            netTxBps: m.io?.net_tx_bps
        )
        Task { await MetricStore.shared.ingest(sample) }
    }

    deinit {
        timer?.invalidate()
    }
}
