import SwiftUI

/// A full-height reading document for the selected recording's summary, edited
/// inline with the Markdown block editor. The edit state is owned by the viewer
/// shell (`TranscriptDetailView`), which also persists the saved summary.
struct SummaryView: View {
    let insights: RecordingInsights?
    let isGenerating: Bool
    let canGenerate: Bool
    let isReadOnly: Bool
    let onGenerate: () -> Void
    @Binding var edit: SummaryEditState?
    let isCurrentTab: Bool
    let saveError: String?
    let onSaveEdit: () async -> Bool

    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSummaryCollapsed = false
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @State private var editorHeight: Double = 160
    @State private var editorHandle = MarkdownEditorHandle()

    init(
        insights: RecordingInsights?,
        isGenerating: Bool,
        canGenerate: Bool,
        isReadOnly: Bool = false,
        onGenerate: @escaping () -> Void = {},
        edit: Binding<SummaryEditState?> = .constant(nil),
        isCurrentTab: Bool = true,
        saveError: String? = nil,
        onSaveEdit: @escaping () async -> Bool = { false }
    ) {
        self.insights = insights
        self.isGenerating = isGenerating
        self.canGenerate = canGenerate
        self.isReadOnly = isReadOnly
        self.onGenerate = onGenerate
        self._edit = edit
        self.isCurrentTab = isCurrentTab
        self.saveError = saveError
        self.onSaveEdit = onSaveEdit
    }

    private var summaryText: String? {
        guard let summary = insights?.summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    private var hasOtherAnalysis: Bool {
        guard let insights else { return false }
        return !insights.actionItems.isEmpty || !insights.tags.isEmpty || !insights.sentiment.isEmpty
    }

    private var readingFont: Font {
        ViewerFonts.font(for: reading, effectiveMode: mode)
    }

    private var additionalLineSpacing: CGFloat {
        ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isGenerating {
                    generatingState
                } else if edit != nil {
                    editingDocument
                } else if let summaryText {
                    summaryDocument(summaryText)
                } else {
                    unavailableState
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
            .overlayScrollers()
        }
        .scrollIndicators(.automatic)
        .background(palette.canvas.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: insights?.summary) { _, _ in isSummaryCollapsed = false }
    }

    private func summaryDocument(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                if reduceMotion {
                    isSummaryCollapsed.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSummaryCollapsed.toggle()
                    }
                }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.accentText.color)

                    Text("Summary")
                        .uiFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.heading.color)

                    Spacer(minLength: 8)
                    Text("\(summary.split(whereSeparator: { $0.isWhitespace }).count.formatted()) words")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.trailing, 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                        .rotationEffect(.degrees(isSummaryCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSummaryCollapsed ? "Expand summary" : "Collapse summary")

            if !isSummaryCollapsed {
                MarkdownText(summary, readingFont: readingFont)
                    .font(readingFont)
                    .lineSpacing(additionalLineSpacing)
                    .textSelection(.enabled)
                    .foregroundStyle(palette.text.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .modifier(ViewerCard())
    }

    private var canSave: Bool {
        edit?.draft.isDirty == true && !isSaving && !isReadOnly
    }

    private var editingDocument: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accentText.color)
                Text("Summary")
                    .uiFont(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer(minLength: 8)
                Button("Cancel") { requestCancel() }
                    .keyboardShortcut(isCurrentTab ? KeyboardShortcut.cancelAction : nil)
                    .disabled(isSaving)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(isCurrentTab ? KeyboardShortcut("s", modifiers: .command) : nil)
                .disabled(!canSave)
            }
            .uiFont(.system(size: 12))
            .buttonStyle(ViewerCommandButtonStyle())

            if isReadOnly {
                Label("Reprocessing is in progress. Your draft is kept; editing is paused.", systemImage: "lock")
                    .uiFont(.callout)
                    .foregroundStyle(palette.secondary.color)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .uiFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            editorBody
        }
        .padding(24)
        .modifier(ViewerCard())
        .confirmationDialog("Discard changes to the summary?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { edit = nil }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    @ViewBuilder private var editorBody: some View {
        if let indexURL = MarkdownEditorResources.bundledIndexURL {
            MarkdownBlockEditor(
                indexURL: indexURL,
                initialMarkdown: edit?.draft.current ?? "",
                isReadOnly: isReadOnly || isSaving,
                isActive: isCurrentTab,
                theme: MarkdownEditorTheme(palette: palette, reading: reading, mode: mode),
                onMessage: handle,
                handle: editorHandle
            )
            .frame(height: max(editorHeight, 160))
            // The block handle sits in the card's padding; text lines up near the read view.
            .padding(.leading, -20)
            .accessibilityLabel("Summary editor")
        } else {
            // `swift run` without the app bundle: plain-text fallback.
            TextEditor(text: Binding(
                get: { edit?.draft.current ?? "" },
                set: { edit?.draft.apply(.changed(markdown: $0)) }
            ))
            .font(readingFont)
            .frame(minHeight: 220)
            .accessibilityLabel("Summary draft")
            .onAppear {
                if let current = edit?.draft.current { edit?.draft.apply(.loaded(markdown: current)) }
            }
        }
    }

    private func handle(_ message: MarkdownEditorMessage) {
        switch message {
        case .height(let height):
            editorHeight = height
        case .shortcut(.save):
            guard isCurrentTab else { return }
            Task { await save() }
        case .shortcut(.cancel):
            guard isCurrentTab else { return }
            requestCancel()
        case .loaded, .changed:
            edit?.draft.apply(message)
        case .ready:
            break
        }
    }

    private func save() async {
        guard !isSaving, !isReadOnly else { return }
        isSaving = true
        // The editor's `changed` is debounced; pull the live text so a fast save keeps it.
        if let markdown = await editorHandle.currentMarkdown() {
            edit?.draft.apply(.changed(markdown: markdown))
        }
        guard edit?.draft.isDirty == true else {
            isSaving = false
            return
        }
        _ = await onSaveEdit()
        isSaving = false
    }

    private func requestCancel() {
        guard !isSaving else { return }
        if edit?.draft.isDirty == true {
            confirmDiscard = true
        } else {
            edit = nil
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 13) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(palette.secondary.color)

            Text(isReadOnly ? "Summary unavailable during reprocessing" : (hasOtherAnalysis ? "No summary text" : "No analysis yet"))
                .uiFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)

            Text(unavailableDescription)
                .uiFont(.system(size: 13))
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if canGenerate && !isReadOnly {
                Button(action: onGenerate) {
                    Label("Generate summary, actions, and tags", systemImage: "sparkles")
                }
                .buttonStyle(ViewerBrandButtonStyle(height: 38))
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .modifier(ViewerCard())
    }

    private var unavailableDescription: String {
        if isReadOnly {
            return "The current results remain available in other tabs while reprocessing is pending."
        }
        if hasOtherAnalysis {
            return "This recording has other analysis, but no summary text was saved."
        }
        if canGenerate {
            return "Generate a summary and the other available analysis from this transcript."
        }
        return "A transcript is needed before analysis can be generated."
    }

    private var generatingState: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.regular)
                .tint(palette.primary.color)
            Text("Generating summary and analysis…")
                .uiFont(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondary.color)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .modifier(ViewerCard())
        .accessibilityElement(children: .combine)
    }
}
