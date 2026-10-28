import AudioToolbox
import ConfluoDSP
import CoreAudio
import Foundation

final class SystemAudioCapture {
    private let mixer: OpaquePointer
    private let source: UInt32
    private let queue = DispatchQueue(label: "confluo.audio.capture")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let scratchFrames = 16_384
    private let scratch: UnsafeMutablePointer<Float>

    var onError: ((Error) -> Void)?
    private(set) var isRunning = false
    private var sourceBegun = false

    init(mixer: OpaquePointer, source: UInt32) {
        self.mixer = mixer
        self.source = source
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit {
        stopLocked()
        scratch.deallocate()
    }

    func start(completion: @escaping (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            if !self.isRunning {
                do {
                    try self.startLocked()
                } catch {
                    self.stopLocked()
                    failure = error
                }
            }
            DispatchQueue.main.async {
                completion(failure)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.stopLocked()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func stopSynchronously() {
        queue.sync {
            stopLocked()
        }
    }

    private func startLocked() throws {
        let ownProcess = CoreAudioQuery.processObject(for: getpid())
        guard ownProcess != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(operation: "TranslatePIDToProcessObject", status: -1)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "Confluo"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Confluo Capture",
            kAudioAggregateDeviceUIDKey: "com.monayzera.confluo.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "AudioHardwareCreateAggregateDevice")
        aggregateID = device

        var rate = CoreAudioQuery.nominalSampleRate(device)
        if rate <= 0 {
            let format: AudioStreamBasicDescription = CoreAudioQuery.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            rate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        }

        let mixer = self.mixer
        let source = self.source
        let scratch = self.scratch
        let scratchFrames = self.scratchFrames
        var created: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&created, device, nil) { _, input, _, _, _ in
            SystemAudioCapture.consume(input, mixer: mixer, source: source, scratch: scratch, scratchFrames: scratchFrames)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = created

        cf_source_begin(mixer, source, CF_MODE_FIFO, rate)
        cf_source_set_fifo_target(mixer, source, 0.03)
        sourceBegun = true
        try check(AudioDeviceStart(device, created), "AudioDeviceStart")
        isRunning = true
        installFormatListener()
    }

    private func stopLocked() {
        removeFormatListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        if sourceBegun {
            cf_source_end(mixer, source)
        }
        sourceBegun = false
        isRunning = false
    }

    private func installFormatListener() {
        guard formatListener == nil, tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartAfterFormatChange()
        }
        var address = CoreAudioQuery.address(kAudioTapPropertyFormat)
        if AudioObjectAddPropertyListenerBlock(tapID, &address, queue, block) == noErr {
            formatListener = block
        }
    }

    private func removeFormatListener() {
        guard let formatListener, tapID != AudioObjectID(kAudioObjectUnknown) else {
            self.formatListener = nil
            return
        }
        var address = CoreAudioQuery.address(kAudioTapPropertyFormat)
        AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, formatListener)
        self.formatListener = nil
    }

    private func restartAfterFormatChange() {
        guard isRunning else { return }
        stopLocked()
        do {
            try startLocked()
        } catch {
            stopLocked()
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
        }
    }

    private static func consume(_ input: UnsafePointer<AudioBufferList>, mixer: OpaquePointer, source: UInt32, scratch: UnsafeMutablePointer<Float>, scratchFrames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }
        let firstChannels = Int(first.mNumberChannels)
        guard firstChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (firstChannels * MemoryLayout<Float>.size)
        guard frames > 0 else { return }
        if buffers.count == 1 && firstChannels == 2 {
            cf_source_append(mixer, source, firstData.assumingMemoryBound(to: Float.self), UInt32(frames))
            return
        }
        var offset = 0
        while offset < frames {
            let chunk = min(frames - offset, scratchFrames)
            if buffers.count == 1 {
                let samples = firstData.assumingMemoryBound(to: Float.self)
                for frame in 0..<chunk {
                    let base = (offset + frame) * firstChannels
                    let left = samples[base]
                    let right = firstChannels > 1 ? samples[base + 1] : left
                    scratch[frame * 2] = left
                    scratch[frame * 2 + 1] = right
                }
            } else {
                let leftSamples = firstData.assumingMemoryBound(to: Float.self)
                let rightSamples = buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? leftSamples
                for frame in 0..<chunk {
                    scratch[frame * 2] = leftSamples[offset + frame]
                    scratch[frame * 2 + 1] = rightSamples[offset + frame]
                }
            }
            cf_source_append(mixer, source, scratch, UInt32(chunk))
            offset += chunk
        }
    }
}
