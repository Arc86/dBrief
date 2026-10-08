import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI

enum PermissionAttention {
    /// Missing permissions that block something the user has turned on. Microphone and
    /// screen recording always matter; speech only for Apple Speech or the live preview;
    /// calendar only when the calendar source is iCal.
    static func count(microphone: PermissionAuthorizationState, screenRecording: PermissionAuthorizationState,
                      speech: PermissionAuthorizationState, calendar: PermissionAuthorizationState,
                      needsSpeech: Bool, needsCalendar: Bool) -> Int {
        var states = [microphone, screenRecording]
        if needsSpeech { states.append(speech) }
        if needsCalendar { states.append(calendar) }
        return states.filter { $0 != .granted }.count
    }
}

/// Live permission states for the Settings window: the Permissions page and the
/// sidebar badge read the same instance.
@MainActor @Observable
final class SettingsPermissionStatus {
    static let didRequestScreenCaptureKey = "permissions.didRequestScreenCapture"

    var microphone: PermissionAuthorizationState = .notDetermined
    var screenRecording: PermissionAuthorizationState = .notDetermined
    var speech: PermissionAuthorizationState = .notDetermined
    var calendar: PermissionAuthorizationState = .notDetermined

    func refresh() {
        microphone = Self.state(AVCaptureDevice.authorizationStatus(for: .audio))
        let didRequestScreenCapture = UserDefaults.standard.bool(forKey: Self.didRequestScreenCaptureKey)
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : (didRequestScreenCapture ? .denied : .notDetermined)
        speech = Self.state(SFSpeechRecognizer.authorizationStatus())
        calendar = Self.state(EKEventStore.authorizationStatus(for: .event))
    }

    func attentionCount(settings: AppSettings) -> Int {
        PermissionAttention.count(
            microphone: microphone, screenRecording: screenRecording, speech: speech, calendar: calendar,
            needsSpeech: settings.effectiveTranscriptionEngine == .appleSpeech || settings.liveTranscriptionEnabled,
            needsCalendar: settings.effectiveCalendarSource == .iCal)
    }

    static func state(_ status: AVAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    static func state(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .restricted
        }
    }

    static func state(_ status: EKAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .notDetermined, .writeOnly: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .granted
        @unknown default: .restricted
        }
    }
}
