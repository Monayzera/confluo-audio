import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case mixer
    case devices
    case shortcuts
    case settings

    var id: String { rawValue }

    var titleKey: String {
        "section.\(rawValue)"
    }

    var symbol: String {
        switch self {
        case .mixer: return "slider.vertical.3"
        case .devices: return "iphone.gen3"
        case .shortcuts: return "keyboard"
        case .settings: return "gearshape"
        }
    }
}

final class WindowNavigation: ObservableObject {
    @Published var section: MainSection? = .mixer
}

struct MainWindowView: View {
    let model: AppModel
    @ObservedObject var navigation: WindowNavigation

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $navigation.section) { section in
                Label(L10n.string(section.titleKey), systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch navigation.section ?? .mixer {
                case .mixer: MixerPage(model: model)
                case .devices: DevicesPage(model: model)
                case .shortcuts: ShortcutsPage(model: model)
                case .settings: SettingsPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(L10n.string((navigation.section ?? .mixer).titleKey))
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

struct MixerPage: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ReceiverStatusLabel(model: model)
                    Spacer()
                    Text(model.receiverName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.clearError() }
                }
                MixerContent(model: model)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }
}

struct DevicesPage: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                if model.settings.knownDevices.isEmpty {
                    Text(L10n.string("devices.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.knownDevices.sorted { $0.lastSeen > $1.lastSeen }) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(L10n.format("devices.lastSeen", device.lastSeen.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.airPlaySources.contains(where: { $0.identifier == device.id }) {
                                Text(L10n.string("devices.connected"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color(red: 0.42, green: 0.78, blue: 0.68))
                            }
                            Button(L10n.string("devices.forget")) {
                                model.forget(device)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text(L10n.string("devices.header"))
            } footer: {
                Text(L10n.format("devices.footer", model.receiverName))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsPage: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string(action.titleKey))
                            if model.hotkeyFailures.contains(action) {
                                Text(L10n.string("hotkey.unavailable"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.93, green: 0.62, blue: 0.55))
                            }
                        }
                        Spacer()
                        HotkeyRecorder(model: model, action: action)
                    }
                }
            } header: {
                Text(L10n.string("section.shortcuts"))
            } footer: {
                Text(L10n.string("hotkey.footer"))
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L10n.string("hotkey.reset")) {
                    model.resetHotkeys()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsPage: View {
    let model: AppModel
    @State private var name = ""
    @State private var pendingName: DispatchWorkItem?

    var body: some View {
        Form {
            Section {
                TextField(L10n.string("settings.receiverName"), text: $name, prompt: Text(model.defaultReceiverName))
                    .onSubmit { commitName() }
                    .onChange(of: name) { _, _ in scheduleName() }
                ReceiverStatusLabel(model: model)
            } header: {
                Text(L10n.string("settings.receiver"))
            } footer: {
                Text(L10n.string("settings.receiverFooter"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.string("settings.captureMac"), isOn: Binding(get: { model.settings.captureMacAudio }, set: { model.setCaptureMacAudio($0) }))
                Picker(L10n.string("settings.latency"), selection: Binding(get: { model.settings.latencyMode }, set: { model.setLatencyMode($0) })) {
                    ForEach(LatencyMode.allCases) { mode in
                        Text(L10n.string(mode.titleKey)).tag(mode)
                    }
                }
            } header: {
                Text(L10n.string("settings.audio"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("settings.captureMacFooter"))
                    Text(L10n.string("settings.latencyFooter"))
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.string("settings.launchAtLogin"), isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let error = model.loginItemError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.93, green: 0.62, blue: 0.55))
                }
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text(L10n.string("settings.loginApproval"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.string("settings.openLoginItems")) {
                            LoginItem.openSystemSettings()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text(L10n.string("settings.general"))
            }

            Section {
                Toggle(L10n.string("settings.notifyConnect"), isOn: Binding(get: { model.settings.notifyOnConnect }, set: { model.settings.notifyOnConnect = $0 }))
                Toggle(L10n.string("settings.notifyDisconnect"), isOn: Binding(get: { model.settings.notifyOnDisconnect }, set: { model.settings.notifyOnDisconnect = $0 }))
                Toggle(L10n.string("settings.notifyError"), isOn: Binding(get: { model.settings.notifyOnError }, set: { model.settings.notifyOnError = $0 }))
            } header: {
                Text(L10n.string("settings.notifications"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = model.settings.receiverName ?? ""
            model.refreshLoginItem()
        }
        .onDisappear { commitName() }
    }

    private func scheduleName() {
        pendingName?.cancel()
        let work = DispatchWorkItem { commitName() }
        pendingName = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func commitName() {
        pendingName?.cancel()
        pendingName = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (model.settings.receiverName ?? "") else { return }
        model.setReceiverName(name)
    }
}
