import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI

struct SettingsPermissionsTab: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var appSettings
    @Environment(SettingsPermissionStatus.self) private var permissions
    @AppStorage(SettingsPermissionStatus.didRequestScreenCaptureKey) private var didRequestScreenCapture = false

    private var attention: Int { permissions.attentionCount(settings: appSettings) }

    var body: some View {
        SettingsPageScaffold(page: .permissions, notice: {
            if attention > 0 {
                SettingsNotice(Text(attention == 1 ? "1 permission needs attention." : "\(attention) permissions need attention."),
                               tone: .warning) {
                    Button("Refresh") { permissions.refresh() }.buttonStyle(.settingsSecondary)
                }
            }
        }) {
            SettingsCard("Access", section: .permissions) {
                row("Microphone", caption: "Required to record.", icon: "mic",
                    state: permissions.microphone, action: requestMicrophone)
                row("Screen recording", caption: "Captures the other side of calls (system audio).",
                    icon: "rectangle.on.rectangle", state: permissions.screenRecording, action: requestScreenRecording)
                row("Speech recognition", caption: "Only for Apple Speech and the live preview.", icon: "waveform",
                    state: permissions.speech, action: requestSpeechRecognition)
                row("Calendar", caption: "Pre-fills meeting titles and attendees.", icon: "calendar",
                    state: permissions.calendar, action: requestCalendar)
            }
        }
        .onAppear { permissions.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    private func row(_ title: LocalizedStringKey, caption: LocalizedStringKey, icon: String,
                     state: PermissionAuthorizationState, action: @escaping () -> Void) -> some View {
        SettingsRow(title, caption: caption, systemImage: icon) {
            HStack(spacing: 8) {
                switch state {
                case .granted: SettingsStatusPill("Allowed", kind: .success)
                case .denied: SettingsStatusPill("Denied", kind: .danger)
                case .restricted: SettingsStatusPill("Restricted", kind: .warning)
                case .notDetermined: SettingsStatusPill("Not asked", kind: .neutral)
                }
                if let title = actionTitle(for: state) {
                    Button(title, action: action).buttonStyle(.settingsSecondary)
                }
            }
        }
    }

    private func requestMicrophone() {
        switch PermissionRecoveryPolicy.action(for: permissions.microphone) {
        case .requestAccess:
            Task {
                _ = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
                permissions.refresh()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Microphone")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestScreenRecording() {
        switch PermissionRecoveryPolicy.action(for: permissions.screenRecording) {
        case .requestAccess:
            didRequestScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
            permissions.refresh()
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_ScreenCapture")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestSpeechRecognition() {
        switch PermissionRecoveryPolicy.action(for: permissions.speech) {
        case .requestAccess:
            Task {
                _ = await LocalTranscriptionService.requestAccess()
                permissions.refresh()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_SpeechRecognition")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestCalendar() {
        switch PermissionRecoveryPolicy.action(for: permissions.calendar) {
        case .requestAccess:
            Task {
                let store = EKEventStore()
                _ = try? await store.requestFullAccessToEvents()
                permissions.refresh()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Calendars")
        case .explainRestriction, .none:
            break
        }
    }

    private func actionTitle(for state: PermissionAuthorizationState) -> LocalizedStringKey? {
        switch PermissionRecoveryPolicy.action(for: state) {
        case .requestAccess: "Request"
        case .openSystemSettings: "Open System Settings"
        case .explainRestriction, .none: nil
        }
    }

    private func openSystemSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
