import Foundation
import Network

final class RAOPServer {
    enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    weak var sessionDelegate: RAOPSessionDelegate?

    private let mixer: OpaquePointer
    private let slots: SlotAllocator
    private let hardwareAddress: Data
    private let queue = DispatchQueue(label: "confluo.raop.listener")
    private var listener: NWListener?
    private var sessions: [UUID: RAOPSession] = [:]
    private var serviceName = "Confluo"
    private var retryWorkItem: DispatchWorkItem?

    init(mixer: OpaquePointer, slots: SlotAllocator, hardwareAddress: Data) {
        self.mixer = mixer
        self.slots = slots
        self.hardwareAddress = hardwareAddress
    }

    static func txtRecord() -> NWTXTRecord {
        NWTXTRecord([
            "txtvers": "1",
            "ch": "2",
            "cn": "0,1",
            "et": "0,1",
            "ek": "1",
            "sr": "44100",
            "ss": "16",
            "da": "true",
            "sv": "false",
            "pw": "false",
            "tp": "UDP",
            "vn": "65537",
            "vs": "105.1",
            "md": "0,1,2",
            "am": "Confluo",
            "sf": "0x4",
            "fv": "76400.10"
        ])
    }

    var bonjourName: String {
        hardwareAddress.map { String(format: "%02X", $0) }.joined() + "@" + serviceName
    }

    func start(name: String) {
        serviceName = Self.sanitized(name)
        retryWorkItem?.cancel()
        listener?.cancel()
        listener = nil
        onStateChange?(.starting)
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let created = try NWListener(using: parameters)
            created.service = NWListener.Service(name: bonjourName, type: "_raop._tcp", domain: nil, txtRecord: Self.txtRecord())
            created.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.accept(connection)
                }
            }
            created.stateUpdateHandler = { [weak self, weak created] state in
                DispatchQueue.main.async {
                    guard let self, let created, self.listener === created else { return }
                    self.handle(state, listener: created)
                }
            }
            listener = created
            created.start(queue: queue)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            scheduleRetry()
        }
    }

    func rename(_ name: String) {
        let sanitized = Self.sanitized(name)
        guard sanitized != serviceName else { return }
        serviceName = sanitized
        listener?.service = NWListener.Service(name: bonjourName, type: "_raop._tcp", domain: nil, txtRecord: Self.txtRecord())
    }

    func stop() {
        retryWorkItem?.cancel()
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.disconnect() }
        onStateChange?(.stopped)
    }

    func disconnect(sessionID: UUID) {
        sessions[sessionID]?.disconnect()
    }

    static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: " ")
        let limited = String(trimmed.prefix(48))
        return limited.isEmpty ? "Confluo" : limited
    }

    private func handle(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            onStateChange?(.ready(port: listener.port?.rawValue ?? 0))
        case .failed(let error):
            onStateChange?(.failed(error.localizedDescription))
            listener.cancel()
            self.listener = nil
            scheduleRetry()
        case .waiting(let error):
            onStateChange?(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.listener == nil else { return }
            self.start(name: self.serviceName)
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func accept(_ connection: NWConnection) {
        let session = RAOPSession(connection: connection, mixer: mixer, slots: slots, hardwareAddress: hardwareAddress) { [weak self] closed in
            self?.sessions[closed.id] = nil
        }
        session.delegate = sessionDelegate
        sessions[session.id] = session
        session.start()
    }
}
