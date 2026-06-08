import SwiftUI

struct TranscriptChatView: View {
    let chatService: TranscriptChatService

    @State private var inputText = ""

    private var sendEnabled: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !chatService.isStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            if chatService.messages.isEmpty {
                promptTemplates
            } else {
                messageList
                promptChipsRow
            }

            inputBar
        }
    }

    // MARK: - Prompt chips (shown above the input once a chat is underway)

    private var promptChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChatPromptTemplate.defaults) { template in
                    Button {
                        inputText = template.prompt
                        submitMessage()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: template.systemIcon)
                                .font(.caption2)
                            Text(template.title)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(
                            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(chatService.isStreaming)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    // MARK: - Prompt templates (shown when chat is empty)

    private var promptTemplates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat with this transcript")
                        .font(.title2.weight(.semibold))
                    Text("Ask a question, or pick one of the example prompts below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)

                inputField
                    .padding(.horizontal, 20)

                Text("EXAMPLE PROMPTS")
                    .font(.caption.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(ChatPromptTemplate.defaults) { template in
                        Button {
                            inputText = template.prompt
                            submitMessage()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: template.systemIcon)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(template.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chatService.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if chatService.isStreaming, let last = chatService.messages.last, last.role == .assistant && last.content.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .id("streaming-indicator")
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: chatService.messages.count) { _, _ in
                if let lastId = chatService.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatService.messages.last?.content) { _, _ in
                if let lastId = chatService.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input

    /// Large, bordered, obviously-clickable text field. Shared by the empty
    /// state and the persistent bottom bar.
    private var inputField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(.secondary)

            TextField("Ask anything about this transcript…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .onSubmit { submitMessage() }

            Button {
                submitMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(sendEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if !chatService.messages.isEmpty {
                Button {
                    chatService.clearMessages()
                } label: {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear chat")
            }

            inputField
        }
        .padding(14)
    }

    // MARK: - Helpers

    private func submitMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !chatService.isStreaming else { return }
        inputText = ""
        Task { await chatService.send(text) }
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var showReasoning = false

    /// Splits an assistant message into its `<think>…</think>` reasoning and the
    /// visible answer. Handles the still-streaming case where `</think>` hasn't
    /// arrived yet.
    private var parts: (reasoning: String?, answer: String) {
        let content = message.content
        guard message.role == .assistant,
              let open = content.range(of: "<think>") else {
            return (nil, content)
        }
        let before = String(content[content.startIndex..<open.lowerBound])
        let afterOpen = content[open.upperBound...]
        if let close = afterOpen.range(of: "</think>") {
            let reasoning = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
            let answer = before + String(afterOpen[close.upperBound...])
            return (trimmed(reasoning), answer.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            // Reasoning is still streaming; no answer text yet.
            return (trimmed(String(afterOpen)), before.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var body: some View {
        let parts = parts
        return HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                if let reasoning = parts.reasoning {
                    reasoningView(reasoning)
                }

                if !parts.answer.isEmpty || parts.reasoning == nil {
                    bubble(parts.answer.isEmpty ? " " : parts.answer)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.role == .user
                ? Color.accentColor.opacity(0.12)
                : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Reasoning")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
