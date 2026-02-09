import SwiftUI

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.fill")
                .font(.largeTitle)
                .foregroundStyle(.blue)

            Text("\(appState.detectedCallApp ?? "A call app") is running")
                .font(.headline)

            Text("Would you like to start recording?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Not Now") {
                    appState.showCallDetectedPopup = false
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Don't Ask Again") {
                    if let bundleId = appState.detectedCallAppBundleId {
                        appSettings.disabledCallApps.insert(bundleId)
                    }
                    appState.showCallDetectedPopup = false
                    dismiss()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)

                Button("Start Recording") {
                    appState.showCallDetectedPopup = false
                    dismiss()
                    Task {
                        try? await recordingManager.startRecording(
                            associatedApp: appState.detectedCallApp
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
