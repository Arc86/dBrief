import SwiftUI

private let brandOrange = Color(hex: "#FF6B00")
private let brandOrangeLight = Color(hex: "#FF9500")

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Glass background
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )

            // Content
            HStack(spacing: 10) {
                // Branded icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [brandOrange, brandOrangeLight],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("dBrief")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("\(appState.detectedCallApp.map { "\($0) call" } ?? "A call") detected")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Button("Not Now") {
                            appState.showCallDetectedPopup = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Record") {
                            appState.showCallDetectedPopup = false
                            Task {
                                try? await recordingManager.startRecording(
                                    associatedApp: appState.detectedCallApp
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(brandOrange)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Dismiss button — last in ZStack so it's on top for hit-testing
            Button {
                appState.showCallDetectedPopup = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(width: 320, height: 90)
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
