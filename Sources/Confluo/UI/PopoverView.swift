import SwiftUI

struct PopoverView: View {
    let model: AppModel
    let openWindow: (MainSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confluo")
                        .font(.system(size: 15, weight: .bold))
                    ReceiverStatusLabel(model: model)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        openWindow(.mixer)
                    } label: {
                        Image(systemName: "macwindow")
                            .frame(width: 16, height: 14)
                    }
                    .glassControl()
                    .help(L10n.string("action.openWindow"))
                    .accessibilityLabel(L10n.string("action.openWindow"))

                    Button {
                        openWindow(.settings)
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 16, height: 14)
                    }
                    .glassControl()
                    .help(L10n.string("section.settings"))
                    .accessibilityLabel(L10n.string("section.settings"))

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .frame(width: 16, height: 14)
                    }
                    .glassControl()
                    .help(L10n.string("action.quit"))
                    .accessibilityLabel(L10n.string("action.quit"))
                }
                .controlSize(.small)
                .glassGroup(spacing: 6)
            }

            if let error = model.lastError {
                ErrorBanner(message: error) { model.clearError() }
            }

            ScrollView {
                MixerContent(model: model)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.93, green: 0.62, blue: 0.55))
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.string("action.dismiss"))
        }
        .padding(10)
        .background(Color(red: 0.93, green: 0.62, blue: 0.55).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
