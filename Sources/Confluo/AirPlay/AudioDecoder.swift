import AudioToolbox
import Foundation

protocol AudioPacketDecoder: AnyObject {
    var maximumFramesPerPacket: Int { get }
    func decode(_ packet: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<Float>) -> Int
}

enum AudioDecoderFactory {
    static func make(for codec: AudioCodec) throws -> AudioPacketDecoder {
        switch codec {
        case .alac(let parameters):
            return try ALACDecoder(parameters: parameters)
        case .pcm16BigEndian(_, let channels):
            return PCM16Decoder(channels: channels)
        case .unsupported(let name):
            throw CoreAudioError(operation: "Unsupported codec \(name)", status: -1)
        }
    }
}

final class PCM16Decoder: AudioPacketDecoder {
    let channels: Int
    let maximumFramesPerPacket = 4096

    init(channels: Int) {
        self.channels = max(1, channels)
    }

    func decode(_ packet: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<Float>) -> Int {
        let frames = min(packet.count / (2 * channels), maximumFramesPerPacket)
        for frame in 0..<frames {
            let left = sample(packet, frame * channels)
            let right = channels > 1 ? sample(packet, frame * channels + 1) : left
            output[frame * 2] = left
            output[frame * 2 + 1] = right
        }
        return frames
    }

    private func sample(_ packet: UnsafeRawBufferPointer, _ index: Int) -> Float {
        let value = Int16(bitPattern: UInt16(packet[index * 2]) << 8 | UInt16(packet[index * 2 + 1]))
        return Float(value) / 32_768
    }
}

final class ALACDecoder: AudioPacketDecoder {
    private struct InputContext {
        var data: UnsafeRawPointer?
        var size: UInt32 = 0
        var consumed = true
        var description = AudioStreamPacketDescription()
    }

    private static let noMoreData: OSStatus = 0x6E6F6474

    private var converter: AudioConverterRef?
    private let channels: Int
    let maximumFramesPerPacket: Int
    private let decodeBuffer: UnsafeMutablePointer<Float>
    private let context: UnsafeMutablePointer<InputContext>

    static func magicCookie(from parameters: [Int]) -> Data {
        var cookie = Data()
        func append32(_ value: Int) {
            var big = UInt32(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: &big) { cookie.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            var big = UInt16(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: &big) { cookie.append(contentsOf: $0) }
        }
        func append8(_ value: Int) {
            cookie.append(UInt8(truncatingIfNeeded: value))
        }
        append32(parameters[0])
        append8(parameters[1])
        append8(parameters[2])
        append8(parameters[3])
        append8(parameters[4])
        append8(parameters[5])
        append8(parameters[6])
        append16(parameters[7])
        append32(parameters[8])
        append32(parameters[9])
        append32(parameters[10])
        return cookie
    }

    init(parameters: [Int]) throws {
        guard parameters.count >= 11, parameters[0] > 0, parameters[0] <= 16_384 else {
            throw CoreAudioError(operation: "ALAC parameters", status: -1)
        }
        let frameLength = parameters[0]
        let bitDepth = parameters[2]
        channels = max(1, min(parameters[6], 8))
        let sampleRate = Double(parameters[10] > 0 ? parameters[10] : 44_100)
        maximumFramesPerPacket = frameLength

        let flags: AudioFormatFlags
        switch bitDepth {
        case 20: flags = kAppleLosslessFormatFlag_20BitSourceData
        case 24: flags = kAppleLosslessFormatFlag_24BitSourceData
        case 32: flags = kAppleLosslessFormatFlag_32BitSourceData
        default: flags = kAppleLosslessFormatFlag_16BitSourceData
        }
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: flags,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameLength),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: AudioConverterRef?
        try check(AudioConverterNew(&input, &output, &created), "AudioConverterNew ALAC")
        guard let created else { throw CoreAudioError(operation: "AudioConverterNew ALAC", status: -1) }
        let cookie = Self.magicCookie(from: parameters)
        let status = cookie.withUnsafeBytes {
            AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        guard status == noErr else {
            AudioConverterDispose(created)
            throw CoreAudioError(operation: "ALAC magic cookie", status: status)
        }
        converter = created
        decodeBuffer = .allocate(capacity: frameLength * channels)
        context = .allocate(capacity: 1)
        context.initialize(to: InputContext())
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        decodeBuffer.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    func decode(_ packet: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<Float>) -> Int {
        guard let converter, let base = packet.baseAddress, packet.count > 0 else { return 0 }
        context.pointee.data = base
        context.pointee.size = UInt32(packet.count)
        context.pointee.consumed = false
        context.pointee.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        var frames = UInt32(maximumFramesPerPacket)
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(maximumFramesPerPacket * channels * 4), mData: decodeBuffer)
        )
        let status = AudioConverterFillComplexBuffer(converter, { _, packetCount, data, descriptions, userData in
                guard let userData else {
                    packetCount.pointee = 0
                    return ALACDecoder.noMoreData
                }
                let context = userData.assumingMemoryBound(to: InputContext.self)
                if context.pointee.consumed {
                    packetCount.pointee = 0
                    return ALACDecoder.noMoreData
                }
                context.pointee.consumed = true
                packetCount.pointee = 1
                data.pointee.mNumberBuffers = 1
                data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: context.pointee.data)
                data.pointee.mBuffers.mDataByteSize = context.pointee.size
                data.pointee.mBuffers.mNumberChannels = 0
                if let descriptions {
                    let offset = MemoryLayout<InputContext>.offset(of: \InputContext.description)!
                    descriptions.pointee = (UnsafeMutableRawPointer(context) + offset).assumingMemoryBound(to: AudioStreamPacketDescription.self)
                }
                return noErr
            }, context, &frames, &list, nil)
        guard status == noErr || status == Self.noMoreData else {
            AudioConverterReset(converter)
            return 0
        }
        let produced = Int(frames)
        if channels == 2 {
            output.update(from: decodeBuffer, count: produced * 2)
        } else {
            for frame in 0..<produced {
                let left = decodeBuffer[frame * channels]
                let right = channels > 1 ? decodeBuffer[frame * channels + 1] : left
                output[frame * 2] = left
                output[frame * 2 + 1] = right
            }
        }
        return produced
    }
}
