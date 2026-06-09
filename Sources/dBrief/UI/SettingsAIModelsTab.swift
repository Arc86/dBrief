import SwiftUI

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
