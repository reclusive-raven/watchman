import Foundation

/// Discovers `_watchman._tcp` agents on the local network via Bonjour.
/// Each discovered worker is published as `DiscoveredWorker` (name/host/port)
/// and filtered against the user's already-configured list by the view.
@MainActor
final class BonjourBrowser: NSObject, ObservableObject {
    struct DiscoveredWorker: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let host: String
        let port: Int
    }

    @Published private(set) var discovered: [DiscoveredWorker] = []

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard resolving.isEmpty && discovered.isEmpty else { return }
        browser.searchForServices(ofType: "_watchman._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for s in resolving { s.stop() }
        resolving.removeAll()
    }
}

extension BonjourBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let svc = service
        Task { @MainActor in
            svc.delegate = self
            svc.resolve(withTimeout: 5)
            self.resolving.append(svc)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            self.discovered.removeAll { $0.name == name }
            self.resolving.removeAll { $0.name == name }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let host = sender.hostName
        let port = sender.port
        Task { @MainActor in
            guard let host, port > 0 else { return }
            let worker = DiscoveredWorker(name: name, host: host, port: port)
            if !self.discovered.contains(where: { $0.name == worker.name }) {
                self.discovered.append(worker)
                self.discovered.sort { $0.name < $1.name }
            }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        let name = sender.name
        Task { @MainActor in
            self.resolving.removeAll { $0.name == name }
        }
    }
}
