import AudioToolbox
import ConfluoDSP
import Foundation
import XCTest
@testable import Confluo

final class AudioTests: XCTestCase {
    private func makeMixer(capacity: UInt32 = 1 << 16) throws -> OpaquePointer {
        try XCTUnwrap(cf_mixer_create(2, capacity, 1_000_000_000))
    }

    func testTimedSourceFollowsAnchor() throws {
        let mixer = try makeMixer()
        defer { cf_mixer_destroy(mixer) }
        cf_mixer_set_output(mixer, 48_000, 0)
        cf_source_begin(mixer, 0, CF_MODE_TIMED, 48_000)
        let frames = 40_000
        var ramp = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            ramp[index * 2] = Float(index) / 100_000
            ramp[index * 2 + 1] = -Float(index) / 100_000
        }
        XCTAssertTrue(cf_source_write(mixer, 0, 0, ramp, UInt32(frames / 2)))
        XCTAssertTrue(cf_source_write(mixer, 0, Int64(frames / 2), Array(ramp[frames...]), UInt32(frames / 2)))
        XCTAssertEqual(cf_source_write_index(mixer, 0), Int64(frames))
        let start: UInt64 = 1_000_000_000
        cf_source_set_anchor(mixer, 0, start, 1_000)
        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        cf_mixer_render(mixer, &left, &right, 256, start)
        let next = start + UInt64(256.0 / 48_000 * 1_000_000_000)
        cf_mixer_render(mixer, &left, &right, 256, next)
        for index in 0..<256 {
            XCTAssertEqual(left[index], Float(1_256 + index) / 100_000, accuracy: 0.00005)
            XCTAssertEqual(right[index], -Float(1_256 + index) / 100_000, accuracy: 0.00005)
        }
        XCTAssertGreaterThan(cf_source_take_peak(mixer, 0), 0.01)
    }

    func testTimedSourceIsSilentWithoutAnchorAndAfterFlush() throws {
        let mixer = try makeMixer()
        defer { cf_mixer_destroy(mixer) }
        cf_mixer_set_output(mixer, 48_000, 0)
        cf_source_begin(mixer, 0, CF_MODE_TIMED, 48_000)
        let data = [Float](repeating: 0.25, count: 8_192)
        XCTAssertTrue(cf_source_write(mixer, 0, 0, data, 4_096))
        var left = [Float](repeating: 1, count: 128)
        var right = [Float](repeating: 1, count: 128)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        cf_source_set_anchor(mixer, 0, 0, 100)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        XCTAssertGreaterThan(left.max() ?? 0, 0)
        cf_source_flush(mixer, 0)
        XCTAssertEqual(cf_source_write_index(mixer, 0), 0)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
    }

    func testGapIsZeroFilled() throws {
        let mixer = try makeMixer()
        defer { cf_mixer_destroy(mixer) }
        cf_mixer_set_output(mixer, 1_000, 0)
        cf_source_begin(mixer, 0, CF_MODE_TIMED, 1_000)
        let ones = [Float](repeating: 0.5, count: 200)
        XCTAssertTrue(cf_source_write(mixer, 0, 0, ones, 100))
        XCTAssertTrue(cf_source_write(mixer, 0, 300, ones, 100))
        XCTAssertEqual(cf_source_write_index(mixer, 0), 400)
        cf_source_set_anchor(mixer, 0, 0, 150)
        var left = [Float](repeating: 0, count: 64)
        var right = [Float](repeating: 0, count: 64)
        cf_mixer_render(mixer, &left, &right, 64, 0)
        cf_mixer_render(mixer, &left, &right, 64, UInt64(64.0 / 1_000 * 1_000_000_000))
        XCTAssertTrue(left.allSatisfy { abs($0) < 0.000001 })
        XCTAssertFalse(cf_source_write(mixer, 0, 1 << 16, ones, 100))
    }

    func testFifoSourceBuffersAndRecoversFromUnderrun() throws {
        let mixer = try makeMixer()
        defer { cf_mixer_destroy(mixer) }
        cf_mixer_set_output(mixer, 48_000, 0)
        cf_source_begin(mixer, 1, CF_MODE_FIFO, 48_000)
        cf_source_set_fifo_target(mixer, 1, 0.01)
        let block = [Float](repeating: 0.5, count: 2_000)
        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        cf_source_append(mixer, 1, block, 300)
        cf_mixer_render(mixer, &left, &right, 256, 0)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        cf_source_append(mixer, 1, block, 1_000)
        cf_mixer_render(mixer, &left, &right, 256, 0)
        cf_mixer_render(mixer, &left, &right, 256, 0)
        XCTAssertEqual(left[200], 0.5, accuracy: 0.001)
        for _ in 0..<8 {
            cf_mixer_render(mixer, &left, &right, 256, 0)
        }
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        cf_source_append(mixer, 1, block, 1_000)
        cf_mixer_render(mixer, &left, &right, 256, 0)
        cf_mixer_render(mixer, &left, &right, 256, 0)
        XCTAssertEqual(left[100], 0.5, accuracy: 0.001)
    }

    func testGainsMasterAndLimiter() throws {
        let mixer = try makeMixer()
        defer { cf_mixer_destroy(mixer) }
        cf_mixer_set_output(mixer, 48_000, 0)
        cf_source_begin(mixer, 0, CF_MODE_FIFO, 48_000)
        cf_source_begin(mixer, 1, CF_MODE_FIFO, 48_000)
        cf_source_set_fifo_target(mixer, 0, 0.005)
        cf_source_set_fifo_target(mixer, 1, 0.005)
        let loud = [Float](repeating: 0.9, count: 8_000)
        cf_source_append(mixer, 0, loud, 4_000)
        cf_source_append(mixer, 1, loud, 4_000)
        var left = [Float](repeating: 0, count: 128)
        var right = [Float](repeating: 0, count: 128)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        XCTAssertLessThan(left.max() ?? 2, 1.0)
        XCTAssertGreaterThan(left.max() ?? 0, 0.9)
        cf_source_set_gain(mixer, 1, 0)
        cf_mixer_set_master_gain(mixer, 0.5)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        cf_mixer_render(mixer, &left, &right, 128, 0)
        XCTAssertEqual(left[64], 0.45, accuracy: 0.001)
    }

    func testVolumeCurveAndMeterSmoothing() {
        XCTAssertEqual(AppModel.gain(for: 0), 0)
        XCTAssertEqual(AppModel.gain(for: 1), 1)
        XCTAssertEqual(AppModel.gain(for: 0.5), 0.25)
        XCTAssertEqual(AppModel.gain(for: 2), 1)
        XCTAssertEqual(AppModel.smoothed(previous: 0, peak: 1), 1)
        XCTAssertEqual(AppModel.smoothed(previous: 1, peak: 0), 0.96, accuracy: 0.0001)
    }

    func testALACDecoderRoundTrip() throws {
        let frames = 352
        let encoded = try encodeALAC(frames: frames)
        let decoder = try ALACDecoder(parameters: encoded.parameters)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { output.deallocate() }
        let produced = encoded.packet.withUnsafeBytes { decoder.decode($0, into: output) }
        XCTAssertEqual(produced, frames)
        for index in stride(from: 0, to: frames, by: 97) {
            XCTAssertEqual(output[index * 2], Float(encoded.samples[index * 2]) / 32_768, accuracy: 0.0001)
            XCTAssertEqual(output[index * 2 + 1], Float(encoded.samples[index * 2 + 1]) / 32_768, accuracy: 0.0001)
        }
        XCTAssertEqual(ALACDecoder.magicCookie(from: encoded.parameters).count, 24)
        XCTAssertEqual(Array(encoded.parameters.prefix(8)), [352, 0, 16, 40, 10, 14, 2, 255])
        XCTAssertEqual(encoded.parameters[10], 44_100)
    }

    private struct EncodedALAC {
        let packet: Data
        let parameters: [Int]
        let samples: [Int16]
    }

    private func encodeALAC(frames: Int) throws -> EncodedALAC {
        var input = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatAppleLossless, mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        XCTAssertEqual(AudioConverterNew(&input, &output, &converter), noErr)
        let encoder = try XCTUnwrap(converter)
        defer { AudioConverterDispose(encoder) }

        var samples = [Int16](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            samples[index * 2] = Int16(sin(Double(index) * 0.031) * 12_000)
            samples[index * 2 + 1] = Int16(cos(Double(index) * 0.017) * 9_000)
        }
        final class Feed {
            var samples: [Int16]
            var done = false
            init(_ samples: [Int16]) { self.samples = samples }
        }
        let feed = Feed(samples)
        var packetData = [UInt8](repeating: 0, count: frames * 8)
        var description = AudioStreamPacketDescription()
        var packets: UInt32 = 1
        let status = packetData.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(encoder, { _, count, data, _, user in
                let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                if feed.done {
                    count.pointee = 0
                    return 0x6E6F6474
                }
                feed.done = true
                count.pointee = UInt32(feed.samples.count / 2)
                feed.samples.withUnsafeMutableBytes {
                    data.pointee.mBuffers.mData = $0.baseAddress
                    data.pointee.mBuffers.mDataByteSize = UInt32($0.count)
                }
                data.pointee.mBuffers.mNumberChannels = 2
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &list, &description)
        }
        XCTAssertTrue(status == noErr || status == 0x6E6F6474)
        XCTAssertEqual(packets, 1)

        var cookieSize: UInt32 = 0
        XCTAssertEqual(AudioConverterGetPropertyInfo(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, nil), noErr)
        var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
        XCTAssertEqual(AudioConverterGetProperty(encoder, kAudioConverterCompressionMagicCookie, &cookieSize, &cookie), noErr)
        cookie = Array(cookie.prefix(Int(cookieSize)))
        let config = try XCTUnwrap(Self.alacConfig(in: cookie))
        func u32(_ offset: Int) -> Int { Int(UInt32(config[offset]) << 24 | UInt32(config[offset + 1]) << 16 | UInt32(config[offset + 2]) << 8 | UInt32(config[offset + 3])) }
        let parameters = [u32(0), Int(config[4]), Int(config[5]), Int(config[6]), Int(config[7]), Int(config[8]), Int(config[9]), Int(UInt16(config[10]) << 8 | UInt16(config[11])), u32(12), u32(16), u32(20)]
        let packet = Data(packetData.prefix(Int(description.mDataByteSize)))
        return EncodedALAC(packet: packet, parameters: parameters, samples: samples)
    }

    private static func alacConfig(in cookie: [UInt8]) -> [UInt8]? {
        let marker: [UInt8] = Array("alac".utf8)
        guard cookie.count >= 24 else { return nil }
        var found: Int?
        for index in 0...(cookie.count - 4) where Array(cookie[index..<(index + 4)]) == marker {
            found = index
        }
        guard let found else { return Array(cookie.prefix(24)) }
        guard found + 8 + 24 <= cookie.count else { return nil }
        return Array(cookie[(found + 8)..<(found + 32)])
    }
}
