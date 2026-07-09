import SwiftUI

struct CallEndedPopup: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.calmAppearance) private var calm

    var body: some View {
        ZStack {
            // Glass background — matches native macOS notification style
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)

            // Signature brand gradient top bar (solid coral in calm mode)
            VStack(spacing: 0) {
                Rectangle().fill(Brand.accentFill(calm: calm)).frame(height: 3)
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
                    BrandKicker("Call ended", color: Brand.coral)

                    Text("\(appState.callEndedApp ?? "Call") ended")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("Stop recording and brief it?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Button("Keep recording") {
                            appState.showCallEndedPopup = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            appState.showCallEndedPopup = false
                            appState.callRecordingBundleId = nil
                            Task {
                                await recordingManager.stopRecording()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Stop")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Brand.ctaFill(calm: calm), in: Capsule())
                            .shadow(color: Brand.ctaGlow(calm: calm), radius: calm ? 0 : 10, y: calm ? 0 : 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Dismiss button — top-trailing, on top. Dismissing keeps recording.
            Button {
                appState.showCallEndedPopup = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep recording")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 380, height: 132)
        // Clip to the card shape so the gradient top bar follows the rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
