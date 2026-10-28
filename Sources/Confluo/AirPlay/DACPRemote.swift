import Foundation
import Network

enum DACPCommand {
    case playPause
    case next
    case previous
    case volume(decibels: Double)

    var path: String {
        switch self {
        case .playPause: return "/ctrl-int/1/playpause"
        case .next: return "/ctrl-int/1/nextitem"
        case .previous: return "/ctrl-int/1/previtem"
        case .volume(let decibels): return String(format: "/ctrl-int/1/setproperty?dmcp.device-volume=%.6f", decibels)
        }
    }
}

final class DACPRemote {
    private let queue = DispatchQueue(label: "confluo.dacp")
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var pending: [String: [(DACPCommand, String)]] = [:]

    func start() {
        queue.async { [weak self] in
            self?.startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }

    func send(_ command: DACPCommand, dacpID: String, activeRemote: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = Self.serviceName(for: dacpID)
            if let endpoint = self.endpoints[key] {
                self.perform(command, endpoint: endpoint, activeRemote: activeRemote)
            } else {
                self.pending[key, default: []].append((command, activeRemote))
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.pending[key] = nil
                }
            }
        }
    }

    static func serviceName(for dacpID: String) -> String {
        "iTunes_Ctrl_\(dacpID)".uppercased()
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let created = NWBrowser(for: .bonjour(type: "_dacp._tcp", domain: nil), using: .tcp)
        created.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        created.stateUpdateHandler = { [weak self, weak created] state in
            if case .failed = state {
                created?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 5) {
                    self?.browser = nil
                    self?.startBrowser()
                }
            }
        }
        browser = created
        created.start(queue: queue)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [String: NWEndpoint] = [:]
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                next[name.uppercased()] = result.endpoint
            }
        }
        endpoints = next
        for (key, commands) in pending {
            guard let endpoint = next[key] else { continue }
            commands.forEach { perform($0.0, endpoint: endpoint, activeRemote: $0.1) }
            pending[key] = nil
        }
    }

    private func perform(_ command: DACPCommand, endpoint: NWEndpoint, activeRemote: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let request = "GET \(command.path) HTTP/1.1\r\nHost: starlight.local.\r\nActive-Remote: \(activeRemote)\r\nConnection: close\r\n\r\n"
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                        connection.cancel()
                    }
                })
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            connection.cancel()
        }
    }
}
