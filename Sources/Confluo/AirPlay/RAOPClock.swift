struct RAOPClock {
    private struct Request {
        let timestamp: UInt64
        let host: UInt64
    }

    private struct Sample {
        let remote: UInt64
        let host: Double
        let received: UInt64
        let roundTrip: Double
    }

    let ticksPerSecond: Double
    private var requests: [Request] = []
    private var samples: [Sample] = []

    init(ticksPerSecond: Double) {
        self.ticksPerSecond = ticksPerSecond
    }

    mutating func sent(_ timestamp: UInt64, at host: UInt64) {
        requests.append(Request(timestamp: timestamp, host: host))
        if requests.count > 8 {
            requests.removeFirst()
        }
    }

    mutating func received(origin: UInt64, remoteReceived: UInt64, remoteSent: UInt64, at host: UInt64) {
        guard let index = requests.firstIndex(where: { $0.timestamp == origin }),
              remoteReceived != 0, remoteSent != 0, host >= requests[index].host else { return }
        let elapsed = Double(host - requests[index].host) / ticksPerSecond
        let processing = Self.seconds(from: remoteReceived, to: remoteSent)
        guard elapsed <= 1, processing >= 0, processing <= elapsed else { return }
        requests.remove(at: index)
        let roundTrip = elapsed - processing
        samples.removeAll { host >= $0.received && Double(host - $0.received) / ticksPerSecond > 30 }
        samples.append(Sample(remote: remoteSent, host: Double(host) - roundTrip * ticksPerSecond / 2, received: host, roundTrip: roundTrip))
        if samples.count > 8 {
            samples.removeFirst()
        }
    }

    func hostTime(for timestamp: UInt64, at arrival: UInt64) -> UInt64? {
        guard timestamp != 0,
              let sample = samples.filter({ arrival >= $0.received && Double(arrival - $0.received) / ticksPerSecond <= 30 }).min(by: { $0.roundTrip < $1.roundTrip }) else { return nil }
        let delta = Self.seconds(from: sample.remote, to: timestamp)
        guard abs(delta) <= 30 else { return nil }
        let host = sample.host + delta * ticksPerSecond
        guard host >= 0, host < Double(UInt64.max) else { return nil }
        return UInt64(host.rounded(.down))
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(Int64(bitPattern: end &- start)) / 4_294_967_296
    }
}
