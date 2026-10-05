import SwiftUI

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        CallAlertCard(
            title: "\(appState.detectedCallApp.map { "\($0) call" } ?? "A call") detected",
            message: "Record this call and create a meeting brief.",
            dismissLabel: "Dismiss",
            onDismiss: { appState.showCallDetectedPopup = false }
        ) {
            Button("Not now") {
                appState.showCallDetectedPopup = false
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fillsWidth: false))

            Button {
                appState.showCallDetectedPopup = false
                Task {
                    try? await recordingManager.startRecording(
                        associatedApp: appState.detectedCallApp,
                        callBundleId: appState.detectedCallAppBundleId
                    )
                }
            } label: {
                Label("Record call", systemImage: "mic")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .accentOutline, height: 30, fillsWidth: false))
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The floating call prompt card: brand-gradient hairline border (flat accent with
/// Reduce neon), logo bars, title, message, close button and trailing actions.
struct CallAlertCard<Actions: View>: View {
    let title: String
    let message: String
    let dismissLabel: String
    let onDismiss: () -> Void
    @ViewBuilder var actions: Actions
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                BrandBarsMark(height: 28)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .uiFont(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                        .lineLimit(1)
                    Text(message)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondary.color)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360, height: 116)
        .background(palette.surface.color, in: shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: palette.brandStops.map(\.color), startPoint: .leading, endPoint: .trailing),
                lineWidth: 1.5
            )
            .allowsHitTesting(false)
        }
        .clipShape(shape)
    }
}
