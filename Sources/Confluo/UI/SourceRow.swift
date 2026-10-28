import SwiftUI

struct SourceRow: View {
    let model: AppModel
    @Bindable var source: SourceItem

    private var statusText: String {
        if source.kind == .mac && !model.captureActive {
            return L10n.string("source.status.captureOff")
        }
        if source.muted {
            return L10n.string("source.status.muted")
        }
        return source.isPlaying ? L10n.string("source.status.playing") : L10n.string("source.status.idle")
    }

    private var statusColor: Color {
        if source.kind == .mac && !model.captureActive {
            return .secondary.opacity(0.5)
        }
        if source.muted {
            return Color(red: 0.93, green: 0.62, blue: 0.55)
        }
        return source.isPlaying ? Color(red: 0.42, green: 0.78, blue: 0.68) : .secondary.opacity(0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: source.kind == .mac ? "desktopcomputer" : "iphone")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                controls
            }
            if source.kind == .airPlay && (!source.metadata.isEmpty || source.artwork != nil) {
                nowPlaying
            }
            VStack(spacing: 6) {
                VolumeSlider(value: source.volume) { model.setVolume($0, for: source) }
                LevelMeter(level: source.level, muted: source.muted)
                    .padding(.leading, 18)
                    .padding(.trailing, 44)
            }
            .disabled(source.kind == .mac && !model.captureActive)
            .opacity(source.kind == .mac && !model.captureActive ? 0.45 : 1)
        }
        .surfaceCard()
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleMute(source)
            } label: {
                Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 16, height: 14)
            }
            .glassControl(active: source.muted, tint: Color(red: 0.93, green: 0.62, blue: 0.55))
            .help(L10n.string(source.muted ? "action.unmute" : "action.mute"))
            .accessibilityLabel(L10n.string(source.muted ? "action.unmute" : "action.mute"))

            Button {
                model.toggleSolo(source)
            } label: {
                Text("S")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 16, height: 14)
            }
            .glassControl(active: source.solo, tint: Color(red: 0.47, green: 0.66, blue: 0.93))
            .help(L10n.string("action.solo"))
            .accessibilityLabel(L10n.string("action.solo"))

            if source.kind == .airPlay {
                Button {
                    model.disconnect(source)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 14)
                }
                .glassControl()
                .help(L10n.string("action.disconnect"))
                .accessibilityLabel(L10n.string("action.disconnect"))
            }
        }
        .controlSize(.small)
        .glassGroup(spacing: 6)
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = source.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06))
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(source.metadata.title ?? L10n.string("source.unknownTrack"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let subtitle = [source.metadata.artist, source.metadata.album].compactMap({ $0 }).first {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if source.supportsRemoteControl {
                HStack(spacing: 4) {
                    transportButton("backward.fill", .previous, "action.previous")
                    transportButton("playpause.fill", .playPause, "action.playPause")
                    transportButton("forward.fill", .next, "action.next")
                }
                .controlSize(.small)
                .glassGroup(spacing: 4)
            }
        }
    }

    private func transportButton(_ symbol: String, _ command: TransportCommand, _ key: String) -> some View {
        Button {
            model.send(command, to: source)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 14, height: 14)
        }
        .glassControl()
        .help(L10n.string(key))
        .accessibilityLabel(L10n.string(key))
    }
}

struct MasterRow: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string("master.title"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.outputDeviceName.isEmpty {
                    Label(model.outputDeviceName, systemImage: "speaker.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            VolumeSlider(value: model.settings.masterVolume) { model.setMasterVolume($0) }
            LevelMeter(level: model.masterLevel)
                .padding(.leading, 18)
                .padding(.trailing, 44)
        }
        .surfaceCard()
    }
}

struct EmptySourcesHint: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.string("empty.title"), systemImage: "airplay.audio")
                .font(.system(size: 12, weight: .semibold))
            Text(L10n.format("empty.body", model.receiverName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }
}

struct MixerContent: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            MasterRow(model: model)
            ForEach(model.sources) { source in
                SourceRow(model: model, source: source)
            }
            if model.airPlaySources.isEmpty {
                EmptySourcesHint(model: model)
            }
        }
    }
}

struct ReceiverStatusLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.receiverState {
            case .ready:
                StatusDot(color: Color(red: 0.42, green: 0.78, blue: 0.68))
                Text(L10n.string("receiver.ready"))
            case .starting:
                StatusDot(color: .secondary.opacity(0.5))
                Text(L10n.string("receiver.starting"))
            case .failed:
                StatusDot(color: Color(red: 0.93, green: 0.62, blue: 0.55))
                Text(L10n.string("receiver.failed"))
            case .stopped:
                StatusDot(color: .secondary.opacity(0.5))
                Text(L10n.string("receiver.stopped"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
