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

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 18) {
            Group {
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
            .transition(.opacity)

            stepIndicator
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: step)
        .task {
            hasSpeechPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    // MARK: - Shared chrome

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == step ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    /// A consistent multi-line body text style that wraps instead of truncating.
    private func bodyText(_ string: LocalizedStringKey) -> some View {
        Text(string)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func iconBadge(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 64, height: 64)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            if let appIcon = appIconImage() {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                iconBadge("waveform", tint: .accentColor)
            }

            Text("Welcome to dBrief")
                .font(.title3.weight(.semibold))

            bodyText("Record, transcribe, and analyze meetings and voice notes — right from your menu bar.")

            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("Press **\(appSettings.recordHotkey.displayString)** anytime to start or stop recording.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Get Started") {
                step = 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "dBrief-Icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 14) {
            iconBadge("lock.shield.fill", tint: .orange)

            Text("Permissions")
                .font(.title3.weight(.semibold))

            bodyText("dBrief needs a microphone to record. The rest are optional and unlock more features.")

            VStack(spacing: 8) {
                permissionRow(
                    granted: recordingManager.hasMicrophonePermission,
                    title: "Microphone",
                    subtitle: "Required to record audio",
                    required: true,
                    action: nil
                )

                permissionRow(
                    granted: recordingManager.hasSystemAudioPermission,
                    title: "Screen Recording",
                    subtitle: "Captures system audio (other people on calls)",
                    required: false,
                    action: recordingManager.hasSystemAudioPermission ? nil : { CGRequestScreenCaptureAccess() }
                )

                permissionRow(
                    granted: hasSpeechPermission,
                    title: "Speech Recognition",
                    subtitle: "For built-in Apple transcription",
                    required: false,
                    action: hasSpeechPermission ? nil : {
                        Task { hasSpeechPermission = await LocalTranscriptionService.requestAccess() }
                    }
                )

                permissionRow(
                    granted: hasCalendarPermission,
                    title: "Calendar",
                    subtitle: "Pre-fills meeting title and participants",
                    required: false,
                    action: hasCalendarPermission ? nil : {
                        Task {
                            let store = EKEventStore()
                            _ = try? await store.requestFullAccessToEvents()
                            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                        }
                    }
                )
            }

            HStack(spacing: 10) {
                Button("Refresh") {
                    Task {
                        await recordingManager.checkPermissions()
                        hasSpeechPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
                        hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Continue") {
                    step = 2
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!recordingManager.hasMicrophonePermission)
            }
        }
    }

    private func permissionRow(
        granted: Bool,
        title: String,
        subtitle: String,
        required: Bool,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                .font(.system(size: 18))
                .foregroundStyle(granted ? .green : (required ? .red : .secondary))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.callout.weight(.medium))
                    if required {
                        Text("Required")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if granted {
                Text("On")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            } else if let action {
                Button("Grant", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Step 2: Engines

    private var endpointStep: some View {
        @Bindable var settings = appSettings
        let needsEndpoint = appSettings.transcriptionEngine == .remoteEndpoint || appSettings.aiEngine == .remoteEndpoint
        return VStack(spacing: 14) {
            iconBadge("cpu", tint: .accentColor)

            Text("Transcription & AI")
                .font(.title3.weight(.semibold))

            bodyText("Pick how recordings are turned into text and summaries. The defaults run fully on-device — no account or server needed.")

            VStack(spacing: 12) {
                enginePicker(
                    title: "Transcription",
                    selection: $settings.transcriptionEngine,
                    cases: AppSettings.TranscriptionEngine.allCases,
                    label: { $0.displayName },
                    recommended: { $0.isRecommended },
                    description: appSettings.transcriptionEngine.shortDescription
                )

                if appSettings.transcriptionEngine == .appleSpeech {
                    ApplePrivacyBadge()
                }

                enginePicker(
                    title: "AI Analysis",
                    selection: $settings.aiEngine,
                    cases: AppSettings.AIEngine.allCases,
                    label: { $0.displayName },
                    recommended: { $0.isRecommended },
                    description: appSettings.aiEngine.shortDescription
                )
            }

            if needsEndpoint {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("Add your server URL and key in Settings before recording.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    SettingsLink { Text("Settings") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button("Continue") {
                step = 3
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func enginePicker<T: Hashable>(
        title: String,
        selection: Binding<T>,
        cases: [T],
        label: @escaping (T) -> String,
        recommended: @escaping (T) -> Bool,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                ForEach(cases, id: \.self) { item in
                    Text(recommended(item) ? "\(label(item))  ·  Recommended" : label(item))
                        .tag(item)
                }
            }
            .labelsHidden()

            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 14) {
            iconBadge("checkmark.circle.fill", tint: .green)

            Text("You're all set!")
                .font(.title3.weight(.semibold))

            bodyText("Click the dB icon in your menu bar to record, or press **\(appSettings.recordHotkey.displayString)** from anywhere. You can change anything later in Settings.")

            Button("Start Using dBrief") {
                appSettings.hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
