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

    @Environment(\.colorScheme) private var colorScheme

    @State private var isEditing = false
    @State private var isSaving = false
    @State private var copied = false
    /// Section keys the user has collapsed (Summary / Action items / Tags).
    @State private var collapsedSections: Set<String> = []

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
            VStack(spacing: 0) {
                header(for: insights)
                Divider()
                ScrollView {
                    Group {
                        if isEditing {
                            VStack(alignment: .leading, spacing: Theme.cardGap) {
                                summaryCard(availableHeight: geo.size.height)
                                actionItemsCard
                                tagsCard
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                        } else {
                            readLayout(wide: geo.size.width > 720)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlayScrollers()
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    // MARK: - Read layout (redesign)

    /// Wide with Summary expanded: prose fills its column with the action-items
    /// rail beside it, the pair capped to a comfortable measure and centred in the
    /// available width. Narrow — or whenever Summary is collapsed — everything
    /// stacks in a single centred column, so collapsing Summary drops the tasks +
    /// tags right below its header instead of leaving them stranded on the right.
    @ViewBuilder
    private func readLayout(wide: Bool) -> some View {
        if wide && !isCollapsed("summary") {
            HStack(alignment: .top, spacing: 48) {
                summarySection
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 28) {
                    actionsSection
                    tagsSection
                }
                .frame(width: 380)
            }
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                summarySection
                actionsSection
                tagsSection
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func isCollapsed(_ key: String) -> Bool { collapsedSections.contains(key) }

    /// Collapsible section header: tapping toggles its content via a rotating chevron.
    private func sectionHeader(key: String, icon: String, tint: Color, title: String, trailing: String? = nil) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsedSections.contains(key) { collapsedSections.remove(key) }
                else { collapsedSections.insert(key) }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.28), lineWidth: 1))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed(key) ? -90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(key: "summary", icon: "text.alignleft", tint: Color(hex: "8b4dff"), title: "Summary")
            if !isCollapsed("summary") {
                if draftSummary.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    MarkdownText(draftSummary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionsSection: some View {
        let groups = ActionItemParser.group(draftActionItems.map(\.text))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(key: "actions", icon: "checklist", tint: Color(hex: "30d158"), title: "Action items",
                          trailing: draftActionItems.isEmpty ? nil : "\(draftActionItems.count) total")
            if !isCollapsed("actions") {
                if draftActionItems.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { ownerCard($0) }
                }
            }
        }
    }

    private func ownerCard(_ group: ActionItemGroup) -> some View {
        let tint = group.isUnassigned ? Color.secondary : Theme.speakerColor(for: group.owner)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if group.isUnassigned {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                } else {
                    SpeakerAvatar(speakerId: group.owner, name: group.owner, size: 22)
                }
                Text(group.owner)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                Spacer(minLength: 8)
                Text("\(group.items.count)")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.16), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.items) { item in
                    actionRow(item)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(TranscriptDesignTokens.cardBorder(scheme: colorScheme), lineWidth: 1))
                .shadow(color: TranscriptDesignTokens.cardShadowColor(scheme: colorScheme),
                        radius: TranscriptDesignTokens.cardShadowRadius(scheme: colorScheme), x: 0, y: 1)
        }
    }

    private func actionRow(_ item: ParsedActionItem) -> some View {
        let done = completed.contains(item.raw)
        return Button {
            if done { completed.remove(item.raw) } else { completed.insert(item.raw) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle()
                        .strokeBorder(done ? Color(hex: "30d158") : Color.secondary.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(hex: "30d158"))
                    }
                }
                .padding(.top, 1)
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : TranscriptDesignTokens.bodyText(scheme: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.text))
        .accessibilityAddTraits(done ? [.isSelected] : [])
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(key: "tags", icon: "tag", tint: Color(hex: "25abff"), title: "Tags")
            if !isCollapsed("tags") {
                if draftTags.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 7) {
                        ForEach(draftTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme).opacity(0.85))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4)
                                .background(TranscriptDesignTokens.chipFill(scheme: colorScheme), in: Capsule())
                                .overlay(Capsule().strokeBorder(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 1))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .buttonStyle(SummaryPillButtonStyle(scheme: colorScheme, tint: copied ? .green : nil))
            .disabled(isEditing)

            if isEditing {
                Button("Cancel") { sync(); isEditing = false }
                    .buttonStyle(SummaryPillButtonStyle(scheme: colorScheme))
                Button {
                    Task { await save(base: insights) }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .buttonStyle(SummaryPillButtonStyle(scheme: colorScheme, prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            } else {
                Button { sync(); isEditing = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(SummaryPillButtonStyle(scheme: colorScheme))
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        // Match the assistant inspector header height (52) so this header's
        // bottom divider lines up with the assistant panel's divider.
        .frame(height: 52)
    }

    // MARK: - Summary card

    /// `availableHeight` is the detail pane's height; in edit mode the summary
    /// editor takes a generous share of it (min 240) so it's comfortable to type
    /// in immediately and grows with the window instead of staying cramped.
    private func summaryCard(availableHeight: CGFloat) -> some View {
        GroupBox {
            if isEditing {
                TextEditor(text: $draftSummary)
                    .font(.body)
                    .frame(minHeight: max(240, availableHeight * 0.55))
                    .scrollContentBackground(.hidden)
            } else if draftSummary.isEmpty {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(draftSummary)
                    .font(.body)
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
                .padding(.bottom, 6)
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

/// Compact capsule button used for the Summary header actions (Copy / Edit /
/// Save / Cancel). A glass pill by default; `prominent` fills with the brand
/// gradient for the primary Save action; `tint` recolours the label (e.g. the
/// green "Copied" confirmation).
private struct SummaryPillButtonStyle: ButtonStyle {
    let scheme: ColorScheme
    var prominent: Bool = false
    var tint: Color? = nil

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(background(pressed: configuration.isPressed))
            }
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(TranscriptDesignTokens.chipBorder(scheme: scheme), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }

    private var foreground: AnyShapeStyle {
        if prominent { return AnyShapeStyle(.white) }
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(TranscriptDesignTokens.bodyText(scheme: scheme).opacity(0.85))
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        if prominent {
            return AnyShapeStyle(TranscriptDesignTokens.brandGradient.opacity(pressed ? 0.8 : 1))
        }
        return AnyShapeStyle(TranscriptDesignTokens.chipFill(scheme: scheme).opacity(pressed ? 0.6 : 1))
    }
}
