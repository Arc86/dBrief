import SwiftUI

struct SettingsAfterRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    let editProfile: (UUID) -> Void

    var body: some View {
        @Bindable var settings = appSettings
        let scope = SettingsProfileScope(settings: appSettings, fields: [])

        SettingsPageScaffold(page: .afterRecording, notice: {
            SettingsProfileScopeView(fields: SettingsPage.afterRecording.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Default tasks", description: "Pre-selected after every recording", section: .afterRecordingTasks) {
                SettingsRow("Transcribe", caption: "Available even when AI analysis is off.") {
                    Toggle("Transcribe", isOn: $settings.autoTranscribe)
                }
                SettingsRow("Write a summary", caption: "Needs AI analysis.") {
                    Toggle("Write a summary", isOn: $settings.autoSummary)
                }
                SettingsRow("Extract action items", caption: "Needs AI analysis.") {
                    Toggle("Extract action items", isOn: $settings.autoActionItems)
                }
                SettingsRow("Tags and sentiment", caption: "Needs AI analysis.") {
                    Toggle("Tags and sentiment", isOn: $settings.autoTags)
                }
                SettingsRow("Load calendar attendees", caption: "Works even when transcription and AI analysis are off.") {
                    Toggle("Load calendar attendees", isOn: $settings.autoLoadCalendarParticipants)
                }
            }

            SettingsCard("Active profile", description: "Profiles can override each task",
                         section: .afterRecordingAutomation) {
                SettingsRow(verbatim: scope.profile.name,
                            caption: "\(scope.profile.postRecordingPolicy.title) · \(scope.isAutomatic ? "chosen automatically" : "saved profile")",
                            systemImage: "person.3") {
                    Button("Edit in Profiles") { editProfile(scope.profile.id) }
                        .buttonStyle(.settingsSecondary)
                }
                SettingsRow("How automation works",
                            caption: "Automatic actions wait 10 seconds so you can choose Review instead. Queued work waits until you process it.")
            }
        }
    }
}
