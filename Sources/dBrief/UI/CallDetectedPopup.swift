import SwiftUI

struct CallDetectedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        ZStack {
            // Glass background — matches native macOS notification style
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)

            // Signature brand gradient top bar
            VStack(spacing: 0) {
                Brand.gradient.frame(height: 3)
                Spacer()
            }

            // Content — icon vertically centered against text block
            HStack(alignment: .center, spacing: 14) {
                // dBrief app icon + live alert dot
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        BrandStatusDot(color: Brand.recording, size: 13, pulse: true)
                            .padding(2)
                            .background(.background, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    BrandKicker("Call detected", color: Brand.coral)

                    Text("\(appState.detectedCallApp.map { "\($0) call" } ?? "A call") detected")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("Want dBrief to record and brief it?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Button("Not now") {
                            appState.showCallDetectedPopup = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            appState.showCallDetectedPopup = false
                            Task {
                                try? await recordingManager.startRecording(
                                    associatedApp: appState.detectedCallApp
                                )
                            }
                        } label: {
                            HStack(spacing: 7) {
                                RecordGlyph(size: 14)
                                Text("Record")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Brand.gradientDiagonal, in: Capsule())
                            .shadow(color: Brand.coral.opacity(0.5), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
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
        .frame(width: 380, height: 132)
        // Clip to the card shape so the gradient top bar follows the rounded
        // corners instead of overhanging them as a straight line.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

