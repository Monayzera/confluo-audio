import SwiftUI

extension View {
    @ViewBuilder
    func glassControl(active: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26, *) {
            if active {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if active {
                self.buttonStyle(.borderedProminent).tint(tint)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    func surfaceCard() -> some View {
        padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

struct LevelMeter: View {
    let level: Double
    var muted = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: muted ? [Color.secondary.opacity(0.35), Color.secondary.opacity(0.35)] : [Color(red: 0.42, green: 0.78, blue: 0.68), Color(red: 0.47, green: 0.66, blue: 0.93), Color(red: 0.93, green: 0.62, blue: 0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * min(max(level, 0), 1)))
                    .mask(alignment: .leading) {
                        Capsule().frame(width: proxy.size.width)
                    }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct VolumeSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1)
                .controlSize(.small)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}
