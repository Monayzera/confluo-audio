import AudioToolbox
import ConfluoDSP
import CoreAudio
import Foundation

private let renderCallback: AURenderCallback = { refCon, _, timeStamp, _, frameCount, ioData in
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard buffers.count >= 2,
          let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }
    let stamp = timeStamp.pointee
    let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
    cf_mixer_render(OpaquePointer(refCon), left, right, frameCount, hostTime)
    return noErr
}

final class AudioMixer {
    static let macSource: UInt32 = 0
    static let airPlaySourceCount = 6
    static let capacityFrames: UInt32 = 1 << 18

    let core: OpaquePointer
    var onDeviceChange: ((AudioDeviceID) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "confluo.audio.output")
    private var unit: AudioUnit?
    private var listener: AudioObjectPropertyListenerBlock?
    private(set) var device = AudioDeviceID(kAudioObjectUnknown)

    init?() {
        guard let core = cf_mixer_create(UInt32(1 + Self.airPlaySourceCount), Self.capacityFrames, HostClock.ticksPerSecond) else {
            return nil
        }
        self.core = core
    }

    deinit {
        stop()
        cf_mixer_destroy(core)
    }

    func start() throws {
        try queue.sync {
            try startUnit()
        }
        installListener()
    }

    func stop() {
        removeListener()
        queue.sync {
            stopUnit()
        }
    }

    func setMasterGain(_ gain: Float) {
        cf_mixer_set_master_gain(core, gain)
    }

    func takeMasterPeak() -> Float {
        cf_mixer_take_master_peak(core)
    }

    func setGain(_ gain: Float, source: UInt32) {
        cf_source_set_gain(core, source, gain)
    }

    func takePeak(source: UInt32) -> Float {
        cf_source_take_peak(core, source)
    }

    private func startUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError(operation: "AudioComponentFindNext", status: -1)
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "AudioComponentInstanceNew")
        guard let created else {
            throw CoreAudioError(operation: "AudioComponentInstanceNew", status: -1)
        }
        do {
            let current = CoreAudioQuery.defaultOutputDevice()
            var rate = CoreAudioQuery.nominalSampleRate(current)
            if rate <= 0 {
                rate = 48_000
            }
            var format = AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "StreamFormat")
            var callback = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: UnsafeMutableRawPointer(core))
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")
            try check(AudioUnitInitialize(created), "AudioUnitInitialize")
            cf_mixer_set_output(core, rate, CoreAudioQuery.outputLatency(current))
            try check(AudioOutputUnitStart(created), "AudioOutputUnitStart")
            unit = created
            device = current
        } catch {
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            throw error
        }
    }

    private func stopUnit() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    private func installListener() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChange()
        }
        var address = CoreAudioQuery.address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            listener = block
        }
    }

    private func removeListener() {
        guard let listener else { return }
        var address = CoreAudioQuery.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        self.listener = nil
    }

    private func handleDefaultDeviceChange() {
        let next = CoreAudioQuery.defaultOutputDevice()
        guard next != device, next != AudioDeviceID(kAudioObjectUnknown) else { return }
        stopUnit()
        do {
            try startUnit()
        } catch {
            device = AudioDeviceID(kAudioObjectUnknown)
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
            return
        }
        let current = device
        DispatchQueue.main.async { [weak self] in
            self?.onDeviceChange?(current)
        }
    }
}
