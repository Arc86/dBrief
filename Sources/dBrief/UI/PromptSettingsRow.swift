import SwiftUI

struct PromptSettingsRow: View {
    @Environment(AppContext.self) private var context
    @Environment(AppSettings.self) private var settings
    let kind: PromptKind
    var scope: PromptScope = .appDefaults

    var body: some View {
        let snapshot = try? PromptPreferencesStore(settings: settings).load(.init(kind: kind, scope: scope))
        let preview = snapshot.map { PromptDraft(snapshot: $0).text } ?? ""
        SettingsRow(verbatim: String(localized: "\(kind.title) · \(status(snapshot))"),
                    caption: preview.isEmpty ? nil : String(preview.prefix(160))) {
            Button("Edit…") { context.promptEditorWindows.show(.init(kind: kind, scope: scope)) }
                .buttonStyle(.settingsSecondary)
                .accessibilityLabel("Edit \(kind.title) prompt")
        }
    }

    private func status(_ snapshot: PromptSnapshot?) -> String {
        guard let snapshot else { return String(localized: "Unavailable") }
        switch snapshot.value {
        case .inherited: return String(localized: "Inherited")
        case .custom(let text): return scope == .appDefaults && text == snapshot.factoryText ? String(localized: "Default") : String(localized: "Customized")
        }
    }
}
