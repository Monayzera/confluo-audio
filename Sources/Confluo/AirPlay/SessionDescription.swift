import Foundation

enum AudioCodec: Equatable {
    case alac(parameters: [Int])
    case pcm16BigEndian(sampleRate: Int, channels: Int)
    case unsupported(String)
}

struct SessionDescription {
    var codec: AudioCodec = .unsupported("")
    var encryptedKey: Data?
    var initializationVector: Data?
    var minimumLatency: Int?
    var senderName: String?

    var sampleRate: Double {
        switch codec {
        case .alac(let parameters):
            return Double(parameters.count >= 11 ? parameters[10] : 44_100)
        case .pcm16BigEndian(let sampleRate, _):
            return Double(sampleRate)
        case .unsupported:
            return 44_100
        }
    }

    var framesPerPacket: Int {
        if case .alac(let parameters) = codec, let first = parameters.first, first > 0 {
            return first
        }
        return 352
    }

    static func parse(_ data: Data) -> SessionDescription {
        var result = SessionDescription()
        var rtpmap = ""
        var fmtp: [Int] = []
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("a=rtpmap:") {
                let value = line.dropFirst("a=rtpmap:".count)
                rtpmap = value.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            } else if line.hasPrefix("a=fmtp:") {
                fmtp = line.dropFirst("a=fmtp:".count).split(separator: " ").dropFirst().compactMap { Int($0) }
            } else if line.hasPrefix("a=rsaaeskey:") {
                result.encryptedKey = decodeBase64(String(line.dropFirst("a=rsaaeskey:".count)))
            } else if line.hasPrefix("a=aesiv:") {
                result.initializationVector = decodeBase64(String(line.dropFirst("a=aesiv:".count)))
            } else if line.hasPrefix("a=min-latency:") {
                result.minimumLatency = Int(line.dropFirst("a=min-latency:".count))
            } else if line.hasPrefix("i=") {
                let name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    result.senderName = name
                }
            }
        }
        let lowered = rtpmap.lowercased()
        if lowered.hasPrefix("applelossless") {
            result.codec = .alac(parameters: fmtp.count >= 11 ? Array(fmtp.prefix(11)) : [352, 0, 16, 40, 10, 14, 2, 255, 0, 0, 44_100])
        } else if lowered.hasPrefix("l16") {
            let parts = rtpmap.split(separator: "/")
            let rate = parts.count > 1 ? Int(parts[1]) ?? 44_100 : 44_100
            let channels = parts.count > 2 ? Int(parts[2]) ?? 2 : 2
            result.codec = .pcm16BigEndian(sampleRate: rate, channels: channels)
        } else {
            result.codec = .unsupported(rtpmap)
        }
        return result
    }

    static func decodeBase64(_ value: String) -> Data? {
        var text = value.trimmingCharacters(in: .whitespaces)
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: text)
    }
}
