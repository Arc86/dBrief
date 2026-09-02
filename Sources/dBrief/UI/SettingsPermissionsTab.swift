import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI

struct SettingsPermissionsTab: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingGranted = false
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined
    @AppStorage("permissions.didRequestScreenCapture") private var didRequestScreenCapture = false

    var body: some View {
        Form {
            Section("Permissions Check") {
                PermissionRow(
                    title: "Microphone",
                    statusText: micStatusText,
                    statusStyle: micStatusStyle,
                    actionTitle: micActionTitle,
                    action: requestMicrophone
                )

                PermissionRow(
                    title: "Screen Recording (System Audio)",
                    statusText: screenStatusText,
                    statusStyle: screenStatusStyle,
                    actionTitle: screenActionTitle,
                    action: requestScreenRecording
                )

                PermissionRow(
                    title: "Speech Recognition",
                    statusText: speechStatusText,
                    statusStyle: speechStatusStyle,
                    actionTitle: speechActionTitle,
                    action: requestSpeechRecognition
                )

                PermissionRow(
                    title: "Calendar",
                    statusText: calendarStatusText,
                    statusStyle: calendarStatusStyle,
                    actionTitle: calendarActionTitle,
                    action: requestCalendar
                )
            }
            .listRowBackground(Color.clear)

            Section("Manage Access") {
                LabeledContent("Open System Settings") {
                    HStack {
                        Button("Microphone") {
                            openSystemSettingsPane("Privacy_Microphone")
                        }
                        .buttonStyle(.bordered)
                        Button("Screen Recording") {
                            openSystemSettingsPane("Privacy_ScreenCapture")
                        }
                        .buttonStyle(.bordered)
                        Button("Speech") {
                            openSystemSettingsPane("Privacy_SpeechRecognition")
                        }
                        .buttonStyle(.bordered)
                        Button("Calendar") {
                            openSystemSettingsPane("Privacy_Calendars")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                LabeledContent("Refresh permission status") {
                    Button("Refresh") {
                        refreshStatuses()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
        .onAppear {
            refreshStatuses()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshStatuses()
            }
        }
    }

    private var micStatusText: String {
        switch micStatus {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not determined"
        @unknown default: "Unknown"
        }
    }

    private var micStatusStyle: Color {
        micStatus == .authorized ? .green : .orange
    }

    private var micActionTitle: String? {
        actionTitle(for: permissionState(for: micStatus))
    }

    private var screenStatusText: String {
        screenRecordingGranted ? "Granted" : "Not granted"
    }

    private var screenStatusStyle: Color {
        screenRecordingGranted ? .green : .orange
    }

    private var screenActionTitle: String? {
        actionTitle(for: screenPermissionState)
    }

    private var speechStatusText: String {
        switch speechStatus {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not determined"
        @unknown default: "Unknown"
        }
    }

    private var speechStatusStyle: Color {
        speechStatus == .authorized ? .green : .orange
    }

    private var speechActionTitle: String? {
        actionTitle(for: permissionState(for: speechStatus))
    }

    private var calendarStatusText: String {
        switch calendarStatus {
        case .fullAccess: "Granted"
        case .writeOnly: "Write-only"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not determined"
        @unknown default: "Unknown"
        }
    }

    private var calendarStatusStyle: Color {
        calendarStatus == .fullAccess ? .green : .orange
    }

    private var calendarActionTitle: String? {
        actionTitle(for: permissionState(for: calendarStatus))
    }

    @MainActor
    private func refreshStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func requestMicrophone() {
        switch PermissionRecoveryPolicy.action(for: permissionState(for: micStatus)) {
        case .requestAccess:
            Task {
                _ = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
                refreshStatuses()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Microphone")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestScreenRecording() {
        switch PermissionRecoveryPolicy.action(for: screenPermissionState) {
        case .requestAccess:
            didRequestScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
            refreshStatuses()
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_ScreenCapture")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestSpeechRecognition() {
        switch PermissionRecoveryPolicy.action(for: permissionState(for: speechStatus)) {
        case .requestAccess:
            Task {
                _ = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
                refreshStatuses()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_SpeechRecognition")
        case .explainRestriction, .none:
            break
        }
    }

    private func requestCalendar() {
        switch PermissionRecoveryPolicy.action(for: permissionState(for: calendarStatus)) {
        case .requestAccess:
            Task {
                let store = EKEventStore()
                _ = try? await store.requestFullAccessToEvents()
                refreshStatuses()
            }
        case .openSystemSettings:
            openSystemSettingsPane("Privacy_Calendars")
        case .explainRestriction, .none:
            break
        }
    }

    private var screenPermissionState: PermissionAuthorizationState {
        if screenRecordingGranted { return .granted }
        return didRequestScreenCapture ? .denied : .notDetermined
    }

    private func permissionState(for status: AVAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    private func permissionState(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    private func permissionState(for status: EKAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined, .writeOnly: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .granted
        @unknown default: .restricted
        }
    }

    private func actionTitle(for state: PermissionAuthorizationState) -> String? {
        switch PermissionRecoveryPolicy.action(for: state) {
        case .requestAccess: "Request"
        case .openSystemSettings: "Open Settings"
        case .explainRestriction: nil
        case .none: "Granted"
        }
    }

    private func openSystemSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let statusText: String
    let statusStyle: Color
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(statusText)
                    .foregroundStyle(statusStyle)
                if let actionTitle {
                    Button(actionTitle) {
                        action()
                    }
                    .disabled(actionTitle == "Granted")
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
