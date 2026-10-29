import AppKit
import Carbon.HIToolbox
import Foundation

enum HotkeyAction: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    case toggleExternalMute
    case masterUp
    case masterDown
    case openMixer
    case checkForUpdates

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .toggleExternalMute: return "hotkey.toggleExternalMute"
        case .masterUp: return "hotkey.masterUp"
        case .masterDown: return "hotkey.masterDown"
        case .openMixer: return "hotkey.openMixer"
        case .checkForUpdates: return "hotkey.checkForUpdates"
        }
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let controlOption = UInt32(controlKey | optionKey)

    static let functionKeyCodes: Set<UInt32> = Set([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].map(UInt32.init))

    static func validated(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Hotkey? {
        var modifiers: UInt32 = 0
        var count = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey); count += 1 }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); count += 1 }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); count += 1 }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); count += 1 }
        let modifierKeys: Set<UInt32> = Set([kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function].map(UInt32.init))
        guard !modifierKeys.contains(keyCode) else { return nil }
        guard count >= 2 || functionKeyCodes.contains(keyCode) else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

enum LatencyMode: String, Codable, CaseIterable, Identifiable {
    case low
    case balanced
    case synced

    var id: String { rawValue }

    var titleKey: String {
        "latency.\(rawValue)"
    }

    var margin: Double? {
        switch self {
        case .low: return 0.15
        case .balanced: return 0.5
        case .synced: return nil
        }
    }
}

struct KnownDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var lastSeen: Date
}

struct AppSettings: Codable, Equatable {
    var receiverName: String?
    var masterVolume: Double = 0.8
    var macVolume: Double = 1.0
    var macMuted = false
    var captureMacAudio = true
    var latencyMode: LatencyMode = .low
    var launchAtLogin = true
    var notifyOnConnect = true
    var notifyOnDisconnect = true
    var notifyOnError = true
    var hotkeys: [HotkeyAction: Hotkey] = AppSettings.defaultHotkeys
    var knownDevices: [KnownDevice] = []
    var hardwareAddress: String = AppSettings.randomHardwareAddress()
    var appliedLaunchAtLoginDefault = false

    static let defaultHotkeys: [HotkeyAction: Hotkey] = [
        .toggleExternalMute: Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: Hotkey.controlOption),
        .masterUp: Hotkey(keyCode: UInt32(kVK_UpArrow), modifiers: Hotkey.controlOption),
        .masterDown: Hotkey(keyCode: UInt32(kVK_DownArrow), modifiers: Hotkey.controlOption),
        .openMixer: Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: Hotkey.controlOption)
    ]

    static func randomHardwareAddress() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    var hardwareAddressData: Data {
        var data = Data()
        var index = hardwareAddress.startIndex
        while index < hardwareAddress.endIndex, data.count < 6 {
            let next = hardwareAddress.index(index, offsetBy: 2, limitedBy: hardwareAddress.endIndex) ?? hardwareAddress.endIndex
            if let byte = UInt8(hardwareAddress[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        return data.count == 6 ? data : Data([0x02, 0x43, 0x46, 0x4C, 0x55, 0x4F])
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        receiverName = try container.decodeIfPresent(String.self, forKey: .receiverName)
        masterVolume = try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? defaults.masterVolume
        macVolume = try container.decodeIfPresent(Double.self, forKey: .macVolume) ?? defaults.macVolume
        macMuted = try container.decodeIfPresent(Bool.self, forKey: .macMuted) ?? defaults.macMuted
        captureMacAudio = try container.decodeIfPresent(Bool.self, forKey: .captureMacAudio) ?? defaults.captureMacAudio
        latencyMode = (try? container.decodeIfPresent(LatencyMode.self, forKey: .latencyMode)) ?? defaults.latencyMode
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        notifyOnConnect = try container.decodeIfPresent(Bool.self, forKey: .notifyOnConnect) ?? defaults.notifyOnConnect
        notifyOnDisconnect = try container.decodeIfPresent(Bool.self, forKey: .notifyOnDisconnect) ?? defaults.notifyOnDisconnect
        notifyOnError = try container.decodeIfPresent(Bool.self, forKey: .notifyOnError) ?? defaults.notifyOnError
        hotkeys = try container.decodeIfPresent([HotkeyAction: Hotkey].self, forKey: .hotkeys) ?? defaults.hotkeys
        knownDevices = try container.decodeIfPresent([KnownDevice].self, forKey: .knownDevices) ?? []
        hardwareAddress = try container.decodeIfPresent(String.self, forKey: .hardwareAddress) ?? defaults.hardwareAddress
        appliedLaunchAtLoginDefault = try container.decodeIfPresent(Bool.self, forKey: .appliedLaunchAtLoginDefault) ?? false
    }
}

final class SettingsStore {
    private let key = "ConfluoSettings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            let fresh = AppSettings()
            save(fresh)
            return fresh
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            let fresh = AppSettings()
            save(fresh)
            return fresh
        }
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

enum KeyNames {
    private static let special: [UInt32: String] = [
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): Bundle.main.localizedString(forKey: "key.space", value: "Space", table: nil),
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
    ]

    static func name(for keyCode: UInt32) -> String {
        if let value = special[keyCode] {
            return value
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
