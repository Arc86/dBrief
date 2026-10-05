import SwiftUI

struct CallEndedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        // Dismissing keeps recording.
        CallAlertCard(
            title: "\(appState.callEndedApp ?? "Call") ended",
            message: "Stop recording and create the meeting brief?",
            dismissLabel: "Keep recording",
            onDismiss: { appState.showCallEndedPopup = false }
        ) {
            Button("Keep recording") {
                appState.showCallEndedPopup = false
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 37, fillsWidth: false))

            Button {
                appState.showCallEndedPopup = false
                appState.callRecordingBundleId = nil
                Task {
                    await recordingManager.stopRecording()
                }
            } label: {
                Label("Stop", systemImage: "stop")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .danger, height: 37, fillsWidth: false))
            .keyboardShortcut(.defaultAction)
        }
    }
}
