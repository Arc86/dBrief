import Testing
@testable import dBrief

struct PermissionAttentionTests {
    @Test func unusedPermissionsNeverCount() {
        #expect(PermissionAttention.count(microphone: .granted, screenRecording: .granted, speech: .denied, calendar: .notDetermined,
                                          needsSpeech: false, needsCalendar: false) == 0)
    }

    @Test func everyMissingPermissionInUseCounts() {
        #expect(PermissionAttention.count(microphone: .denied, screenRecording: .notDetermined, speech: .denied, calendar: .denied,
                                          needsSpeech: true, needsCalendar: true) == 4)
        #expect(PermissionAttention.count(microphone: .granted, screenRecording: .denied, speech: .granted, calendar: .restricted,
                                          needsSpeech: true, needsCalendar: true) == 2)
    }
}
