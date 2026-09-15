import SwiftUI

struct PromptSettingsRow: View {
    @Environment(AppContext.self) private var context
    @Environment(AppSettings.self) private var settings
    let kind: PromptKind
    var scope: PromptScope = .appDefaults

    var body: some View {
        let snapshot = try? PromptPreferencesStore(settings: settings).load(.init(kind: kind, scope: scope))
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(kind.title)
                    Text(status(snapshot)).font(.caption).foregroundStyle(.secondary)
                }
                if let snapshot {
                    Text(PromptDraft(snapshot: snapshot).text)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit Prompt…") { context.promptEditorWindows.show(.init(kind: kind, scope: scope)) }
                .accessibilityLabel("Edit \(kind.title) prompt")
        }
        .padding(.vertical, 4)
    }
    private func status(_ snapshot: PromptSnapshot?) -> String {
        guard let snapshot else { return "Unavailable" }
        switch snapshot.value {
        case .inherited: return "Inherited"
        case .custom(let text): return scope == .appDefaults && text == snapshot.factoryText ? "Default" : "Customized"
        }
    }
}
