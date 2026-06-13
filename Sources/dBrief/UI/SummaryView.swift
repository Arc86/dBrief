import SwiftUI
import AppKit

/// The Summary view of the recording viewer: material-backed cards for the
/// Summary, Action Items (grouped by assignee), and Tags. Read-only by default;
/// an Edit toggle reveals plain editors and Save persists via `onSave`.
///
/// When no analysis exists it shows a "Generate summary" empty state wired to
/// `onGenerate` (re-runs the AI pipeline for the recording).
struct SummaryView: View {
    let insights: RecordingInsights?
    let isGenerating: Bool
    let canGenerate: Bool
    var onGenerate: () -> Void = {}
    var onSave: (RecordingInsights) async -> Void = { _ in }

    @State private var isEditing = false
    @State private var isSaving = false
    @State private var copied = false

    // Working copies for edit mode.
    @State private var draftSummary = ""
    @State private var draftActionItems: [String] = []
    @State private var draftTags: [String] = []

    // Ephemeral per-session "done" state for action-item checkboxes, keyed by raw text.
    @State private var completed: Set<String> = []

    var body: some View {
        Group {
            if isGenerating {
                generatingState
            } else if let insights, hasContent(insights) {
                content(for: insights)
            } else {
                emptyState
            }
        }
        .onAppear { sync() }
        .onChange(of: insights) { _, _ in if !isEditing { sync() } }
    }

    private func hasContent(_ i: RecordingInsights) -> Bool {
        !i.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !i.actionItems.isEmpty || !i.tags.isEmpty
    }

    private func sync() {
        guard let insights else { return }
        draftSummary = insights.summary
        draftActionItems = insights.actionItems
        draftTags = insights.tags
    }

    // MARK: - Loaded content

    private func content(for insights: RecordingInsights) -> some View {
        VStack(spacing: 0) {
            header(for: insights)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardGap) {
                    summaryCard
                    actionItemsCard
                    tagsCard
                }
                .padding(Theme.contentPadding)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func header(for insights: RecordingInsights) -> some View {
        HStack(spacing: 8) {
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
                Button("Cancel") { sync(); isEditing = false }
                Button {
                    Task { await save(base: insights) }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            } else {
                Button("Edit") { sync(); isEditing = true }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 8)
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        GroupBox {
            if isEditing {
                TextEditor(text: $draftSummary)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
            } else {
                Text(draftSummary.isEmpty ? "—" : draftSummary)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Summary", systemImage: "text.alignleft")
                .font(.headline)
        }
    }

    // MARK: - Action items card

    @ViewBuilder
    private var actionItemsCard: some View {
        GroupBox {
            if isEditing {
                editableActionItems
            } else if draftActionItems.isEmpty {
                Text("—").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let groups = ActionItemParser.group(draftActionItems)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        ownerGroup(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Action Items", systemImage: "checklist")
                .font(.headline)
        }
    }

    private func ownerGroup(_ group: ActionItemGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.items) { item in
                    Toggle(isOn: Binding(
                        get: { completed.contains(item.raw) },
                        set: { isOn in
                            if isOn { completed.insert(item.raw) } else { completed.remove(item.raw) }
                        }
                    )) {
                        Text(item.text)
                            .strikethrough(completed.contains(item.raw))
                            .foregroundStyle(completed.contains(item.raw) ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 2)
        } label: {
            HStack(spacing: 8) {
                if group.isUnassigned {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                } else {
                    SpeakerAvatar(speakerId: group.owner, name: group.owner, size: 22)
                }
                Text(group.owner)
                    .font(.body.weight(.medium))
                Text("\(group.items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var editableActionItems: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(draftActionItems.indices, id: \.self) { idx in
                HStack(spacing: 6) {
                    TextField("Action item", text: $draftActionItems[idx])
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        draftActionItems.remove(at: idx)
                    } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }
            Button {
                draftActionItems.append("")
            } label: { Label("Add Item", systemImage: "plus.circle") }
                .buttonStyle(.plain)
                .font(.callout)
        }
    }

    // MARK: - Tags card

    private var tagsCard: some View {
        GroupBox {
            if isEditing {
                TextField("Comma-separated tags", text: Binding(
                    get: { draftTags.joined(separator: ", ") },
                    set: { draftTags = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty } }
                ))
                .textFieldStyle(.roundedBorder)
            } else if draftTags.isEmpty {
                Text("—").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(draftTags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Tags", systemImage: "tag")
                .font(.headline)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Summary Yet", systemImage: "sparkles")
        } description: {
            Text(canGenerate
                 ? "Generate an AI summary, action items, and tags for this recording."
                 : "A transcript is needed before a summary can be generated.")
        } actions: {
            if canGenerate {
                Button("Generate Summary", action: onGenerate)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var generatingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Generating summary…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    private func save(base: RecordingInsights) async {
        isSaving = true
        defer { isSaving = false }
        var updated = base
        updated.summary = draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.actionItems = draftActionItems
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.tags = draftTags
        // sentiment unchanged (display-only)
        await onSave(updated)
        isEditing = false
    }
}
