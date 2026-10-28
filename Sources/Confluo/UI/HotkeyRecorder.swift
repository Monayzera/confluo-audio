import SwiftUI

struct HotkeyRecorder: View {
    let model: AppModel
    let action: HotkeyAction

    private var hotkey: Hotkey? {
        model.settings.hotkeys[action]
    }

    private var recording: Bool {
        model.recordingAction == action
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if recording {
                    model.endHotkeyRecording()
                } else {
                    model.beginHotkeyRecording(action)
                }
            } label: {
                Text(recording ? L10n.string("hotkey.recording") : (hotkey?.display ?? L10n.string("hotkey.none")))
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minWidth: 110)
            }
            .glassControl(active: recording)
            .accessibilityLabel(L10n.string(action.titleKey))
            .accessibilityValue(hotkey?.display ?? L10n.string("hotkey.none"))

            if hotkey != nil && !recording {
                Button {
                    model.setHotkey(nil, for: action)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 12, height: 12)
                }
                .glassControl()
                .help(L10n.string("hotkey.clear"))
                .accessibilityLabel(L10n.string("hotkey.clear"))
            }
        }
        .controlSize(.small)
        .onDisappear {
            if recording {
                model.endHotkeyRecording()
            }
        }
    }
}
