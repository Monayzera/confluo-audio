import AudioToolbox
import CoreAudio
import Foundation

enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    static func now() -> UInt64 {
        mach_absolute_time()
    }
}

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) (OSStatus \(status))"
    }
}

@discardableResult
func check(_ status: OSStatus, _ operation: String) throws -> OSStatus {
    guard status == noErr else {
        throw CoreAudioError(operation: operation, status: status)
    }
    return status
}

enum CoreAudioQuery {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = address(selector, scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    static func outputLatency(_ device: AudioDeviceID) -> Double {
        let rate = nominalSampleRate(device)
        guard rate > 0 else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        let deviceLatency: UInt32 = value(device, kAudioDevicePropertyLatency, scope: scope, default: 0)
        let safetyOffset: UInt32 = value(device, kAudioDevicePropertySafetyOffset, scope: scope, default: 0)
        let bufferFrames: UInt32 = value(device, kAudioDevicePropertyBufferFrameSize, scope: scope, default: 0)
        var streamLatency: UInt32 = 0
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                streamLatency = value(first, kAudioStreamPropertyLatency, default: UInt32(0))
            }
        }
        let total = Double(deviceLatency) + Double(safetyOffset) + Double(bufferFrames) + Double(streamLatency)
        return min(total / rate, 1.0)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var input = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &input, &size, &object)
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }
}
