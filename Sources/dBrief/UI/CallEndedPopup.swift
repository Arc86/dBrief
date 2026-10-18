import SwiftUI

struct CallEndedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        // Dismissing keeps recording.
        let text = CallPromptText.ended(app: appState.callEndedApp)
        CallAlertCard(
            title: text.title,
            message: text.message,
            dismissLabel: "Keep recording",
            onDismiss: { appState.showCallEndedPopup = false }
        ) {
            Button("Keep recording") {
                appState.showCallEndedPopup = false
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30, fillsWidth: false))
            .keyboardShortcut(.cancelAction)

            Button {
                appState.showCallEndedPopup = false
                appState.callRecordingBundleId = nil
                Task {
                    await recordingManager.stopRecording()
                }
            } label: {
                Label("Stop", systemImage: "stop")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 30, fillsWidth: false))
            .keyboardShortcut(.defaultAction)
        }
    }
}
