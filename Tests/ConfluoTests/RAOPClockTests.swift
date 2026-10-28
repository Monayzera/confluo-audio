import XCTest
@testable import Confluo

final class RAOPClockTests: XCTestCase {
    private func ntp(_ seconds: Double) -> UInt64 {
        UInt64((seconds * 4_294_967_296).rounded())
    }

    private func synchronizedClock() -> RAOPClock {
        var clock = RAOPClock(ticksPerSecond: 1_000_000_000)
        clock.sent(7, at: 1_000_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_000.009), remoteSent: ntp(1_000.011), at: 1_020_000_000)
        return clock
    }

    func testSyncUsesSenderTimeInsteadOfPacketArrival() throws {
        let clock = synchronizedClock()
        let timestamp = ntp(1_000.5)
        let first = try XCTUnwrap(clock.hostTime(for: timestamp, at: 1_540_000_000))
        let delayed = try XCTUnwrap(clock.hostTime(for: timestamp, at: 1_900_000_000))
        XCTAssertEqual(Double(first), 1_500_000_000, accuracy: 1)
        XCTAssertEqual(first, delayed)
    }

    func testMapsTimestampBeforeTimingReference() throws {
        let host = try XCTUnwrap(synchronizedClock().hostTime(for: ntp(999.9), at: 1_100_000_000))
        XCTAssertEqual(Double(host), 900_000_000, accuracy: 1)
    }

    func testRejectsUnmatchedAndInvalidResponsesWithoutConsumingRequest() throws {
        var clock = RAOPClock(ticksPerSecond: 1_000_000_000)
        clock.sent(7, at: 1_000_000_000)
        clock.received(origin: 8, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 1_020_000_000)
        clock.received(origin: 7, remoteReceived: 0, remoteSent: ntp(1_000), at: 1_020_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_001), remoteSent: ntp(1_000), at: 1_020_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_000), remoteSent: ntp(1_001), at: 1_020_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 999_000_000)
        XCTAssertNil(clock.hostTime(for: ntp(1_000), at: 1_020_000_000))
        clock.received(origin: 7, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 1_020_000_000)
        let host = try XCTUnwrap(clock.hostTime(for: ntp(1_000), at: 1_020_000_000))
        XCTAssertEqual(host, 1_010_000_000)
    }

    func testPrefersLowerRoundTripAndIgnoresDuplicateResponse() throws {
        var clock = synchronizedClock()
        clock.sent(8, at: 2_000_000_000)
        clock.received(origin: 8, remoteReceived: ntp(1_001.15), remoteSent: ntp(1_001.15), at: 2_200_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_020), remoteSent: ntp(1_020), at: 2_200_000_000)
        let host = try XCTUnwrap(clock.hostTime(for: ntp(1_001.5), at: 2_600_000_000))
        XCTAssertEqual(Double(host), 2_500_000_000, accuracy: 1)
    }

    func testRejectsStaleResponsesAndExpiresClockSamples() {
        var clock = RAOPClock(ticksPerSecond: 1_000_000_000)
        clock.sent(7, at: 1_000_000_000)
        clock.received(origin: 7, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 3_000_000_000)
        XCTAssertNil(clock.hostTime(for: ntp(1_000), at: 3_000_000_000))
        XCTAssertNil(synchronizedClock().hostTime(for: ntp(1_030), at: 32_000_000_000))
        XCTAssertNil(synchronizedClock().hostTime(for: 0, at: 2_000_000_000))
    }

    func testNTPRolloverAndHostClockUnits() throws {
        var clock = RAOPClock(ticksPerSecond: 24_000_000)
        let beforeWrap = UInt64.max &- ntp(0.01) &+ 1
        clock.sent(7, at: 24_000_000)
        clock.received(origin: 7, remoteReceived: beforeWrap, remoteSent: ntp(0.01), at: 24_960_000)
        let host = try XCTUnwrap(clock.hostTime(for: ntp(0.5), at: 40_000_000))
        XCTAssertEqual(Double(host), 36_480_000, accuracy: 1)
    }

    func testRequestHistoryIsBounded() {
        var clock = RAOPClock(ticksPerSecond: 1_000_000_000)
        for token in UInt64(1)...9 {
            clock.sent(token, at: 1_000_000_000)
        }
        clock.received(origin: 1, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 1_020_000_000)
        XCTAssertNil(clock.hostTime(for: ntp(1_000), at: 1_020_000_000))
        clock.received(origin: 9, remoteReceived: ntp(1_000), remoteSent: ntp(1_000), at: 1_020_000_000)
        XCTAssertNotNil(clock.hostTime(for: ntp(1_000), at: 1_020_000_000))
    }
}
