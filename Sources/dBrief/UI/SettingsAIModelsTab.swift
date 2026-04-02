import SwiftUI

struct SettingsAIModelsTab: View {
    enum SubTab: String, CaseIterable {
        case transcription = "Transcription"
        case ai = "AI Analysis"
    }

    @State private var selectedSubTab: SubTab = .transcription

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Button {
                        selectedSubTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selectedSubTab == tab ? Color(NSColor.selectedControlColor) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch selectedSubTab {
            case .transcription:
                SettingsTranscriptionTab()
            case .ai:
                SettingsAITab()
            }
        }
    }
}
