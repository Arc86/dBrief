import SwiftUI

struct TranscriptChatView: View {
    @State var chatService: TranscriptChatService

    @State private var inputText = ""
    @State private var scrollToBottom = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if chatService.messages.isEmpty {
                promptTemplates
            } else {
                messageList
            }

            inputBar
        }
    }

    // MARK: - Prompt templates (shown when chat is empty)

    private var promptTemplates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Prominent input at top
                HStack(spacing: 8) {
                    Text("✦")
                        .font(.system(size: 13))
                        .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                    TextField("Ask anything about this transcript…", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .lineLimit(1...4)
                        .onSubmit { submitMessage() }
                    Button { submitMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? TranscriptDesignTokens.secondaryText(scheme: colorScheme)
                                    : Color.accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                            .fill(TranscriptDesignTokens.cardFill(scheme: colorScheme))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TranscriptDesignTokens.cardCornerRadius)
                        .stroke(TranscriptDesignTokens.cardBorder(scheme: colorScheme), lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.top, 14)

                // Section label
                Text("QUICK TEMPLATES")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(TranscriptDesignTokens.sectionLabel(scheme: colorScheme))
                    .padding(.horizontal, 14)
                    .padding(.top, 4)

                // Chip grid
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(ChatPromptTemplate.defaults) { template in
                        Button {
                            inputText = template.prompt
                            submitMessage()
                        } label: {
                            Text(template.title)
                                .font(.system(size: 11))
                                .foregroundStyle(TranscriptDesignTokens.bodyText(scheme: colorScheme))
                                .padding(.vertical, 5)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule()
                                        .fill(TranscriptDesignTokens.chipFill(scheme: colorScheme))
                                        .background(.ultraThinMaterial, in: Capsule())
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(TranscriptDesignTokens.chipBorder(scheme: colorScheme), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
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

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            if !chatService.messages.isEmpty {
                Button {
                    chatService.clearMessages()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(TranscriptDesignTokens.secondaryText(scheme: colorScheme))
                }
                .buttonStyle(.borderless)
                .help("Clear chat")
            }

            TextField("Ask about this transcript…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .onSubmit { submitMessage() }

            Button {
                submitMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatService.isStreaming
                            ? TranscriptDesignTokens.secondaryText(scheme: colorScheme)
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || chatService.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            TranscriptDesignTokens.structureFill(scheme: colorScheme)
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TranscriptDesignTokens.structureBorder(scheme: colorScheme))
                .frame(height: 1)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                Text(message.content.isEmpty ? " " : message.content)
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

            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }
}
