import SwiftUI
import AppKit

/// The menu panel's notices: errors, warnings and results, newest first, each
/// with its own Copy, action and dismiss. Replaces the single error box.
struct NoticeStack: View {
    var notices: [AppNotice]
    var limit = 3
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notices.prefix(limit)) { notice in
                    NoticeCard(notice: notice, perform: perform) { appState.notices.dismiss(notice.id) }
                }
            }
        }
    }

    private func perform(_ action: NoticeAction) {
        switch action {
        case .openQueue:
            appState.showInQueue(UUID())
        case .reviewIntegrations(let url):
            Task { await recordingManager.reviewIntegrationDeliveries(for: url) }
        case .openRecording(let url):
            appState.pendingTranscriptSelectionURL = url
            MenuBarPanel.open("transcript", with: openWindow)
        case .retryCaptureRecovery:
            Task {
                await recordingManager.recoverInterruptedSessions()
                await recordingManager.refreshWorkQueue()
            }
        case .showRecoveryFiles:
            MenuBarPanel.open(InterruptedSessionStore.defaultRootURL)
        }
    }
}

struct NoticeCard: View {
    let notice: AppNotice
    let perform: (NoticeAction) -> Void
    let dismiss: () -> Void
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    private var text: String { UserFacingError.text(notice.message) }

    private var tint: Color {
        switch notice.tone {
        case .error: status.danger.color
        case .warning: status.warning.color
        case .info: status.success.color
        }
    }

    private var symbol: String {
        switch notice.tone {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(text)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                if !notice.actions.isEmpty || notice.tone == .error {
                    HStack(spacing: 8) {
                        ForEach(notice.actions, id: \.title) { action in
                            Button(action.title) { perform(action) }
                        }
                        if notice.tone == .error {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                            .help("Copy the message")
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 24, fontSize: 11, fillsWidth: false))
                }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 18))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
    }

    private var background: Color {
        switch notice.tone {
        case .error: status.dangerFill.color
        case .warning: status.warning.color.opacity(0.12)
        case .info: status.successFill.color
        }
    }
}
