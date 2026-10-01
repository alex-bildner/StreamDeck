import Foundation
import Network

final class MacBrowser: ObservableObject {
    @Published var found: [DiscoveredMac] = []
    private var browser: NWBrowser?

    func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_deck._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                if case let .service(name, _, _, _) = result.endpoint {
                    return DiscoveredMac(name: name, host: "", port: 0)
                }
                return nil
            }
            Task { @MainActor in
                self?.resolve(results, names: macs.map(\.name))
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func resolve(_ results: Set<NWBrowser.Result>, names: [String]) {
        found.removeAll { !names.contains($0.name) }
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if found.contains(where: { $0.name == name && !$0.host.isEmpty }) { continue }
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let connection else { return }
                if let path = connection.currentPath,
                   case let .hostPort(host, port) = path.remoteEndpoint ?? result.endpoint {
                    let address = hostAddress(host)
                    let value = port.rawValue
                    Task { @MainActor in
                        guard let self, !address.isEmpty else { return }
                        let mac = DiscoveredMac(name: name, host: address, port: Int(value))
                        if let index = self.found.firstIndex(where: { $0.name == name }) {
                            self.found[index] = mac
                        } else {
                            self.found.append(mac)
                        }
                    }
                }
                connection.cancel()
            }
            connection.start(queue: .main)
        }
    }
}

private func hostAddress(_ host: NWEndpoint.Host) -> String {
    let raw: String
    switch host {
    case .ipv4(let address):
        raw = "\(address)"
    case .name(let name, _):
        raw = name
    default:
        return ""
    }
    return stripInterface(raw)
}
