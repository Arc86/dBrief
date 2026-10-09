import SwiftUI

/// The finished-recording assistant chrome, shared by the live app and native
/// whole-workspace checks. Chat state remains with TranscriptChatService.
struct ViewerAssistantPanel<Content: View>: View {
    var onDevice: Bool = false
    var onClose: () -> Void
    var onClearChat: (() -> Void)? = nil
    var clearChatDisabled: Bool = false
    var conversation: ChatConversationActions? = nil
    var chatFontSize: Binding<Int> = .constant(ViewerAppearancePreferences.defaultChatFontSize)
    @ViewBuilder var content: () -> Content
    @Environment(\.viewerPalette) private var palette
    @State private var showChatTextSize = false

    var body: some View {
        VStack(spacing: 12) {
            // Keeps the panel's top level with the document title.
            Color.clear.frame(height: 38)

            VStack(spacing: 15) {
                HStack(spacing: 8) {
                    ViewerSparkle(size: 20).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ask dBrief AI")
                            .uiFont(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        Text(onDevice ? "This recording · On-device" : "This recording")
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.secondary.color)
                    }
                    Spacer(minLength: 0)
                    Button { showChatTextSize.toggle() } label: {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(palette.secondary.color)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat text size")
                    .accessibilityValue("\(chatFontSize.wrappedValue) points")
                    .help("Chat text size")
                    .popover(isPresented: $showChatTextSize) {
                        ViewerPopoverContent {
                            ViewerChatTextSizeOptions(chatFontSize: chatFontSize)
                        }
                    }
                    if onClearChat != nil || conversation != nil {
                        Menu {
                            if let conversation {
                                Button("Copy Conversation", action: conversation.copy)
                                    .disabled(conversation.isEmpty)
                                Button("Save Conversation as Markdown…", action: conversation.save)
                                    .disabled(conversation.isEmpty)
                                if let addToNote = conversation.addToNote {
                                    Button("Add Conversation to Recording Note", action: addToNote)
                                        .disabled(conversation.isEmpty)
                                }
                            }
                            if let onClearChat {
                                if conversation != nil { Divider() }
                                Button("Clear Chat", action: onClearChat)
                                    .disabled(clearChatDisabled)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(palette.secondary.color)
                                .frame(width: 24, height: 28)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.typographyBorderless)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Conversation options")
                        .help("Conversation options")
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondary.color)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide assistant")
                    .help("Hide assistant")
                }
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) {
                    palette.divider.color.frame(height: 1)
                }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(17)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface.color, in: RoundedRectangle(cornerRadius: palette.readingCardCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: palette.readingCardCornerRadius).strokeBorder(palette.divider.color, lineWidth: 1))
        }
    }
}

private struct ViewerChatTextSizeOptions: View {
    let chatFontSize: Binding<Int>
    @Environment(\.viewerPalette) private var palette

    private var pointSize: Binding<Double> {
        Binding(
            get: { Double(chatFontSize.wrappedValue) },
            set: { chatFontSize.wrappedValue = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat text size")
                .uiFont(.headline)
                .foregroundStyle(palette.heading.color)

            HStack {
                Text("Text size")
                Spacer()
                Text("\(chatFontSize.wrappedValue) pt")
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary.color)
                    .accessibilityLabel("\(chatFontSize.wrappedValue) points")
            }

            Slider(value: pointSize, in: 12...24, step: 1)
                .tint(palette.primary.color)
                .accessibilityLabel("Chat text size")
                .accessibilityValue("\(chatFontSize.wrappedValue) points")
        }
        .uiFont(.system(size: 13))
        .foregroundStyle(palette.text.color)
        .padding(14)
        .frame(width: 230, alignment: .leading)
        .background(palette.surface.color)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Whole-conversation commands in the assistant panel's "…" menu.
struct ChatConversationActions {
    var isEmpty: Bool
    var copy: () -> Void
    var save: () -> Void
    /// Nil when the recording has no Markdown note to add to.
    var addToNote: (() -> Void)?
}
