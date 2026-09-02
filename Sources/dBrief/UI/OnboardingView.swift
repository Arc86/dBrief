import AppKit
import CoreGraphics
import EventKit
import Speech
import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @AppStorage("permissions.didRequestScreenCapture") private var didRequestScreenCapture = false

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
            refreshPermissionStatuses()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshPermissionStatuses()
            }
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

            bodyText("Enable at least one audio source. Use Microphone for your voice, Screen Recording for system audio, or both for calls.")

            VStack(spacing: 8) {
                permissionRow(
                    state: recordingManager.microphoneAuthorizationState,
                    title: "Microphone",
                    subtitle: "Records your voice",
                    action: handleMicrophonePermission
                )

                permissionRow(
                    state: systemAudioPermissionState,
                    title: "Screen Recording",
                    subtitle: "Captures system audio (other people on calls)",
                    action: handleScreenRecordingPermission
                )

                permissionRow(
                    state: speechPermissionState,
                    title: "Speech Recognition",
                    subtitle: "For built-in Apple transcription",
                    action: handleSpeechPermission
                )

                permissionRow(
                    state: calendarPermissionState,
                    title: "Calendar",
                    subtitle: "Pre-fills meeting title and participants",
                    action: handleCalendarPermission
                )
            }

            if !canContinueWithAudioPermissions {
                Label("Enable Microphone, Screen Recording, or both to continue.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Refresh") {
                    refreshPermissionStatuses()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Continue") {
                    step = 2
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinueWithAudioPermissions)
            }
        }
    }

    private func permissionRow(
        state: PermissionAuthorizationState,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: permissionIcon(for: state))
                .font(.system(size: 18))
                .foregroundStyle(state.isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if state.isGranted {
                Text("Granted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            } else if let actionTitle = permissionActionTitle(for: state) {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("Restricted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var systemAudioPermissionState: PermissionAuthorizationState {
        if recordingManager.hasSystemAudioPermission { return .granted }
        return didRequestScreenCapture ? .denied : .notDetermined
    }

    private var speechPermissionState: PermissionAuthorizationState {
        switch speechStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    private var calendarPermissionState: PermissionAuthorizationState {
        switch calendarStatus {
        case .notDetermined, .writeOnly: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .fullAccess: .granted
        @unknown default: .restricted
        }
    }

    private var canContinueWithAudioPermissions: Bool {
        PermissionRecoveryPolicy.canContinue(audioSourceStates: [
            recordingManager.microphoneAuthorizationState,
            systemAudioPermissionState,
        ])
    }

    private func permissionActionTitle(for state: PermissionAuthorizationState) -> String? {
        switch PermissionRecoveryPolicy.action(for: state) {
        case .requestAccess: "Grant"
        case .openSystemSettings: "Open Settings"
        case .explainRestriction, .none: nil
        }
    }

    private func permissionIcon(for state: PermissionAuthorizationState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .restricted: "lock.circle.fill"
        case .denied: "exclamationmark.circle.fill"
        case .notDetermined: "circle"
        }
    }

    private func refreshPermissionStatuses() {
        recordingManager.refreshPermissions()
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func handleMicrophonePermission() {
        switch PermissionRecoveryPolicy.action(for: recordingManager.microphoneAuthorizationState) {
        case .requestAccess:
            Task { _ = await recordingManager.requestMicrophonePermission() }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Microphone")
        case .explainRestriction, .none:
            break
        }
    }

    private func handleScreenRecordingPermission() {
        switch PermissionRecoveryPolicy.action(for: systemAudioPermissionState) {
        case .requestAccess:
            didRequestScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
            refreshPermissionStatuses()
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_ScreenCapture")
        case .explainRestriction, .none:
            break
        }
    }

    private func handleSpeechPermission() {
        switch PermissionRecoveryPolicy.action(for: speechPermissionState) {
        case .requestAccess:
            Task {
                _ = await LocalTranscriptionService.requestAccess()
                refreshPermissionStatuses()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_SpeechRecognition")
        case .explainRestriction, .none:
            break
        }
    }

    private func handleCalendarPermission() {
        switch PermissionRecoveryPolicy.action(for: calendarPermissionState) {
        case .requestAccess:
            Task {
                let store = EKEventStore()
                _ = try? await store.requestFullAccessToEvents()
                refreshPermissionStatuses()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Calendars")
        case .explainRestriction, .none:
            break
        }
    }

    private func openSystemSettingsPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
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
