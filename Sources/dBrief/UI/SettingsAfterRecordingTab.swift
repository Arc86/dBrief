import SwiftUI

struct SettingsAfterRecordingTab: View {
    @Environment(AppSettings.self) private var appSettings
    let editProfile: (UUID) -> Void

    var body: some View {
        @Bindable var settings = appSettings
        let scope = SettingsProfileScope(settings: appSettings, fields: [])

        Form {
            Section {
                Toggle("Preselect transcription after recording", isOn: $settings.autoTranscribe)
                Toggle("Generate summary", isOn: $settings.autoSummary)
                Toggle("Extract action items", isOn: $settings.autoActionItems)
                Toggle("Analyze tags & sentiment", isOn: $settings.autoTags)
            } header: {
                SettingsSearchHeading("Task Defaults", section: .afterRecordingTasks)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These shared app defaults select the tasks offered after recording. Profiles can override each task in Profiles. The profile’s automation policy controls when those tasks start.")
                    Text("Summary, action items, and tags require AI analysis. Transcription remains available when AI analysis is off, and saved task choices are kept.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section {
                LabeledContent(scope.isAutomatic ? "Automatically selected profile" : "Selected profile") {
                    Text(scope.profile.name)
                }
                LabeledContent("After recording") {
                    Text(scope.profile.postRecordingPolicy.title)
                }
                Button("Edit \(scope.profile.name) in Profiles…") {
                    editProfile(scope.profile.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } header: {
                SettingsSearchHeading("Profile Automation", section: .afterRecordingAutomation)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each profile chooses whether to review, process automatically, or queue automatically. Automatic actions wait 10 seconds so you can choose Review instead. Queued work waits for manual processing later.")
                    Text("Edit the policy in Profiles. Opening the editor keeps your saved profile selection and automatic routing unchanged.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .toggleStyle(.smallSwitch)
        .padding(.top, -20)
    }
}
