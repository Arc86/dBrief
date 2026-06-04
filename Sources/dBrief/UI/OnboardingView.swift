import AppKit
import CoreGraphics
import EventKit
import Speech
import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var step = 0
    @State private var hasSpeechPermission = false
    @State private var hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    var body: some View {
        VStack(spacing: 16) {
            switch step {
            case 0:
                welcomeStep
            case 1:
                permissionsStep
            case 2:
                endpointStep
            default:
                readyStep
            }
        }
        .padding()
        .frame(width: 300)
        .animation(.easeInOut(duration: 0.2), value: step)
        .task {
            hasSpeechPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            if let appIcon = appIconImage() {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
            }

            Text("Welcome to dBrief")
                .font(.headline)

            Text("Record, transcribe, and analyze voice recordings right from your menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Use **\u{2318}\u{21E7}R** to start/stop recording from anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Get Started") {
                step = 1
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Permissions")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                permissionRow(
                    granted: recordingManager.hasMicrophonePermission,
                    title: "Microphone",
                    subtitle: nil,
                    required: true
                )

                permissionRow(
                    granted: recordingManager.hasSystemAudioPermission,
                    title: "Screen Recording",
                    subtitle: "For system audio capture",
                    required: false
                )

                permissionRow(
                    granted: hasSpeechPermission,
                    title: "Speech Recognition",
                    subtitle: "For built-in transcription",
                    required: false
                )

                permissionRow(
                    granted: hasCalendarPermission,
                    title: "Calendar",
                    subtitle: "To pre-fill meeting title and participants",
                    required: false
                )
            }

            Text("Grant permissions in System Settings > Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Button("Screen Recording") {
                    CGRequestScreenCaptureAccess()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(recordingManager.hasSystemAudioPermission)

                Button("Speech") {
                    Task {
                        hasSpeechPermission = await LocalTranscriptionService.requestAccess()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hasSpeechPermission)

                if !hasCalendarPermission {
                    Button("Calendar") {
                        Task {
                            let store = EKEventStore()
                            _ = try? await store.requestFullAccessToEvents()
                            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Refresh") {
                    Task {
                        await recordingManager.checkPermissions()
                        hasSpeechPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
                        hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Continue") {
                step = 2
            }
            .buttonStyle(.borderedProminent)
            .disabled(!recordingManager.hasMicrophonePermission)
        }
    }

    private func permissionRow(granted: Bool, title: String, subtitle: String?, required: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : (required ? .red : .orange))
            VStack(alignment: .leading) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var endpointStep: some View {
        @Bindable var settings = appSettings
        return VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("Processing Engine")
                .font(.headline)

            Text("Choose how to transcribe and analyze your recordings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Transcription engine", selection: $settings.transcriptionEngine) {
                    ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .font(.callout)

                Picker("AI engine", selection: $settings.aiEngine) {
                    ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .font(.callout)
            }
            .padding(.horizontal, 4)

            if appSettings.transcriptionEngine == .remoteEndpoint || appSettings.aiEngine == .remoteEndpoint {
                Text("Configure external endpoints in Settings for Whisper / LLM services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Finish Setup") {
                step = 3
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.headline)

            Text("Click the waveform icon in the menu bar to start recording, or press **\u{2318}\u{21E7}R**.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                appSettings.hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
