import SwiftUI

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        let text = CallPromptText.detected(app: appState.detectedCallApp)
        CallAlertCard(
            title: text.title,
            message: text.message,
            dismissLabel: String(localized: "Dismiss"),
            onDismiss: { appState.showCallDetectedPopup = false }
        ) {
            if let target = CallDetectionService.muteTarget(forBundleId: appState.detectedCallAppBundleId) {
                Button(String(localized: "Don't ask for \(target.name)")) { mute(target) }
                    .buttonStyle(CallMuteButtonStyle())
                    .help("Stop call prompts for this app. Turn it back on in Settings → Meetings.")
            }
        } actions: {
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
                Label("Record call", systemImage: "mic.fill")
            }
            // The panel's Record button style: the one filled, accent-coloured action.
            .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 30, fontSize: 13, fillsWidth: false))
            .keyboardShortcut(.defaultAction)
        }
    }

    private func mute(_ target: CallDetectionService.MuteTarget) {
        appSettings.disabledCallApps.insert(target.bundleId)
        appState.showCallDetectedPopup = false
        appState.announcer.announce(
            String(localized: "dBrief won't ask for \(target.name) calls. Turn it back on in Settings → Meetings."),
            priority: .normal
        )
    }
}

/// The prompt's quiet leading action: secondary text that underlines on hover, so the
/// two buttons on the right stay the obvious choices.
private struct CallMuteButtonStyle: ButtonStyle {
    @Environment(\.viewerPalette) private var palette
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 11))
            .underline(isHovering)
            .foregroundStyle(palette.secondary.color.opacity(configuration.isPressed ? 0.6 : 1))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
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
struct CallAlertCard<Leading: View, Actions: View>: View {
    let title: String
    let message: String
    let dismissLabel: String
    let onDismiss: () -> Void
    /// Shown at the start of the actions row (e.g. "Don't ask for Zoom").
    @ViewBuilder var leading: Leading
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
                leading
                Spacer(minLength: 0)
                actions.fixedSize()
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

extension CallAlertCard where Leading == EmptyView {
    init(title: String, message: String, dismissLabel: String, onDismiss: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions) {
        self.init(title: title, message: message, dismissLabel: dismissLabel, onDismiss: onDismiss,
                  leading: { EmptyView() }, actions: actions)
    }
}
