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
    /// Reading-text size, shared with the transcript's Display control.
    var fontSize: Int = 16
    var onGenerate: () -> Void = {}
    var onSave: (RecordingInsights) async -> Void = { _ in }

    @State private var isEditing = false
    @State private var isSaving = false
    @State private var copied = false

    /// One row in the editable action-items list. Carries a stable `id` so the
    /// edit `ForEach` keeps identity and deleting a focused row can't index past
    /// the array (the classic `ForEach(indices, id: \.self)` + `TextField` crash).
    private struct DraftActionItem: Identifiable {
        let id = UUID()
        var text: String
    }

    // Working copies for edit mode.
    @State private var draftSummary = ""
    @State private var draftActionItems: [DraftActionItem] = []
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        draftActionItems = insights.actionItems.map { DraftActionItem(text: $0) }
        draftTags = insights.tags
    }

    // MARK: - Loaded content

    private func content(for insights: RecordingInsights) -> some View {
        GeometryReader { geo in
            // When the pane is wide, run the summary prose beside a details rail
            // (Action Items + Tags) instead of stacking them in a narrow centered
            // column — this fills the horizontal space and surfaces action items
            // without scrolling. Editing always uses one column for clarity.
            let twoColumn = !isEditing && geo.size.width >= 1000
            VStack(spacing: 0) {
                header(for: insights)
                Divider()
                ScrollView {
                    Group {
                        if twoColumn {
                            HStack(alignment: .top, spacing: Theme.cardGap) {
                                summaryCard(availableHeight: geo.size.height)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                VStack(spacing: Theme.cardGap) {
                                    actionItemsCard
                                    tagsCard
                                }
                                .frame(width: 380, alignment: .topLeading)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: Theme.cardGap) {
                                summaryCard(availableHeight: geo.size.height)
                                actionItemsCard
                                tagsCard
                            }
                        }
                    }
                    .padding(Theme.contentPadding)
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
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

    /// `availableHeight` is the detail pane's height; in edit mode the summary
    /// editor takes a generous share of it (min 240) so it's comfortable to type
    /// in immediately and grows with the window instead of staying cramped.
    private func summaryCard(availableHeight: CGFloat) -> some View {
        GroupBox {
            if isEditing {
                TextEditor(text: $draftSummary)
                    .font(.system(size: CGFloat(fontSize)))
                    .frame(minHeight: max(240, availableHeight * 0.55))
                    .scrollContentBackground(.hidden)
            } else if draftSummary.isEmpty {
                Text("—")
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(draftSummary)
                    .font(.system(size: CGFloat(fontSize)))
                    .lineSpacing(CGFloat(fontSize) * 0.35)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Summary", systemImage: "text.alignleft")
                .font(.headline)
                .padding(.bottom, 6)
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
                let groups = ActionItemParser.group(draftActionItems.map(\.text))
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        ownerGroup(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Action Items", systemImage: "checklist")
                .font(.headline)
                .padding(.bottom, 6)
        }
    }

    /// One owner's action items: a light subheader (avatar · name · count) over a
    /// clean, always-visible checklist. Rows use a top-aligned tappable check so
    /// multi-line items read straight down instead of centering on the box, and the
    /// old per-owner disclosure chevron is gone (it added clutter, never collapsed).
    private func ownerGroup(_ group: ActionItemGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if group.isUnassigned {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                } else {
                    SpeakerAvatar(speakerId: group.owner, name: group.owner, size: 20)
                }
                Text(group.owner)
                    .font(.subheadline.weight(.semibold))
                Text("\(group.items.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(group.items) { item in
                    actionItemRow(item)
                }
            }
        }
    }

    private func actionItemRow(_ item: ParsedActionItem) -> some View {
        let isDone = completed.contains(item.raw)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button {
                if isDone { completed.remove(item.raw) } else { completed.insert(item.raw) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: CGFloat(fontSize)))
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .font(.system(size: CGFloat(fontSize)))
                .lineSpacing(3)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editableActionItems: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($draftActionItems) { $item in
                HStack(spacing: 6) {
                    TextField("Action item", text: $item.text)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        draftActionItems.removeAll { $0.id == item.id }
                    } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }
            Button {
                draftActionItems.append(DraftActionItem(text: ""))
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
                .padding(.bottom, 6)
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
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.tags = draftTags
        // sentiment unchanged (display-only)
        await onSave(updated)
        isEditing = false
    }
}
