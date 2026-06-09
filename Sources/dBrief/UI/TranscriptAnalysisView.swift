import SwiftUI
import AppKit

/// AI-analysis panel shown in the transcript window: Summary / Action Items /
/// Tags+Sentiment in three glass cards. Read-only by default; Edit enables
/// editing, Save persists via the parent-supplied `onSave` closure.
struct TranscriptAnalysisView: View {
    /// The loaded analysis, or nil when no sidecar exists for this recording.
    let insights: RecordingInsights?
    /// Persist edited values. Receives the updated insights (sentiment unchanged).
    let onSave: (RecordingInsights) async -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var isEditing = false
    @State private var isSaving = false
    @State private var copied = false

    // Editable working copies
    @State private var summary = ""
    @State private var actionItems: [String] = []
    @State private var tags: [String] = []

    var body: some View {
        Group {
            if let insights {
                content(for: insights)
            } else {
                emptyState
            }
        }
        .background(TranscriptDesignTokens.windowBackground(scheme: colorScheme))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No saved analysis for this recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("AI analysis is saved automatically when a recording is processed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func content(for insights: RecordingInsights) -> some View {
        VStack(spacing: 0) {
            header(for: insights)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: TranscriptDesignTokens.cardGap) {
                    summaryCard
                    actionItemsCard
                    tagsCard(sentiment: insights.sentiment)
                }
                .padding(TranscriptDesignTokens.scrollPadding)
            }
        }
    }

    private func header(for insights: RecordingInsights) -> some View {
        HStack(spacing: 12) {
            Text("AI Analysis")
                .font(.headline)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(insights.plainTextForCopy(), forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(isEditing)

            if isEditing {
                Button("Cancel") { resetEdits(from: insights); isEditing = false }
                Button {
                    Task { await save(base: insights) }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            } else {
                Button("Edit") { resetEdits(from: insights); isEditing = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var summaryCard: some View {
        card(title: "Summary") {
            if isEditing {
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            } else {
                Text(summary.isEmpty ? "—" : summary)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionItemsCard: some View {
        card(title: "Action Items") {
            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(actionItems.indices, id: \.self) { idx in
                        HStack(spacing: 6) {
                            TextField("Action item", text: $actionItems[idx])
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                actionItems.remove(at: idx)
                            } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                        }
                    }
                    Button {
                        actionItems.append("")
                    } label: { Label("Add Item", systemImage: "plus.circle") }
                        .buttonStyle(.plain)
                        .font(.callout)
                }
            } else if actionItems.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(actionItems.indices, id: \.self) { idx in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "square")
                                .foregroundStyle(.secondary)
                            Text(actionItems[idx])
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tagsCard(sentiment: String) -> some View {
        card(title: "Tags & Sentiment") {
            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    TextField("Comma-separated tags", text: Binding(
                        get: { tags.joined(separator: ", ") },
                        set: { tags = $0.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.roundedBorder)
                } else if tags.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                if !sentiment.isEmpty {
                    Text("Sentiment: \(sentiment)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
            content()
        }
        .padding(TranscriptDesignTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TranscriptDesignTokens.cardFill(scheme: colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                .stroke(TranscriptDesignTokens.cardBorder(scheme: colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius))
    }

    // MARK: - Edit helpers

    private func resetEdits(from insights: RecordingInsights) {
        summary = insights.summary
        actionItems = insights.actionItems
        tags = insights.tags
    }

    private func save(base: RecordingInsights) async {
        isSaving = true
        defer { isSaving = false }
        var updated = base
        updated.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.actionItems = actionItems
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.tags = tags
        // sentiment unchanged (display-only)
        await onSave(updated)
        isEditing = false
    }
}
