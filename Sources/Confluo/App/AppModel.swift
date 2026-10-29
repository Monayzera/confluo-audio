import AppKit
import Carbon.HIToolbox
import ConfluoDSP
import CoreAudio
import Foundation
import Observation
import ServiceManagement
import SystemConfiguration

enum SourceKind {
    case mac
    case airPlay
}

@Observable
final class SourceItem: Identifiable {
    let id: String
    let kind: SourceKind
    let slot: UInt32
    let sessionID: UUID?
    let identifier: String
    var dacpID: String?
    var activeRemote: String?
    var name: String
    var bufferedSeconds: Double?
    var volume: Double
    var muted: Bool
    var solo = false
    var level: Double = 0
    var metadata = TrackMetadata()
    var artwork: NSImage?
    var lastActivity: Date?

    init(kind: SourceKind, slot: UInt32, name: String, volume: Double, muted: Bool, sender: SenderInfo? = nil) {
        self.kind = kind
        self.slot = slot
        self.name = name
        self.volume = volume
        self.muted = muted
        sessionID = sender?.sessionID
        identifier = sender?.identifier ?? "mac"
        dacpID = sender?.dacpID
        activeRemote = sender?.activeRemote
        id = sender.map { $0.sessionID.uuidString } ?? "mac"
    }

    var isPlaying: Bool {
        guard let lastActivity else { return false }
        return Date().timeIntervalSince(lastActivity) < 1.2
    }

    var supportsRemoteControl: Bool {
        dacpID != nil && activeRemote != nil
    }
}

enum CaptureState: Equatable {
    case off
    case starting
    case active
    case failed
}

enum ErrorSource {
    case general
    case output
    case capture
    case receiver
}

enum TransportCommand {
    case previous
    case playPause
    case next
}

@Observable
final class AppModel: RAOPSessionDelegate {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
        }
    }
    private(set) var sources: [SourceItem] = []
    private(set) var masterLevel: Double = 0
    private(set) var receiverState: RAOPServer.State = .stopped
    private(set) var outputDeviceName = ""
    private(set) var captureState: CaptureState = .off
    private(set) var lastError: String?
    private(set) var hotkeyFailures: Set<HotkeyAction> = []
    private(set) var recordingAction: HotkeyAction?
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?

    @ObservationIgnored var onOpenMixerRequest: (() -> Void)?
    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private let mixer: AudioMixer?
    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var server: RAOPServer?
    @ObservationIgnored private let dacp = DACPRemote()
    @ObservationIgnored private let hotkeys = HotkeyManager()
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var meterClients = 0
    @ObservationIgnored private var remoteVolumeWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var remoteVolumeSentAt: [UUID: Date] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var outputRunning = false
    @ObservationIgnored private var lastErrorSource: ErrorSource = .general
    @ObservationIgnored private var lastNotifiedError: (message: String, date: Date)?
    @ObservationIgnored private var recordingMonitor: Any?

    init() {
        settings = store.load()
        mixer = AudioMixer()
        let mac = SourceItem(kind: .mac, slot: AudioMixer.macSource, name: L10n.string("source.mac"), volume: settings.macVolume, muted: settings.macMuted)
        sources = [mac]
    }

    var macSource: SourceItem? {
        sources.first { $0.kind == .mac }
    }

    var airPlaySources: [SourceItem] {
        sources.filter { $0.kind == .airPlay }
    }

    var anySolo: Bool {
        sources.contains { $0.solo }
    }

    var captureActive: Bool {
        captureState == .active
    }

    var defaultReceiverName: String {
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        return "\(computer) · Confluo"
    }

    var receiverName: String {
        let custom = settings.receiverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RAOPServer.sanitized(custom.isEmpty ? defaultReceiverName : custom)
    }

    func start() {
        guard !started else { return }
        started = true
        Notifier.requestAuthorization()
        if !settings.appliedLaunchAtLoginDefault {
            settings.appliedLaunchAtLoginDefault = true
            if settings.launchAtLogin, let error = LoginItem.setEnabled(true) {
                loginItemError = L10n.format("error.login", error.localizedDescription)
            }
        }
        refreshLoginItem()
        hotkeys.onAction = { [weak self] action in
            self?.perform(action)
        }
        hotkeys.apply(settings.hotkeys)
        hotkeyFailures = hotkeys.failures

        guard let mixer else {
            report(L10n.string("error.mixer"))
            return
        }
        mixer.onDeviceChange = { [weak self] device in
            guard let self else { return }
            self.outputDeviceName = CoreAudioQuery.deviceName(device) ?? ""
            let wasRunning = self.outputRunning
            self.outputRunning = true
            self.clearError(from: .output)
            if !wasRunning && self.settings.captureMacAudio {
                self.startCapture()
            } else {
                self.capture?.verifyExclusion()
            }
        }
        mixer.onError = { [weak self] error in
            guard let self else { return }
            self.outputRunning = false
            self.stopCaptureForSafety()
            self.report(L10n.format("error.output", error.localizedDescription), source: .output)
        }
        do {
            try mixer.start()
            outputRunning = true
            outputDeviceName = CoreAudioQuery.deviceName(mixer.device) ?? ""
        } catch {
            outputRunning = false
            report(L10n.format("error.output", error.localizedDescription), source: .output)
        }
        applyGains()

        let slots = SlotAllocator(slots: (1...UInt32(AudioMixer.airPlaySourceCount)).map { $0 })
        let server = RAOPServer(mixer: mixer.core, slots: slots, hardwareAddress: settings.hardwareAddressData)
        server.sessionDelegate = self
        server.setLatencyMode(settings.latencyMode)
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.receiverState = state
            switch state {
            case .failed(let message):
                self.report(L10n.format("error.receiver", message), source: .receiver, notify: false)
            case .ready:
                self.clearError(from: .receiver)
            default:
                break
            }
        }
        self.server = server
        server.start(name: receiverName)
        let capture = SystemAudioCapture(mixer: mixer.core, source: AudioMixer.macSource)
        capture.onError = { [weak self] error in
            self?.captureState = .failed
            self?.report(L10n.format("error.capture", error.localizedDescription), source: .capture)
        }
        self.capture = capture
        if settings.captureMacAudio && outputRunning {
            startCapture()
        }

        dacp.start()
    }

    func shutdown() {
        endHotkeyRecording()
        server?.stop()
        capture?.stopSynchronously()
        mixer?.stop()
        dacp.stop()
    }

    func meterClientAppeared() {
        meterClients += 1
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateMeters()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func meterClientDisappeared() {
        meterClients = max(0, meterClients - 1)
        guard meterClients == 0 else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        for source in sources where source.level != 0 {
            source.level = 0
        }
        if masterLevel != 0 {
            masterLevel = 0
        }
    }

    private func updateMeters() {
        guard let mixer else { return }
        let now = Date()
        for source in sources {
            let peak = Double(mixer.takePeak(source: source.slot))
            if peak > 0.0003, source.lastActivity.map({ now.timeIntervalSince($0) > 0.25 }) ?? true {
                source.lastActivity = now
            }
            let level = Self.smoothed(previous: source.level, peak: peak)
            if level != source.level {
                source.level = level
            }
            if source.kind == .airPlay {
                let buffered = cf_source_buffered_seconds(mixer.core, source.slot)
                let delay: Double? = buffered >= 0 ? ((buffered + cf_mixer_output_latency(mixer.core)) * 20).rounded() / 20 : nil
                if delay != source.bufferedSeconds {
                    source.bufferedSeconds = delay
                }
            }
        }
        let master = Self.smoothed(previous: masterLevel, peak: Double(mixer.takeMasterPeak()))
        if master != masterLevel {
            masterLevel = master
        }
    }

    static func smoothed(previous: Double, peak: Double) -> Double {
        let decibels = peak > 0 ? 20 * log10(peak) : -120
        let normalized = min(max((decibels + 60) / 60, 0), 1)
        return normalized >= previous ? normalized : max(normalized, previous - 0.04)
    }

    static func gain(for volume: Double) -> Float {
        let clamped = min(max(volume, 0), 1)
        return Float(clamped * clamped)
    }

    func applyGains() {
        guard let mixer else { return }
        let anySolo = self.anySolo
        for source in sources {
            let audible = !source.muted && (!anySolo || source.solo)
            mixer.setGain(audible ? Self.gain(for: source.volume) : 0, source: source.slot)
        }
        mixer.setMasterGain(Self.gain(for: settings.masterVolume))
    }

    func setMasterVolume(_ value: Double) {
        settings.masterVolume = min(max(value, 0), 1)
        applyGains()
    }

    func setVolume(_ value: Double, for source: SourceItem) {
        source.volume = min(max(value, 0), 1)
        if source.kind == .mac {
            settings.macVolume = source.volume
        } else {
            scheduleRemoteVolume(for: source)
        }
        applyGains()
    }

    func toggleMute(_ source: SourceItem) {
        setMuted(!source.muted, for: source)
    }

    private func setMuted(_ muted: Bool, for source: SourceItem) {
        source.muted = muted
        if source.kind == .mac {
            settings.macMuted = muted
        }
        applyGains()
    }

    func setLatencyMode(_ mode: LatencyMode) {
        settings.latencyMode = mode
        server?.setLatencyMode(mode)
    }

    func toggleSolo(_ source: SourceItem) {
        source.solo.toggle()
        applyGains()
    }

    func disconnect(_ source: SourceItem) {
        guard let sessionID = source.sessionID else { return }
        server?.disconnect(sessionID: sessionID)
    }

    func send(_ command: TransportCommand, to source: SourceItem) {
        guard let dacpID = source.dacpID, let activeRemote = source.activeRemote else { return }
        let mapped: DACPCommand
        switch command {
        case .previous: mapped = .previous
        case .playPause: mapped = .playPause
        case .next: mapped = .next
        }
        dacp.send(mapped, dacpID: dacpID, activeRemote: activeRemote)
    }

    func toggleExternalMute() {
        let external = airPlaySources
        guard !external.isEmpty else { return }
        let shouldMute = external.contains { !$0.muted }
        external.forEach { setMuted(shouldMute, for: $0) }
    }

    func setCaptureMacAudio(_ enabled: Bool) {
        settings.captureMacAudio = enabled
        if enabled {
            startCapture()
        } else {
            capture?.stop()
            captureState = .off
            clearError(from: .capture)
        }
    }

    private func startCapture() {
        guard let capture, outputRunning else { return }
        captureState = .starting
        capture.start { [weak self] error in
            guard let self else { return }
            guard self.settings.captureMacAudio, self.outputRunning else {
                capture.stop()
                self.captureState = .off
                return
            }
            if let error {
                self.captureState = .failed
                self.report(L10n.format("error.capture", error.localizedDescription), source: .capture)
            } else {
                self.captureState = .active
                self.clearError(from: .capture)
            }
        }
    }

    private func stopCaptureForSafety() {
        capture?.stop()
        if captureState != .off {
            captureState = settings.captureMacAudio ? .failed : .off
        }
    }

    func openCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        if let error = LoginItem.setEnabled(enabled) {
            loginItemError = L10n.format("error.login", error.localizedDescription)
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        if status != loginItemStatus {
            loginItemStatus = status
        }
        let enabled = status == .enabled || status == .requiresApproval
        if settings.launchAtLogin != enabled {
            settings.launchAtLogin = enabled
        }
    }

    func setReceiverName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.receiverName = trimmed.isEmpty ? nil : trimmed
        server?.rename(receiverName)
    }

    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        var updated = settings.hotkeys
        if let hotkey {
            for (other, existing) in updated where other != action && existing == hotkey {
                updated[other] = nil
            }
        }
        updated[action] = hotkey
        settings.hotkeys = updated
        if recordingAction == nil {
            hotkeys.apply(settings.hotkeys)
            hotkeyFailures = hotkeys.failures
        }
    }

    func resetHotkeys() {
        endHotkeyRecording()
        settings.hotkeys = AppSettings.defaultHotkeys
        hotkeys.apply(settings.hotkeys)
        hotkeyFailures = hotkeys.failures
    }

    func beginHotkeyRecording(_ action: HotkeyAction) {
        endHotkeyRecording()
        recordingAction = action
        hotkeys.suspend()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            self.handleRecordedKey(event, for: action)
            return nil
        }
    }

    func endHotkeyRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        guard recordingAction != nil else { return }
        recordingAction = nil
        hotkeys.apply(settings.hotkeys)
        hotkeyFailures = hotkeys.failures
    }

    private func handleRecordedKey(_ event: NSEvent, for action: HotkeyAction) {
        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if keyCode == UInt32(kVK_Escape) && flags.isEmpty {
            endHotkeyRecording()
            return
        }
        if (keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete)) && flags.isEmpty {
            setHotkey(nil, for: action)
            endHotkeyRecording()
            return
        }
        guard let hotkey = Hotkey.validated(keyCode: keyCode, flags: flags) else {
            NSSound.beep()
            return
        }
        setHotkey(hotkey, for: action)
        endHotkeyRecording()
    }

    func forget(_ device: KnownDevice) {
        settings.knownDevices.removeAll { $0.id == device.id }
    }

    func clearError() {
        lastError = nil
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleExternalMute:
            toggleExternalMute()
        case .masterUp:
            setMasterVolume(settings.masterVolume + 0.05)
        case .masterDown:
            setMasterVolume(settings.masterVolume - 0.05)
        case .openMixer:
            onOpenMixerRequest?()
        }
    }

    private func report(_ message: String, source: ErrorSource = .general, notify: Bool = true) {
        lastError = message
        lastErrorSource = source
        guard notify && settings.notifyOnError else { return }
        let now = Date()
        if let last = lastNotifiedError, last.message == message, now.timeIntervalSince(last.date) < 60 {
            return
        }
        lastNotifiedError = (message, now)
        Notifier.post(title: "Confluo", body: message)
    }

    private func clearError(from source: ErrorSource) {
        guard lastError != nil, lastErrorSource == source else { return }
        lastError = nil
    }

    private func scheduleRemoteVolume(for source: SourceItem) {
        guard let sessionID = source.sessionID, let dacpID = source.dacpID, let activeRemote = source.activeRemote else { return }
        remoteVolumeWork[sessionID]?.cancel()
        let volume = source.volume
        let work = DispatchWorkItem { [weak self] in
            let decibels = volume <= 0 ? -144 : volume * 30 - 30
            self?.dacp.send(.volume(decibels: decibels), dacpID: dacpID, activeRemote: activeRemote)
            self?.remoteVolumeWork[sessionID] = nil
            self?.remoteVolumeSentAt[sessionID] = Date()
        }
        remoteVolumeWork[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func source(for session: RAOPSession) -> SourceItem? {
        sources.first { $0.sessionID == session.id }
    }

    func sessionDidBegin(_ session: RAOPSession, sender: SenderInfo) {
        guard source(for: session) == nil else { return }
        let item = SourceItem(kind: .airPlay, slot: sender.slot, name: sender.name, volume: 1.0, muted: false, sender: sender)
        sources.append(item)
        if let index = settings.knownDevices.firstIndex(where: { $0.id == sender.identifier }) {
            settings.knownDevices[index].name = sender.name
            settings.knownDevices[index].lastSeen = Date()
        } else {
            settings.knownDevices.append(KnownDevice(id: sender.identifier, name: sender.name, lastSeen: Date()))
        }
        applyGains()
        if settings.notifyOnConnect {
            Notifier.post(title: L10n.format("notification.connected", sender.name), body: L10n.string("notification.connected.body"))
        }
    }

    func session(_ session: RAOPSession, didChangeVolume decibels: Double) {
        guard let item = source(for: session) else { return }
        let volume = decibels <= -144 ? 0 : min(max((decibels + 30) / 30, 0), 1)
        guard abs(volume - item.volume) > 0.004, remoteVolumeWork[session.id] == nil else { return }
        if let sent = remoteVolumeSentAt[session.id], Date().timeIntervalSince(sent) < 1.5 {
            return
        }
        item.volume = volume
        applyGains()
    }

    func session(_ session: RAOPSession, didChangeMetadata metadata: TrackMetadata) {
        source(for: session)?.metadata = metadata
    }

    func session(_ session: RAOPSession, didUpdateRemote dacpID: String?, activeRemote: String?) {
        guard let item = source(for: session) else { return }
        item.dacpID = dacpID
        item.activeRemote = activeRemote
    }

    func session(_ session: RAOPSession, didChangeArtwork artwork: Data?) {
        guard let artwork else {
            source(for: session)?.artwork = nil
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let image = NSImage(data: artwork)
            DispatchQueue.main.async {
                self?.source(for: session)?.artwork = image
            }
        }
    }

    func sessionDidEnd(_ session: RAOPSession) {
        guard let item = source(for: session) else { return }
        sources.removeAll { $0.id == item.id }
        remoteVolumeWork[session.id]?.cancel()
        remoteVolumeWork[session.id] = nil
        remoteVolumeSentAt[session.id] = nil
        if let index = settings.knownDevices.firstIndex(where: { $0.id == item.identifier }) {
            settings.knownDevices[index].lastSeen = Date()
        }
        applyGains()
        if settings.notifyOnDisconnect {
            Notifier.post(title: L10n.format("notification.disconnected", item.name), body: L10n.string("notification.disconnected.body"))
        }
    }
}
