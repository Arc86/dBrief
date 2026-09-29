import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptChatView: View {
    @Bindable var chatService: TranscriptChatService

    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.uiTypography) private var typography
    @FocusState private var inputIsFocused: Bool
    @State private var scrollFollow = ChatScrollFollowController()

    private var sendEnabled: Bool {
        !chatService.draftInput.trimmingCharacters(in: .whitespaces).isEmpty && !chatService.isStreaming
    }

    var body: some View {
        VStack(spacing: 15) {
            if chatService.messages.isEmpty && chatService.isLoadingHistory {
                // Hold the space while a saved conversation loads, rather than
                // flashing the empty-state prompt it is about to replace.
                Color.clear
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else if chatService.messages.isEmpty {
                emptyState
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else {
                messageList
                    .frame(minHeight: 0, maxHeight: .infinity)
            }
            if let notice = chatService.streamingNotice {
                Text(notice)
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            promptChipsRow
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            chatService.stopGenerating()
            chatService.stopReading()
        }
        .onDisappear { chatService.stopReading() }
    }

    // MARK: - Prompt chips

    private var promptChipsRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(suggestedPrompts) { template in
                Button {
                    chatService.draftInput = template.prompt
                    inputIsFocused = true
                } label: {
                    Text(template.title)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.canvas.color))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.divider.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(chatService.isStreaming)
                .help("Put this prompt in the composer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestedPrompts: [ChatPromptTemplate] {
        ["Action Items", "Key Points", "Questions Asked"].compactMap { title in
            ChatPromptTemplate.defaults.first(where: { $0.title == title })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ViewerSparkle(size: 24)
            Text("Ask a question about this transcript")
                .uiFont(.callout.weight(.medium))
                .foregroundStyle(palette.heading.color)
            Text("Choose a prompt below or type your own.")
                .uiFont(.caption)
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Chat replies can be taller than the viewport. Use measured
                // row heights when restoring or scrolling to a reply, rather
                // than letting a lazy stack revise its off-screen estimates.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chatService.messages) { message in
                        // While a reply streams, only its bubble re-renders per
                        // token; render it as plain text then (skipping the block
                        // Markdown parse that would re-run over the whole growing
                        // reply each token — O(n^2)) and parse once when done.
                        MessageBubble(
                            message: message,
                            chatService: chatService,
                            chatFontSize: reading.chatFontSize,
                            isStreaming: chatService.isStreaming && message.id == chatService.messages.last?.id
                        )
                        .id(message.id)
                    }

                    if chatService.isStreaming, let last = chatService.messages.last, last.role == .assistant && last.content.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking…")
                                .uiFont(.caption)
                                .foregroundStyle(palette.secondary.color)
                        }
                        .padding(.horizontal, 16)
                        .id("streaming-indicator")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .overlayScrollers()
                .background(ChatScrollFollowObserver(controller: scrollFollow))
            }
            .scrollIndicators(.automatic)
            .onChange(of: chatService.messages.count) { _, _ in
                if scrollFollow.shouldFollow, let lastId = chatService.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: chatService.messages.last?.content) { _, _ in
                if scrollFollow.shouldFollow, let lastId = chatService.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    // MARK: - Input

    /// Persistent composer at the bottom of both empty and populated chats.
    private var inputField: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up…", text: $chatService.draftInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppFontStyle.system(size: CGFloat(reading.chatFontSize)).resolve(
                    using: AppTypographyPreferences(readingFont: typography.readingFont)))
                .lineSpacing(chatLineSpacing)
                .foregroundStyle(palette.text.color)
                .lineLimit(1...6)
                .accessibilityLabel("Ask a follow-up")
                .onSubmit { submitMessage() }
                .focused($inputIsFocused)

            Button {
                if chatService.isStreaming {
                    chatService.stopGenerating()
                } else {
                    submitMessage()
                }
            } label: {
                Image(systemName: chatService.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle((sendEnabled || chatService.isStreaming) ? palette.onPrimary.color : palette.secondary.color)
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8).fill(
                            (sendEnabled || chatService.isStreaming)
                                ? AnyShapeStyle(palette.primary.color)
                                : AnyShapeStyle(palette.divider.color))
                    }
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled && !chatService.isStreaming)
            .accessibilityLabel(chatService.isStreaming ? "Stop generating" : "Send message")
            .help(chatService.isStreaming ? "Stop generating (Esc)" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.surface.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    inputIsFocused ? palette.accentText.color.opacity(0.88) : palette.divider.color,
                    lineWidth: inputIsFocused ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        inputField
    }

    private var chatLineSpacing: CGFloat {
        chatAdditionalLineSpacing(size: reading.chatFontSize, typography: typography)
    }

    // MARK: - Helpers

    private func submitMessage() {
        let text = chatService.draftInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !chatService.isStreaming else { return }
        scrollFollow.resumeFollowing()
        chatService.draftInput = ""
        Task { await chatService.send(text) }
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ChatMessage
    let chatService: TranscriptChatService
    let chatFontSize: Int
    /// True only for the assistant reply currently streaming — render plain
    /// text while true, then Markdown once the reply completes.
    var isStreaming: Bool = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiTypography) private var typography
    @State private var showReasoning = false

    var body: some View {
        let parts = message.displayParts
        return HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    HStack(spacing: 6) {
                        ViewerSparkle(size: 13)
                        Text("dBrief")
                            .uiFont(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accentText.color)
                    }
                    .padding(.bottom, 3)
                }

                if let reasoning = parts.reasoning {
                    reasoningView(reasoning)
                }

                if !parts.answer.isEmpty || parts.reasoning == nil {
                    if message.role == .user {
                        userBubble(parts.answer.isEmpty ? " " : parts.answer)
                    } else {
                        assistantAnswer(
                            parts.answer.isEmpty ? " " : parts.answer,
                            showsActions: !isStreaming && !parts.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }

        }
        .padding(.horizontal, 3)
    }

    private func userBubble(_ text: String) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14
        ))
        return bubbleContent(text)
            .font(chatFont)
            .lineSpacing(chatAdditionalLineSpacing(size: chatFontSize, typography: typography))
            .foregroundStyle(palette.onPrimary.color)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(palette.primary.color)
            .clipShape(shape)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantAnswer(_ text: String, showsActions: Bool) -> some View {
        let cardColour = palette.surface.mixed(with: palette.primary, fraction: 0.08).color

        return VStack(alignment: .leading, spacing: 10) {
            assistantBody(text)
            if showsActions {
                MessageActions(message: message, chatService: chatService)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardColour, in: RoundedRectangle(cornerRadius: palette.readingCardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: palette.readingCardCornerRadius)
                .strokeBorder(palette.divider.color.opacity(0.8), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assistantBody(_ text: String) -> some View {
        bubbleContent(text)
            .font(chatFont)
            .foregroundStyle(palette.text.color)
            .lineSpacing(chatAdditionalLineSpacing(size: chatFontSize, typography: typography))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The chat size slider sets point size; the app preference supplies only the family.
    private var chatFont: Font {
        AppFontStyle.system(size: CGFloat(chatFontSize)).resolve(
            using: AppTypographyPreferences(readingFont: typography.readingFont))
    }

    /// User messages stay plain; assistant messages render Markdown (headings,
    /// lists, bold) so the model's formatting isn't shown as raw syntax.
    @ViewBuilder
    private func bubbleContent(_ text: String) -> some View {
        if message.role == .assistant && !isStreaming {
            MarkdownText(text, readingFont: chatFont)
        } else {
            Text(text)
        }
    }

    private func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if reduceMotion {
                    showReasoning.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { showReasoning.toggle() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Reasoning")
                        .uiFont(.caption2.weight(.semibold))
                }
                .foregroundStyle(palette.accentText.color)
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(reasoning)
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.divider.color, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Kept below the answer so actions remain reachable without hovering.
private struct MessageActions: View {
    let message: ChatMessage
    let chatService: TranscriptChatService
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerMode) private var appearanceMode
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copyToken: UUID?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?

    private var speechState: VoicePreviewPlayer.State {
        chatService.spokenMessageID == message.id ? chatService.speechPlayer.state : .idle
    }

    private var isReading: Bool {
        switch speechState {
        case .preparingVoice, .synthesizing, .playing: true
        case .idle, .failed: false
        }
    }

    private var isAnswerExportEnabled: Bool {
        !isExporting && chatService.canExportAnswer(message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    answerActions
                    Spacer(minLength: 2)
                    exportMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    answerActions
                    exportMenu
                }
            }
            .buttonStyle(.typographyBorderless)
            .uiFont(.caption)

            switch speechState {
            case .preparingVoice(let progress):
                speechProgress(progress.map { "Preparing voice… \(Int($0 * 100))%" } ?? "Preparing voice…")
            case .synthesizing:
                speechProgress("Preparing audio…")
            case .failed(let message):
                Text("Could not read aloud: \(message)")
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .textSelection(.enabled)
            case .idle, .playing:
                EmptyView()
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .alert(
            "Couldn’t export answer",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "The answer is still available in this conversation.")
        }
        .task(id: copyToken) {
            guard copyToken != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copyToken = nil
        }
    }

    private func speechProgress(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title).uiFont(.caption).foregroundStyle(palette.secondary.color)
        }
    }

    private var answerActions: some View {
        HStack(spacing: 4) {
            Button {
                Task {
                    if await chatService.copyAnswer(message) {
                        copyToken = UUID()
                    }
                }
            } label: {
                Image(systemName: copyToken == nil ? "doc.on.doc" : "checkmark")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("Copy this answer to the clipboard")
            .accessibilityLabel(copyToken == nil ? "Copy answer" : "Answer copied")

            Button {
                chatService.toggleReadAloud(message)
            } label: {
                Image(systemName: isReading ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .disabled(message.speechText.isEmpty)
            .help(isReading ? "Stop reading (Esc)" : "Read using the voice selected in Settings → Spoken Summary")
            .accessibilityLabel(isReading ? "Stop reading answer" : "Read answer aloud")
            .foregroundStyle(palette.accentText.color)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var exportMenu: some View {
        Menu {
            Section("Share this answer") {
                Button {
                    Task {
                        guard chatService.canExportAnswer(message),
                              await chatService.copyAnswer(message) else { return }
                        copyToken = UUID()
                    }
                } label: {
                    Label("Copy answer", systemImage: "doc.on.doc")
                }
                .disabled(!isAnswerExportEnabled)
            }

            Divider()

            Button {
                beginExport(format: .markdown)
            } label: {
                Label("Download Markdown", systemImage: "arrow.down.doc")
            }
            .disabled(!isAnswerExportEnabled)

            Button {
                beginExport(format: .plainText)
            } label: {
                Label("Download text", systemImage: "arrow.down.doc")
            }
            .disabled(!isAnswerExportEnabled)
        } label: {
            Label("Share / Export", systemImage: "square.and.arrow.up")
                .uiFont(.system(size: 11))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(palette.text.color)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface.color))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.divider.color, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .controlSize(.small)
        .disabled(!isAnswerExportEnabled)
        .help("Copy or export this answer only")
        .accessibilityLabel("Share or export this answer")
    }

    @MainActor
    private func beginExport(format: ChatAnswerExportFormat) {
        guard isAnswerExportEnabled, chatService.canExportAnswer(message) else { return }

        let panel = NSSavePanel()
        let appearanceName: NSAppearance.Name = contrast == .increased
            ? (appearanceMode.isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (appearanceMode.isDark ? .darkAqua : .aqua)
        panel.appearance = NSAppearance(named: appearanceName)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        switch format {
        case .markdown:
            panel.title = "Export Answer as Markdown"
            panel.allowedContentTypes = [
                UTType(filenameExtension: "md")
                    ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
            ]
            panel.nameFieldStringValue = "dBrief-answer.md"
        case .plainText:
            panel.title = "Export Answer as Text"
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "dBrief-answer.txt"
        }

        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            let response = await panel.begin()
            guard response == .OK, let destination = panel.url,
                  chatService.canExportAnswer(message) else { return }

            do {
                try await chatService.exportAnswer(message, format: format, to: destination)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

/// Account for the family's natural metrics, including OpenDyslexic's taller lines.
@MainActor
private func chatAdditionalLineSpacing(size: Int, typography: AppTypographyPreferences) -> CGFloat {
    let font = AppFontStyle.system(size: CGFloat(size)).nsFont(
        using: AppTypographyPreferences(readingFont: typography.readingFont))
    let naturalLineHeight = max(0, font.ascender - font.descender + font.leading)
    return max(0, CGFloat(size) * 1.5 - naturalLineHeight)
}
