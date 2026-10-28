import Foundation

struct TrackMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil
    }
}

enum DMAP {
    private static let containers: Set<String> = ["mlit", "cmst", "mdcl", "mlcl"]

    static func metadata(from data: Data) -> TrackMetadata {
        var result = TrackMetadata()
        walk([UInt8](data), 0, data.count, &result, depth: 0)
        return result
    }

    private static func walk(_ bytes: [UInt8], _ start: Int, _ end: Int, _ result: inout TrackMetadata, depth: Int) {
        guard depth < 8 else { return }
        var index = start
        while index + 8 <= end {
            let code = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
            let length = Int(UInt32(bytes[index + 4]) << 24 | UInt32(bytes[index + 5]) << 16 | UInt32(bytes[index + 6]) << 8 | UInt32(bytes[index + 7]))
            let valueStart = index + 8
            let valueEnd = valueStart + length
            guard length >= 0, valueEnd <= end else { return }
            if containers.contains(code) {
                walk(bytes, valueStart, valueEnd, &result, depth: depth + 1)
            } else {
                let text = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = text.isEmpty ? nil : text
                switch code {
                case "minm": result.title = value
                case "asar": result.artist = value
                case "asal": result.album = value
                default: break
                }
            }
            index = valueEnd
        }
    }
}
