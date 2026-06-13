import SwiftUI

// Decision D-2 (sub-navigation): Transcription vs AI Analysis stay under a single
// "AI & Models" sidebar entry, switched by a native segmented Picker at the top of
// the pane (rather than two separate sidebar rows). Keeps the already-busy Settings
// sidebar compact while using a stock SwiftUI control.
struct SettingsAIModelsTab: View {
    enum SubTab: String, CaseIterable {
        case transcription = "Transcription"
        case ai = "AI Analysis"
    }

    @State private var selectedSubTab: SubTab = .transcription

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch selectedSubTab {
            case .transcription:
                SettingsTranscriptionTab()
            case .ai:
                SettingsAITab()
            }
        }
    }
}
