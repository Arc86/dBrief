import Foundation
import dBriefWire
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class TranscriptChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamingError: String? = nil

    /// Provides the transcript text at send-time. A closure (rather than a stored
    /// string) so the chat can read a *live, growing* transcript during recording —
    /// each `send()` rebuilds the prompt from the current snapshot. Mutable so a live
    /// chat can be re-pointed at the authoritative transcript when recording finishes
    /// (see `rebindTranscript`).
    private var transcriptProvider: @MainActor () -> String
    private var speakerLabels: [SpeakerLabel]
    private let appSettings: AppSettings
    private let localPlugin: LocalAIPluginService?
    private let aiService = AIService()

    init(
        transcriptProvider: @escaping @MainActor () -> String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?
    ) {
        self.transcriptProvider = transcriptProvider
        self.speakerLabels = speakerLabels
        self.appSettings = appSettings
        self.localPlugin = localPlugin
    }

    /// Convenience init for a fixed (completed-recording) transcript.
    convenience init(
        transcriptText: String,
        speakerLabels: [SpeakerLabel],
        appSettings: AppSettings,
        localPlugin: LocalAIPluginService?
    ) {
        self.init(
            transcriptProvider: { transcriptText },
            speakerLabels: speakerLabels,
            appSettings: appSettings,
            localPlugin: localPlugin
        )
    }

    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))

        var assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIdx = messages.count - 1

        isStreaming = true
        streamingError = nil

        let systemPrompt = buildSystemPrompt()
        let fullUserMessage = buildContextualUserMessage(currentMessage: trimmed)

        do {
            let stream = await buildStream(systemPrompt: systemPrompt, userMessage: fullUserMessage)
            for try await chunk in stream {
                assistantMessage.content += chunk
                messages[assistantIdx] = assistantMessage
            }
        } catch {
            streamingError = error.localizedDescription
            messages[assistantIdx].content = "Error: \(error.localizedDescription)"
        }

        isStreaming = false
    }

    func clearMessages() {
        messages = []
        streamingError = nil
    }

    /// Re-point this chat at a fixed transcript while keeping the conversation so far.
    /// Used when a live recording finishes: the in-memory live preview is gone, so the
    /// chat switches to the authoritative on-disk transcript, but the live Q&A history
    /// is preserved (those earlier answers were grounded in the rough live preview).
    func rebindTranscript(text: String, speakerLabels: [SpeakerLabel]) {
        transcriptProvider = { text }
        self.speakerLabels = speakerLabels
    }

    /// True once the conversation has at least one exchange — used to decide whether a
    /// finished recording should preserve and reopen the carried-over live chat.
    var hasHistory: Bool { !messages.isEmpty }

    /// Warms the on-device model when the chat panel opens so the first answer streams
    /// sooner. No-op unless Apple Intelligence is the active (or fallback) chat engine.
    func prewarm() {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine
        guard engine == .appleIntelligence else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    // MARK: - Private

    private func buildStream(systemPrompt: String, userMessage: String) async -> AsyncThrowingStream<String, Error> {
        // The Local CLI is one-shot and can't stream chat, so route to the
        // user-selected fallback engine instead.
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine

        switch engine {

        case .localCLI:
            return errorStream("Local CLI does not support chat. Choose a chat fallback engine in Settings → AI & Models.")

        case .qwenLocal:
            guard let plugin = localPlugin else {
                return errorStream("Local AI plugin not available")
            }
            return await plugin.chatStream(systemPrompt: systemPrompt, userMessage: userMessage)

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            let session = LanguageModelSession(instructions: systemPrompt)
                            let options = GenerationOptions(temperature: 0.5)
                            let response = try await session.respond(to: userMessage, options: options)
                            continuation.yield(response.content)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            #endif
            return errorStream("Apple Intelligence requires macOS 26 or later")

        case .remoteEndpoint:
            guard let endpoint = appSettings.effectiveDefaultAIEndpoint else {
                return errorStream("No AI endpoint configured. Add one in Settings → AI.")
            }
            return aiService.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, endpoint: endpoint)
        }
    }

    private func errorStream(_ message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(
                domain: "TranscriptChatService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    private func buildSystemPrompt() -> String {
        let engine = appSettings.effectiveAIEngine == .localCLI
            ? appSettings.chatFallbackEngine
            : appSettings.effectiveAIEngine
        // Apple Intelligence (FoundationModels) has a ~4096-token context window — a full
        // transcript in the instructions overflows it and chat errors out immediately.
        // Truncate for that engine; Gemma (128K) and remote endpoints keep the full text.
        let transcriptText = transcriptProvider()
        let transcript = engine == .appleIntelligence
            ? UnifiedInsightsPrompt.truncateForFoundationModels(transcriptText)
            : transcriptText

        var prompt = "You are an intelligent assistant helping analyze a meeting transcript.\n\n"
        prompt += "TRANSCRIPT:\n\(transcript)\n"
        if !speakerLabels.isEmpty {
            prompt += "\nSPEAKER LEGEND:\n"
            for label in speakerLabels {
                prompt += "- \(label.id): \(label.displayName)\n"
            }
        }
        prompt += "\nAnswer the user's questions concisely. When asked to format or transform the transcript, do so directly without preamble."
        return prompt
    }

    private func buildContextualUserMessage(currentMessage: String) -> String {
        let history = messages.dropLast()  // exclude the assistant placeholder we just added
        guard !history.isEmpty else { return currentMessage }

        // Include conversation history as plain text for backends that are single-turn
        var context = "Previous conversation:\n"
        for msg in history {
            let prefix = msg.role == .user ? "User: " : "Assistant: "
            context += "\(prefix)\(msg.content)\n\n"
        }
        return "\(context)Current question: \(currentMessage)"
    }
}
