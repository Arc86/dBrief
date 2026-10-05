import SwiftUI

/// A sheet draft for the action items and tags (the summary is edited inline in
/// `SummaryView`). The shell dismisses only after a verified save; an error
/// leaves these working copies available for retry.
struct RecordingAnalysisEditor: View {
    let baseline: RecordingInsights
    let isReadOnly: Bool
    let saveError: String?
    let onSave: (RecordingInsights) async -> Void
    let onCancel: () -> Void

    @Environment(\.viewerPalette) private var palette
    @State private var actions: [DraftAction]
    @State private var tags: String
    @State private var isSaving = false

    private struct DraftAction: Identifiable {
        let id = UUID()
        var text: String
    }

    init(baseline: RecordingInsights, isReadOnly: Bool, saveError: String?,
         onSave: @escaping (RecordingInsights) async -> Void, onCancel: @escaping () -> Void) {
        self.baseline = baseline
        self.isReadOnly = isReadOnly
        self.saveError = saveError
        self.onSave = onSave
        self.onCancel = onCancel
        _actions = State(initialValue: baseline.actionItems.map { DraftAction(text: $0) })
        _tags = State(initialValue: baseline.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit actions and tags").uiFont(.title2.weight(.semibold))
            if isReadOnly {
                Label("Reprocessing is in progress. Your draft is retained; editing is temporarily unavailable.", systemImage: "lock")
                    .uiFont(.callout)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Actions").uiFont(.headline)
                    ForEach($actions) { $action in
                        HStack(alignment: .top) {
                            TextField("Action", text: $action.text, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                actions.removeAll { $0.id == action.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Remove action")
                        }
                    }
                    Button("Add action", systemImage: "plus") { actions.append(DraftAction(text: "")) }
                    Text("Tags").uiFont(.headline)
                    TextField("Comma-separated tags", text: $tags)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Tags draft")
                }
                .disabled(isReadOnly || isSaving)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).disabled(isSaving)
                Button {
                    var edited = baseline
                    // Preserve every unchanged raw action key, including whitespace.
                    let rawActions = actions.map(\.text)
                    if rawActions != baseline.actionItems {
                        edited.actionItems = rawActions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    }
                    if tags != baseline.tags.joined(separator: ", ") {
                        edited.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                    isSaving = true
                    Task { await onSave(edited); isSaving = false }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isReadOnly || isSaving)
            }
            .buttonStyle(ViewerCommandButtonStyle())
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
        .foregroundStyle(palette.text.color)
        .background(palette.surface.color)
        .interactiveDismissDisabled(isSaving)
    }
}
