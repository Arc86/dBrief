import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptChatView: View {
    @Bindable var chatService: TranscriptChatService
    /// Seeks the recording when a `[hh:mm:ss]` citation is clicked; nil when there
    /// is no audio to seek (citations then stay plain text).
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// People in this recording, for "What did … commit to?" prompts.
    var people: [String] = []
    var savedPrompts: [SavedChatPrompt] = []
    /// Saves a question as a reusable prompt; nil hides "Save as Prompt".
    var onSavePrompt: ((String) -> Void)? = nil
    /// Where an answer can be added; nil when the recording has no analysis yet.
    var answerDestinations: ChatAnswerDestinations? = nil

    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.uiTypography) private var typography
    @FocusState private var inputIsFocused: Bool
    @State private var scrollFollow = ChatScrollFollowController()
    @State private var isAwayFromLatest = false

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
            if !chatService.messages.isEmpty, !chatService.isStreaming {
                followUpRow
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.chatAnswerDestinations, answerDestinations)
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = ChatTimestampLink.seconds(from: url) else { return .systemAction }
            onSeek?(seconds)
            return .handled
        })
        .onExitCommand {
            chatService.stopGenerating()
            chatService.stopReading()
        }
        .onAppear {
            scrollFollow.onFollowChange = { [away = $isAwayFromLatest] follows in away.wrappedValue = !follows }
            inputIsFocused = true
        }
        .onDisappear { chatService.stopReading() }
    }

    // MARK: - Prompts

    private func ask(_ template: ChatPromptTemplate) {
        guard !chatService.isStreaming else { return }
        scrollFollow.resumeFollowing()
        Task { await chatService.send(template.prompt) }
    }

    /// Follow-up prompts under the conversation; one click asks.
    private var followUpRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(ChatPromptTemplate.followUps(after: chatService.messages, people: people,
                                                 saved: savedPrompts, limit: 4)) { template in
                Button { ask(template) } label: {
                    Text(template.title)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .background(Capsule().fill(palette.canvas.color))
                        .overlay(Capsule().strokeBorder(palette.divider.color, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(template.prompt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask anything about this recording")
                    .uiFont(.callout.weight(.semibold))
                    .foregroundStyle(palette.heading.color)
                Text("Answers cite timestamps you can click to jump to that moment.")
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ChatPromptTemplate.starters + ChatPromptTemplate.people(people, limit: 2)) { template in
                    StarterPromptRow(template: template) { ask(template) }
                }
                if !savedPrompts.isEmpty {
                    Text("Your prompts")
                        .uiFont(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    ForEach(ChatPromptTemplate.saved(savedPrompts)) { template in
                        StarterPromptRow(template: template) { ask(template) }
                    }
                }
            }
            .disabled(chatService.isStreaming)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Chat replies can be taller than the viewport. Use measured
                // row heights when restoring or scrolling to a reply, rather
                // than letting a lazy stack revise its off-screen estimates.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chatService.messages.enumerated()), id: \.element.id) { index, message in
                        // While a reply streams, only its bubble re-renders per
                        // token; render it as plain text then (skipping the block
                        // Markdown parse that would re-run over the whole growing
                        // reply each token — O(n^2)) and parse once when done.
                        MessageBubble(
                            message: message,
                            chatService: chatService,
                            chatFontSize: reading.chatFontSize,
                            isStreaming: chatService.isStreaming && message.id == chatService.messages.last?.id,
                            isLatest: message.id == chatService.messages.last?.id,
                            linksTimestamps: onSeek != nil,
                            onEditQuestion: { editQuestion($0) },
                            onAskAgain: { askAgain() },
                            onSavePrompt: onSavePrompt,
                            isSavedPrompt: savedPrompts.contains { $0.prompt == message.content }
                        )
                        // A question sits close to its answer; exchanges are set apart.
                        .padding(.top, index == 0 ? 0 : (message.role == .user ? 22 : 10))
                        .id(message.id)
                    }

                    if let last = chatService.messages.last, last.role == .assistant, !last.content.isEmpty {
                        if let footnote = chatService.scanFootnote, footnote.messageID == last.id {
                            Text(footnote.text)
                                .uiFont(.caption)
                                .foregroundStyle(palette.secondary.color)
                                .padding(.horizontal, 3)
                                .padding(.top, 8)
                        } else if chatService.coverage == .relevantParts || chatService.coverage == .recentPart
                                    || chatService.offerScan {
                            coverageFooter(after: last)
                                .padding(.top, 8)
                        }
                    }

                    if chatService.isStreaming, let last = chatService.messages.last, last.role == .assistant,
                       last.content.isEmpty || chatService.scanStatus != nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(chatService.scanStatus ?? chatService.indexingStatus ?? "Thinking…")
                                .uiFont(.caption)
                                .foregroundStyle(palette.secondary.color)
                        }
                        .padding(.horizontal, 3)
                        .padding(.top, 8)
                        .id("streaming-indicator")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .overlayScrollers()
                .background(ChatScrollFollowObserver(controller: scrollFollow))
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .bottom) {
                if isAwayFromLatest {
                    jumpToLatestButton {
                        scrollFollow.resumeFollowing()
                        if let lastId = chatService.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
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
            .onAppear {
                // A reopened conversation starts at its latest exchange.
                guard let lastId = chatService.messages.last?.id else { return }
                Task { @MainActor in proxy.scrollTo(lastId, anchor: .bottom) }
            }
            .onChange(of: chatService.isStreaming) { _, streaming in
                // The finished reply re-renders as Markdown (and gains its actions),
                // which changes its height after the last token scrolled it into view.
                guard !streaming, scrollFollow.shouldFollow, let lastId = chatService.messages.last?.id else { return }
                Task { @MainActor in proxy.scrollTo(lastId, anchor: .bottom) }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text.color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(palette.surface.color))
                .overlay(Circle().strokeBorder(palette.divider.color, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest message")
        .help("Jump to latest message")
    }

    /// Coverage note ("relevant parts" / "most recent part"), plus the opt-in exhaustive
    /// scan of the whole recording for the question that produced `answer` when the
    /// service offers it (a long-mode answer or an Apple overflow error).
    private func coverageFooter(after answer: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = coverageNote {
                Text(note)
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
            }
            if chatService.offerScan, !chatService.isStreaming, let question = question(answeredBy: answer) {
                Button {
                    scrollFollow.resumeFollowing()
                    Task { await chatService.scanWholeRecording(for: question) }
                } label: {
                    Label("Check the whole recording (\(chatService.scanEstimateLabel))", systemImage: "text.magnifyingglass")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.canvas.color))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.divider.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Ask this question of every part of the recording, so nothing is missed. Stop cancels it.")
            }
        }
        .padding(.horizontal, 3)
    }

    private var coverageNote: String? {
        switch chatService.coverage {
        case .relevantParts?: "Answered from the most relevant parts of this long recording."
        case .recentPart?: "Answered from the most recent part of this live recording."
        case .full?, nil: nil
        }
    }

    /// The user question directly before `answer`, if any.
    private func question(answeredBy answer: ChatMessage) -> String? {
        guard let idx = chatService.messages.lastIndex(where: { $0.id == answer.id }), idx > 0 else { return nil }
        let previous = chatService.messages[idx - 1]
        return previous.role == .user ? previous.content : nil
    }

    // MARK: - Input

    /// Persistent composer at the bottom of both empty and populated chats.
    private var inputField: some View {
        HStack(spacing: 10) {
            TextField(chatService.messages.isEmpty ? "Ask about this recording…" : "Ask a follow-up…",
                      text: $chatService.draftInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppFontStyle.system(size: CGFloat(reading.chatFontSize)).resolve(
                    using: AppTypographyPreferences(readingFont: typography.readingFont)))
                .lineSpacing(chatLineSpacing)
                .foregroundStyle(palette.text.color)
                .lineLimit(1...6)
                .accessibilityLabel("Ask about this recording")
                .onSubmit { submitMessage() }
                .focused($inputIsFocused)

            if !chatService.isStreaming {
                Button(action: startDictation) {
                    Image(systemName: "mic")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary.color)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask by voice")
                .help("Ask by voice (macOS Dictation)")
            }

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
            .help(chatService.isStreaming ? "Stop generating (Esc)" : "Send message (Return)")
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

    /// Starts macOS Dictation in the composer: on-device where available, in the
    /// system language, and macOS offers to turn it on when it is off.
    private func startDictation() {
        inputIsFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private func editQuestion(_ text: String) {
        chatService.draftInput = text
        inputIsFocused = true
    }

    private func askAgain() {
        scrollFollow.resumeFollowing()
        Task { await chatService.askAgain() }
    }
}

// MARK: - Starter prompt

private struct StarterPromptRow: View {
    let template: ChatPromptTemplate
    let action: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: template.systemIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
                    .frame(width: 18)
                Text(template.title)
                    .uiFont(.system(size: 13))
                    .foregroundStyle(palette.text.color)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? palette.canvas.color : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(template.prompt)
        .accessibilityLabel("Ask: \(template.title)")
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
    /// The newest message keeps its answer actions visible; older ones reveal them on hover.
    var isLatest: Bool = false
    var linksTimestamps: Bool = false
    var onEditQuestion: (String) -> Void = { _ in }
    var onAskAgain: () -> Void = {}
    var onSavePrompt: ((String) -> Void)? = nil
    var isSavedPrompt = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiTypography) private var typography
    @State private var showReasoning = false
    @State private var isHovered = false

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
                            .foregroundStyle(palette.heading.color)
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, 2)
                    .accessibilityElement(children: .combine)
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
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { contextMenuItems(answer: parts.answer) }
    }

    @ViewBuilder
    private func contextMenuItems(answer: String) -> some View {
        if message.role == .user {
            Button("Copy") { Task { _ = await chatService.copy(message.content) } }
            Button("Edit Question") { onEditQuestion(message.content) }
                .disabled(chatService.isStreaming)
            if let onSavePrompt {
                Divider()
                Button(isSavedPrompt ? "Saved as Prompt" : "Save as Prompt") { onSavePrompt(message.content) }
                    .disabled(isSavedPrompt)
            }
        } else if !isStreaming, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Copy") { Task { _ = await chatService.copyAnswer(message, format: .markdown) } }
            Button("Copy as Plain Text") { Task { _ = await chatService.copyAnswer(message, format: .plainText) } }
            Divider()
            Button(chatService.spokenMessageID == message.id && chatService.speechPlayer.isBusy
                   ? "Stop Reading" : "Read Aloud") {
                chatService.toggleReadAloud(message)
            }
            .disabled(message.speechText.isEmpty)
            if isLatest {
                Button("Ask Again") { onAskAgain() }
                    .disabled(chatService.questionToAskAgain == nil)
            }
        }
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
            // Not selectable, so right-click reaches Copy / Edit Question / Save as Prompt.
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Answers sit on the panel surface without a card, so the text carries the weight.
    private func assistantAnswer(_ text: String, showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            assistantBody(text)
            if showsActions {
                MessageActions(message: message, chatService: chatService,
                               isLatest: isLatest, isRevealed: isLatest || isHovered,
                               onAskAgain: onAskAgain)
            }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assistantBody(_ text: String) -> some View {
        bubbleContent(text)
            .font(chatFont)
            .foregroundStyle(palette.text.color)
            .tint(palette.accentText.color)
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
            MarkdownText(text, readingFont: chatFont, linksTimestamps: linksTimestamps)
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
                .foregroundStyle(palette.secondary.color)
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
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Icon actions under an answer. The latest answer always shows them; older answers
/// show them on hover or keyboard focus, and every action is also in the context menu.
private struct MessageActions: View {
    let message: ChatMessage
    let chatService: TranscriptChatService
    var isLatest: Bool = false
    var isRevealed: Bool = true
    var onAskAgain: () -> Void = {}
    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerMode) private var appearanceMode
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chatAnswerDestinations) private var destinations
    @FocusState private var focusedAction: Action?
    @State private var copyToken: UUID?
    @State private var proposedActionItems: [String]?
    @State private var addStatus: String?
    @State private var isAdding = false
    @State private var isExporting = false
    @State private var exportErrorMessage: String?

    private enum Action: Hashable { case copy, read, askAgain, share }

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

    private var isVisible: Bool {
        isRevealed || focusedAction != nil || isReading || copyToken != nil || proposedActionItems != nil
    }

    /// The question this answer replies to.
    private var question: String? {
        guard let index = chatService.messages.firstIndex(where: { $0.id == message.id }), index > 0,
              chatService.messages[index - 1].role == .user else { return nil }
        return chatService.messages[index - 1].content
    }

    private func addToSummary() {
        guard let destinations, !isAdding else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            let added = await destinations.addToSummary(message.displayParts.answer, question)
            addStatus = added ? "Added to the summary." : nil
        }
    }

    private func proposeActionItems() {
        guard let destinations else { return }
        let existing = Set(destinations.existingActionItems.map { $0.lowercased() })
        let items = ChatAnswerHarvest.actionItems(from: message.displayParts.answer,
                                                  knownOwners: destinations.knownOwners)
            .filter { !existing.contains($0.lowercased()) }
        if items.isEmpty {
            addStatus = "No new action items found in this answer."
        } else {
            proposedActionItems = items
        }
    }

    private func addActionItems(_ items: [String]) {
        guard let destinations, !isAdding else { return }
        proposedActionItems = nil
        isAdding = true
        Task {
            defer { isAdding = false }
            let added = await destinations.addActionItems(items)
            addStatus = added ? (items.count == 1 ? "Added 1 action item." : "Added \(items.count) action items.") : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                iconButton(copyToken == nil ? "doc.on.doc" : "checkmark",
                           help: "Copy this answer", label: copyToken == nil ? "Copy answer" : "Answer copied",
                           action: .copy) {
                    Task {
                        if await chatService.copyAnswer(message) { copyToken = UUID() }
                    }
                }

                iconButton(isReading ? "stop.fill" : "speaker.wave.2",
                           help: isReading ? "Stop reading (Esc)" : "Read using the voice selected in Settings → Spoken summary",
                           label: isReading ? "Stop reading answer" : "Read answer aloud",
                           action: .read) {
                    chatService.toggleReadAloud(message)
                }
                .disabled(message.speechText.isEmpty)

                if isLatest {
                    iconButton("arrow.clockwise", help: "Ask this question again", label: "Ask again",
                               action: .askAgain, perform: onAskAgain)
                        .disabled(chatService.questionToAskAgain == nil)
                }

                exportMenu
            }
            .opacity(isVisible ? 1 : 0)
            .popover(isPresented: Binding(get: { proposedActionItems != nil },
                                          set: { if !$0 { proposedActionItems = nil } }),
                     arrowEdge: .bottom) {
                if let proposedActionItems {
                    ActionItemPicker(items: proposedActionItems, onAdd: addActionItems,
                                     onCancel: { self.proposedActionItems = nil })
                }
            }

            if let addStatus {
                Label(addStatus, systemImage: "checkmark")
                    .uiFont(.caption)
                    .foregroundStyle(palette.secondary.color)
                    .padding(.leading, 6)
                    .task {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        self.addStatus = nil
                    }
            }

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
        .padding(.leading, -6) // optically align the first icon with the answer text
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

    private func iconButton(_ symbol: String, help: String, label: String, action: Action,
                            perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.typographyBorderless)
        .focused($focusedAction, equals: action)
        .help(help)
        .accessibilityLabel(label)
    }

    private func speechProgress(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title).uiFont(.caption).foregroundStyle(palette.secondary.color)
        }
        .padding(.leading, 6)
    }

    private var exportMenu: some View {
        Menu {
            if destinations != nil {
                Section("Add to this recording") {
                    Button {
                        addToSummary()
                    } label: {
                        Label("Add to Summary", systemImage: "text.badge.plus")
                    }
                    Button {
                        proposeActionItems()
                    } label: {
                        Label("Add as Action Items…", systemImage: "checklist")
                    }
                }
                .disabled(!isAnswerExportEnabled || isAdding)

                Divider()
            }

            Button {
                Task {
                    guard chatService.canExportAnswer(message),
                          await chatService.copyAnswer(message, format: .plainText) else { return }
                    copyToken = UUID()
                }
            } label: {
                Label("Copy as Plain Text", systemImage: "doc.plaintext")
            }
            .disabled(!isAnswerExportEnabled)

            Divider()

            Button {
                beginExport(format: .markdown)
            } label: {
                Label("Save as Markdown…", systemImage: "arrow.down.doc")
            }
            .disabled(!isAnswerExportEnabled)

            Button {
                beginExport(format: .plainText)
            } label: {
                Label("Save as Text…", systemImage: "arrow.down.doc")
            }
            .disabled(!isAnswerExportEnabled)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.typographyBorderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($focusedAction, equals: .share)
        .disabled(!isAnswerExportEnabled)
        .help("Add this answer to the recording, copy it, or save it")
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

// MARK: - Answer destinations

/// Where a chat answer can be added in the open recording.
struct ChatAnswerDestinations {
    /// Names an action-item owner can match (speakers, participants, attendees).
    var knownOwners: [String]
    var existingActionItems: [String]
    /// Appends the answer to the summary; false when the save failed (the viewer shows why).
    var addToSummary: @MainActor (_ answer: String, _ question: String?) async -> Bool
    var addActionItems: @MainActor (_ items: [String]) async -> Bool
}

extension EnvironmentValues {
    @Entry var chatAnswerDestinations: ChatAnswerDestinations? = nil
}

/// Pick which of an answer's items become action items.
private struct ActionItemPicker: View {
    let items: [String]
    let onAdd: ([String]) -> Void
    let onCancel: () -> Void
    @Environment(\.viewerPalette) private var palette
    @State private var selected: Set<String>

    init(items: [String], onAdd: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.items = items
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selected = State(initialValue: Set(items))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add action items")
                .uiFont(.headline)
                .foregroundStyle(palette.heading.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        let parsed = ActionItemParser.parse(item).first
                        Toggle(isOn: Binding(
                            get: { selected.contains(item) },
                            set: { if $0 { selected.insert(item) } else { selected.remove(item) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(parsed?.text ?? item)
                                    .foregroundStyle(palette.text.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let owner = parsed?.owner {
                                    Text(owner)
                                        .uiFont(.caption)
                                        .foregroundStyle(palette.secondary.color)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(selected.count == items.count ? "Select None" : "Select All") {
                    selected = selected.count == items.count ? [] : Set(items)
                }
                .buttonStyle(.settingsSecondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.settingsSecondary)
                Button(selected.count == 1 ? "Add 1 Item" : "Add \(selected.count) Items") {
                    onAdd(items.filter(selected.contains))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.settingsPrimary)
                .disabled(selected.isEmpty)
            }
        }
        .uiFont(.system(size: 13))
        .padding(14)
        .frame(width: 340)
        .background(palette.surface.color)
    }
}
