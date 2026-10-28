import Carbon.HIToolbox
import Foundation

final class HotkeyManager {
    private static let signature: OSType = 0x43464C4F

    var onAction: ((HotkeyAction) -> Void)?
    private var references: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private(set) var failures: Set<HotkeyAction> = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let actions = HotkeyAction.allCases
            guard Int(identifier.id) < actions.count else { return OSStatus(eventNotHandledErr) }
            let action = actions[Int(identifier.id)]
            DispatchQueue.main.async {
                manager.onAction?(action)
            }
            return noErr
        }, 1, &spec, context, &handler)
    }

    deinit {
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    func apply(_ hotkeys: [HotkeyAction: Hotkey]) {
        unregisterAll()
        failures = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let hotkey = hotkeys[action] else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references[action] = reference
            } else {
                failures.insert(action)
            }
        }
    }

    func suspend() {
        unregisterAll()
    }

    private func unregisterAll() {
        references.values.forEach { UnregisterEventHotKey($0) }
        references = [:]
    }
}
