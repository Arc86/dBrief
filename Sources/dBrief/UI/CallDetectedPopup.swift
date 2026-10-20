import SwiftUI

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        let text = CallPromptText.detected(app: appState.detectedCallApp)
        CallAlertCard(
            title: text.title,
            message: text.message,
            dismissLabel: String(localized: "Dismiss"),
            onDismiss: { appState.showCallDetectedPopup = false }
        ) {
            Button("Not now") {
                appState.showCallDetectedPopup = false
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fillsWidth: false))
            .keyboardShortcut(.cancelAction)

            Button {
                appState.showCallDetectedPopup = false
                Task {
                    await recordingManager.requestRecording(
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

/// Title and message of a call prompt. The card shows them; the panel also uses them
/// as its window title and VoiceOver announcement.
struct CallPromptText: Equatable {
    let title: String
    let message: String

    static func detected(app: String?) -> CallPromptText {
        CallPromptText(title: app.map { String(localized: "\($0) call detected") } ?? String(localized: "A call detected"),
                       message: String(localized: "Record this call and create a meeting brief."))
    }

    static func ended(app: String?) -> CallPromptText {
        CallPromptText(title: app.map { String(localized: "\($0) ended") } ?? String(localized: "Call ended"),
                       message: String(localized: "Stop recording and create the meeting brief?"))
    }

    var announcement: String { String(localized: "\(title). \(message)") }

    /// The card's fixed width; its height follows the text.
    static let cardWidth: CGFloat = 360
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
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                }
                .fixedSize(horizontal: false, vertical: true)
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
        // The height follows the text, so larger text sizes don't clip the buttons.
        .frame(width: CallPromptText.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
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
