import SwiftUI

struct AppleSpeechLanguagePicker: View {
    @Binding var selection: String
    var title = "Audio language"

    private var selectedID: String {
        selection.isEmpty ? "" : AppleSpeechLanguages.explicitIdentifier(selection) ?? selection
    }
    private var available: Bool { AppleSpeechLanguages.identifier(for: selection) != nil }

    var body: some View {
        Picker(title, selection: Binding(get: { selectedID }, set: { selection = $0 })) {
            if AppleSpeechLanguages.identifier(for: "") != nil {
                Text("System language").tag("")
            }
            if !available {
                Text("Choose a supported language…").tag(selectedID).disabled(true)
            }
            ForEach(AppleSpeechLanguages.choices) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
        .pickerStyle(.menu)
        if !available {
            Text("The saved language is unavailable with Apple Speech. Choose a supported language or change the transcription engine.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
