import ConfluoDSP
import Foundation
import Network

final class SlotAllocator {
    private let lock = NSLock()
    private let slots: [UInt32]
    private var used: Set<UInt32> = []

    init(slots: [UInt32]) {
        self.slots = slots
    }

    func acquire() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots.first(where: { !used.contains($0) }) else { return nil }
        used.insert(slot)
        return slot
    }

    func release(_ slot: UInt32) {
        lock.lock()
        used.remove(slot)
        lock.unlock()
    }
}

struct SenderInfo: Equatable {
    let sessionID: UUID
    let slot: UInt32
    let name: String
    let identifier: String
    let dacpID: String?
    let activeRemote: String?
}

protocol RAOPSessionDelegate: AnyObject {
    func sessionDidBegin(_ session: RAOPSession, sender: SenderInfo)
    func session(_ session: RAOPSession, didChangeVolume decibels: Double)
    func session(_ session: RAOPSession, didChangeMetadata metadata: TrackMetadata)
    func session(_ session: RAOPSession, didChangeArtwork artwork: Data?)
    func sessionDidEnd(_ session: RAOPSession)
}

final class RAOPSession {
    static let receiverLatencyFrames = 11_025

    let id = UUID()
    weak var delegate: RAOPSessionDelegate?

    private let queue: DispatchQueue
    private let connection: NWConnection
    private let mixer: OpaquePointer
    private let slots: SlotAllocator
    private let hardwareAddress: Data
    private let onClose: (RAOPSession) -> Void

    private var buffer = Data()
    private var slot: UInt32?
    private var senderName = "iPhone"
    private var deviceIdentifier: String?
    private var dacpID: String?
    private var activeRemote: String?
    private var decoder: AudioPacketDecoder?
    private var decryptor: AudioPacketDecryptor?
    private var audioSocket: UDPSocket?
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var remoteControl: SocketAddress?
    private var remoteTiming: SocketAddress?
    private var timingTimer: DispatchSourceTimer?
    private var sampleRate = 44_100.0
    private var baseRTP: UInt32?
    private var lastRTP: UInt32 = 0
    private var lastExtended: Int64 = 0
    private var expectedSequence: UInt16?
    private var volumeDecibels = -15.0
    private var began = false
    private var ended = false
    private let pcm: UnsafeMutablePointer<Float>
    private let pcmCapacityFrames = 16_384
    private let decrypted: UnsafeMutableRawBufferPointer

    init(connection: NWConnection, mixer: OpaquePointer, slots: SlotAllocator, hardwareAddress: Data, onClose: @escaping (RAOPSession) -> Void) {
        self.connection = connection
        self.mixer = mixer
        self.slots = slots
        self.hardwareAddress = hardwareAddress
        self.onClose = onClose
        queue = DispatchQueue(label: "confluo.raop.session", qos: .userInteractive)
        pcm = .allocate(capacity: pcmCapacityFrames * 2)
        pcm.initialize(repeating: 0, count: pcmCapacityFrames * 2)
        decrypted = .allocate(byteCount: 65_536, alignment: 16)
    }

    deinit {
        pcm.deallocate()
        decrypted.deallocate()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.end()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.end()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if complete || error != nil {
                self.end()
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        while !ended {
            let request: RTSPRequest?
            do {
                request = try RTSPParser.next(from: &buffer)
            } catch {
                end()
                return
            }
            guard let request else { return }
            var response = handle(request)
            response.add("Audio-Jack-Status", "connected; type=analog")
            if request.method == "TEARDOWN" {
                connection.send(content: response.serialized(cseq: request.cseq), completion: .contentProcessed { [weak self] _ in
                    self?.end()
                })
                return
            }
            connection.send(content: response.serialized(cseq: request.cseq), completion: .contentProcessed { _ in })
        }
    }

    private func handle(_ request: RTSPRequest) -> RTSPResponse {
        var response = RTSPResponse()
        if let challenge = request.header("Apple-Challenge") {
            guard let signed = challengeResponse(challenge) else {
                return .status(500, "Internal Server Error")
            }
            response.add("Apple-Response", signed)
        }
        updateRemoteIdentity(request)
        switch request.method {
        case "OPTIONS":
            response.add("Public", "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER")
        case "ANNOUNCE":
            return merge(response, handleAnnounce(request))
        case "SETUP":
            return merge(response, handleSetup(request))
        case "RECORD":
            response.add("Audio-Latency", "\(Self.receiverLatencyFrames)")
        case "FLUSH":
            flushTimeline()
        case "TEARDOWN", "PAUSE":
            break
        case "SET_PARAMETER":
            handleSetParameter(request)
        case "GET_PARAMETER":
            if String(decoding: request.body, as: UTF8.self).contains("volume") {
                response.add("Content-Type", "text/parameters")
                response.body = Data(String(format: "volume: %.6f\r\n", volumeDecibels).utf8)
            }
        case "POST" where request.uri == "/feedback":
            break
        default:
            return merge(response, .status(501, "Not Implemented"))
        }
        return response
    }

    private func merge(_ base: RTSPResponse, _ result: RTSPResponse) -> RTSPResponse {
        var merged = result
        merged.headers = base.headers + result.headers
        return merged
    }

    private func challengeResponse(_ challenge: String) -> String? {
        guard let challengeData = SessionDescription.decodeBase64(challenge),
              case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return nil }
        let address: Data
        switch host {
        case .ipv4(let value):
            address = value.rawValue
        case .ipv6(let value):
            let raw = value.rawValue
            if raw.count == 16, raw.prefix(12) == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]) {
                address = raw.suffix(4)
            } else {
                address = raw
            }
        default:
            return nil
        }
        return try? RAOPCrypto.challengeResponse(challenge: challengeData, localAddress: address, hardwareAddress: hardwareAddress)
    }

    private func updateRemoteIdentity(_ request: RTSPRequest) {
        if let value = request.header("DACP-ID"), !value.isEmpty {
            dacpID = value
        }
        if let value = request.header("Active-Remote"), !value.isEmpty {
            activeRemote = value
        }
        if let value = request.header("X-Apple-Client-Name"), !value.isEmpty {
            senderName = value
        }
        if let value = request.header("X-Apple-Device-ID"), !value.isEmpty {
            deviceIdentifier = value
        }
    }

    private func handleAnnounce(_ request: RTSPRequest) -> RTSPResponse {
        let description = SessionDescription.parse(request.body)
        do {
            decoder = try AudioDecoderFactory.make(for: description.codec)
        } catch {
            return .status(415, "Unsupported Media Type")
        }
        switch (description.encryptedKey, description.initializationVector) {
        case let (key?, iv?):
            do {
                decryptor = try AudioPacketDecryptor(key: try RAOPCrypto.decryptSessionKey(key), iv: iv)
            } catch {
                return .status(400, "Bad Request")
            }
        case (nil, nil):
            decryptor = nil
        default:
            return .status(400, "Bad Request")
        }
        if request.header("X-Apple-Client-Name") == nil, let name = description.senderName {
            senderName = name
        }
        sampleRate = description.sampleRate
        if slot == nil {
            guard let acquired = slots.acquire() else {
                return .status(453, "Not Enough Bandwidth")
            }
            slot = acquired
        }
        guard let slot else { return .status(500, "Internal Server Error") }
        cf_source_begin(mixer, slot, CF_MODE_TIMED, sampleRate)
        resetTimeline()
        if !began {
            began = true
            let info = SenderInfo(
                sessionID: id,
                slot: slot,
                name: senderName,
                identifier: deviceIdentifier ?? dacpID ?? senderName,
                dacpID: dacpID,
                activeRemote: activeRemote
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.sessionDidBegin(self, sender: info)
            }
        }
        return RTSPResponse()
    }

    private func handleSetup(_ request: RTSPRequest) -> RTSPResponse {
        guard let transport = request.header("Transport"),
              let controlPort = Self.port(named: "control_port", in: transport),
              let timingPort = Self.port(named: "timing_port", in: transport),
              case .hostPort(let host, _) = connection.endpoint else {
            return .status(400, "Bad Request")
        }
        do {
            if audioSocket == nil {
                audioSocket = try UDPSocket(queue: queue) { [weak self] bytes in
                    self?.handleAudioPacket(bytes)
                }
            }
            if controlSocket == nil {
                controlSocket = try UDPSocket(queue: queue) { [weak self] bytes in
                    self?.handleControlPacket(bytes)
                }
            }
            if timingSocket == nil {
                timingSocket = try UDPSocket(queue: queue) { [weak self] bytes in
                    self?.handleTimingPacket(bytes)
                }
            }
        } catch {
            return .status(500, "Internal Server Error")
        }
        remoteControl = SocketAddress(host: host, port: controlPort)
        remoteTiming = SocketAddress(host: host, port: timingPort)
        startTimingRequests()
        guard let audioPort = audioSocket?.port, let localControl = controlSocket?.port, let localTiming = timingSocket?.port else {
            return .status(500, "Internal Server Error")
        }
        var response = RTSPResponse()
        response.add("Transport", "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(localControl);timing_port=\(localTiming);server_port=\(audioPort)")
        response.add("Session", "1")
        return response
    }

    static func port(named name: String, in transport: String) -> UInt16? {
        for component in transport.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name {
                return UInt16(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func handleSetParameter(_ request: RTSPRequest) {
        let type = request.contentType
        if type.hasPrefix("text/parameters") {
            let text = String(decoding: request.body, as: UTF8.self)
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "volume",
                      let value = Double(parts[1].trimmingCharacters(in: .whitespaces)), value.isFinite else { continue }
                volumeDecibels = value
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.session(self, didChangeVolume: value)
                }
            }
        } else if type.hasPrefix("application/x-dmap-tagged") {
            let metadata = DMAP.metadata(from: request.body)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didChangeMetadata: metadata)
            }
        } else if type.hasPrefix("image/") {
            let artwork: Data? = (type.hasPrefix("image/none") || request.body.isEmpty) ? nil : request.body
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didChangeArtwork: artwork)
            }
        }
    }

    private func resetTimeline() {
        baseRTP = nil
        lastRTP = 0
        lastExtended = 0
        expectedSequence = nil
    }

    private func flushTimeline() {
        guard let slot else { return }
        cf_source_flush(mixer, slot)
        resetTimeline()
    }

    private func establishBase(_ rtp: UInt32) {
        if baseRTP == nil {
            baseRTP = rtp
            lastRTP = rtp
            lastExtended = 0
        }
    }

    private func extendedIndex(_ rtp: UInt32) -> Int64 {
        lastExtended + Int64(Int32(bitPattern: rtp &- lastRTP))
    }

    private func advance(_ rtp: UInt32) -> Int64 {
        establishBase(rtp)
        let index = extendedIndex(rtp)
        if index > lastExtended {
            lastExtended = index
            lastRTP = rtp
        }
        return index
    }

    private func handleAudioPacket(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 12 else { return }
        let type = bytes[1] & 0x7F
        if type == 0x60 {
            ingest(bytes, retransmitted: false)
        } else if type == 0x56, bytes.count > 16 {
            ingest(UnsafeRawBufferPointer(rebasing: bytes[4...]), retransmitted: true)
        }
    }

    private func handleControlPacket(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 4 else { return }
        let type = bytes[1] & 0x7F
        if type == 0x54, bytes.count >= 20 {
            handleSync(bytes)
        } else if type == 0x56, bytes.count > 16 {
            ingest(UnsafeRawBufferPointer(rebasing: bytes[4...]), retransmitted: true)
        }
    }

    private func handleSync(_ bytes: UnsafeRawBufferPointer) {
        guard let slot else { return }
        let arrival = HostClock.now()
        let rtpLessLatency = Self.read32(bytes, 4)
        let rtpNow = Self.read32(bytes, 16)
        establishBase(rtpNow)
        let extra = UInt32((Double(Self.receiverLatencyFrames) * sampleRate / 44_100).rounded())
        let audible = rtpLessLatency &- extra
        cf_source_set_anchor(mixer, slot, arrival, Double(extendedIndex(audible)))
    }

    private func ingest(_ packet: UnsafeRawBufferPointer, retransmitted: Bool) {
        guard let slot, let decoder, packet.count > 12 else { return }
        let sequence = Self.read16(packet, 2)
        let rtp = Self.read32(packet, 4)
        if !retransmitted {
            trackSequence(sequence)
        }
        let payload = UnsafeRawBufferPointer(rebasing: packet[12...])
        guard payload.count <= decrypted.count else { return }
        let audio: UnsafeRawBufferPointer
        if let decryptor {
            guard decryptor.decrypt(payload, into: decrypted) else { return }
            audio = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(decrypted)[0..<payload.count])
        } else {
            audio = payload
        }
        guard decoder.maximumFramesPerPacket <= pcmCapacityFrames else { return }
        let frames = decoder.decode(audio, into: pcm)
        guard frames > 0 else { return }
        let index = advance(rtp)
        if !cf_source_write(mixer, slot, index, pcm, UInt32(frames)) {
            cf_source_flush(mixer, slot)
            resetTimeline()
            let restarted = advance(rtp)
            _ = cf_source_write(mixer, slot, restarted, pcm, UInt32(frames))
        }
    }

    private func trackSequence(_ sequence: UInt16) {
        guard let expected = expectedSequence else {
            expectedSequence = sequence &+ 1
            return
        }
        let gap = Int16(bitPattern: sequence &- expected)
        if gap == 0 {
            expectedSequence = sequence &+ 1
        } else if gap > 0 {
            if gap < 256 {
                requestResend(first: expected, count: UInt16(gap))
            }
            expectedSequence = sequence &+ 1
        }
    }

    private func requestResend(first: UInt16, count: UInt16) {
        guard let controlSocket, let remoteControl else { return }
        let packet: [UInt8] = [0x80, 0xD5, 0x00, 0x01, UInt8(first >> 8), UInt8(first & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)]
        controlSocket.send(packet, to: remoteControl)
    }

    private func handleTimingPacket(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 32, bytes[1] & 0x7F == 0x52, let timingSocket, let remoteTiming else { return }
        let received = Self.ntpNow()
        var reply = [UInt8](repeating: 0, count: 32)
        reply[0] = 0x80
        reply[1] = 0xD3
        reply[2] = bytes[2]
        reply[3] = bytes[3]
        for offset in 0..<8 {
            reply[8 + offset] = bytes[24 + offset]
        }
        Self.write64(&reply, 16, received)
        Self.write64(&reply, 24, Self.ntpNow())
        timingSocket.send(reply, to: remoteTiming)
    }

    private func startTimingRequests() {
        guard timingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.sendTimingRequest()
        }
        timer.resume()
        timingTimer = timer
    }

    private func sendTimingRequest() {
        guard let timingSocket, let remoteTiming else { return }
        var request = [UInt8](repeating: 0, count: 32)
        request[0] = 0x80
        request[1] = 0xD2
        request[3] = 0x07
        Self.write64(&request, 24, Self.ntpNow())
        timingSocket.send(request, to: remoteTiming)
    }

    private func end() {
        guard !ended else { return }
        ended = true
        timingTimer?.cancel()
        timingTimer = nil
        audioSocket?.close()
        controlSocket?.close()
        timingSocket?.close()
        audioSocket = nil
        controlSocket = nil
        timingSocket = nil
        if let slot {
            cf_source_end(mixer, slot)
            slots.release(slot)
        }
        slot = nil
        connection.cancel()
        let wasBegun = began
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if wasBegun {
                self.delegate?.sessionDidEnd(self)
            }
            self.onClose(self)
        }
    }

    static func read16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func write64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> (56 - 8 * UInt64(index))) & 0xFF)
        }
    }

    static func ntpNow() -> UInt64 {
        let now = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = floor(now)
        let fraction = (now - seconds) * 4_294_967_296
        return UInt64(seconds) << 32 | UInt64(fraction)
    }
}
