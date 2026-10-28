import Foundation

struct RTSPRequest {
    let method: String
    let uri: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var cseq: String? {
        header("CSeq")
    }

    var contentType: String {
        (header("Content-Type") ?? "").lowercased()
    }
}

struct RTSPResponse {
    var status: Int = 200
    var reason: String = "OK"
    var headers: [(String, String)] = []
    var body = Data()

    static func status(_ status: Int, _ reason: String) -> RTSPResponse {
        RTSPResponse(status: status, reason: reason)
    }

    mutating func add(_ name: String, _ value: String) {
        headers.append((name, value))
    }

    func serialized(cseq: String?) -> Data {
        var text = "RTSP/1.0 \(status) \(reason)\r\n"
        if let cseq {
            text += "CSeq: \(cseq)\r\n"
        }
        text += "Server: AirTunes/105.1\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        if !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

enum RTSPParseError: Error {
    case malformed
    case tooLarge
}

enum RTSPParser {
    static let maximumHeaderBytes = 64 * 1024
    static let maximumBodyBytes = 8 * 1024 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    static func next(from buffer: inout Data) throws -> RTSPRequest? {
        guard let range = buffer.range(of: separator) else {
            if buffer.count > maximumHeaderBytes {
                throw RTSPParseError.tooLarge
            }
            return nil
        }
        let headerData = buffer[buffer.startIndex..<range.lowerBound]
        let text = String(decoding: headerData, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw RTSPParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw RTSPParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maximumBodyBytes else { throw RTSPParseError.tooLarge }
        let bodyStart = range.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return RTSPRequest(method: String(requestLine[0]), uri: String(requestLine[1]), headers: headers, body: body)
    }
}
