import SwiftUI

private let brandOrange = Color(hex: "#FF6B00")
private let brandOrangeLight = Color(hex: "#FF9500")

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        ZStack {
            // Glass background — matches native macOS notification style
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)

            // Content — icon vertically centered against text block
            HStack(alignment: .center, spacing: 14) {
                // dBrief app icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(appState.detectedCallApp.map { "\($0) call" } ?? "A call") detected")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("Would you like to start recording?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Button("Not Now") {
                            appState.showCallDetectedPopup = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button("Record") {
                            appState.showCallDetectedPopup = false
                            Task {
                                try? await recordingManager.startRecording(
                                    associatedApp: appState.detectedCallApp
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(brandOrange)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Dismiss button — top-trailing, on top
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 360, height: 118)
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
