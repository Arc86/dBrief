import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI

struct SettingsPermissionsTab: View {
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingGranted = false
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined

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
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            refreshStatuses()
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

    private var micActionTitle: String {
        micStatus == .authorized ? "Granted" : "Request"
    }

    private var screenStatusText: String {
        screenRecordingGranted ? "Granted" : "Not granted"
    }

    private var screenStatusStyle: Color {
        screenRecordingGranted ? .green : .orange
    }

    private var screenActionTitle: String {
        screenRecordingGranted ? "Granted" : "Request"
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

    private var speechActionTitle: String {
        speechStatus == .authorized ? "Granted" : "Request"
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

    private var calendarActionTitle: String {
        calendarStatus == .fullAccess ? "Granted" : "Request"
    }

    @MainActor
    private func refreshStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func requestMicrophone() {
        guard micStatus != .authorized else { return }
        Task.detached {
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run {
                refreshStatuses()
            }
        }
    }

    private func requestScreenRecording() {
        guard !screenRecordingGranted else { return }
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            refreshStatuses()
        }
    }

    private func requestSpeechRecognition() {
        guard speechStatus != .authorized else { return }
        Task.detached {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            await MainActor.run {
                refreshStatuses()
            }
        }
    }

    private func requestCalendar() {
        guard calendarStatus != .fullAccess else { return }
        Task.detached {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
            await MainActor.run {
                refreshStatuses()
            }
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
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(statusText)
                    .foregroundStyle(statusStyle)
                Button(actionTitle) {
                    action()
                }
                .disabled(actionTitle == "Granted")
                .buttonStyle(.bordered)
            }
        }
    }
}
