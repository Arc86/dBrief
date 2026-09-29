import Foundation

struct ChatMessage: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date

    enum Role: String, Sendable, Codable {
        case user, assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// Share the same visible answer between rendering, copying and speech.
    var displayParts: (reasoning: String?, answer: String) {
        guard role == .assistant, content.contains("<think>") else {
            return (nil, content)
        }
        var cursor = content.startIndex
        var answer = ""
        var reasoningBlocks: [String] = []
        // Models can emit more than one reasoning block. Keep every block out
        // of the shared answer used by rendering, Copy, speech and file export.
        while let open = content.range(of: "<think>", range: cursor..<content.endIndex) {
            answer += content[cursor..<open.lowerBound]
            let close = content.range(of: "</think>", range: open.upperBound..<content.endIndex)
            let reasoning = content[open.upperBound..<(close?.lowerBound ?? content.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoning.isEmpty { reasoningBlocks.append(reasoning) }
            cursor = close?.upperBound ?? content.endIndex
        }
        answer += content[cursor...]
        return (reasoningBlocks.isEmpty ? nil : reasoningBlocks.joined(separator: "\n\n"),
                answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var speechText: String { SpokenSummaryScript.clean(displayParts.answer) }
}

struct ChatPromptTemplate: Identifiable, Sendable {
    let id: UUID
    let title: String
    let systemIcon: String
    let prompt: String

    init(title: String, systemIcon: String, prompt: String) {
        self.id = UUID()
        self.title = title
        self.systemIcon = systemIcon
        self.prompt = prompt
    }

    static let defaults: [ChatPromptTemplate] = [
        ChatPromptTemplate(title: "Bullet Points", systemIcon: "list.bullet",
            prompt: "Summarize this transcript as concise bullet points."),
        ChatPromptTemplate(title: "Action Items", systemIcon: "checkmark.circle",
            prompt: "Extract all action items and tasks mentioned in this transcript."),
        ChatPromptTemplate(title: "Key Points", systemIcon: "star",
            prompt: "Identify and explain the most important points from this transcript."),
        ChatPromptTemplate(title: "Questions Asked", systemIcon: "questionmark.circle",
            prompt: "Extract all questions asked during this conversation."),
        ChatPromptTemplate(title: "Improve Grammar", systemIcon: "text.badge.checkmark",
            prompt: "Rewrite this transcript with improved grammar, punctuation, and readability while maintaining the original meaning and speaking style."),
        ChatPromptTemplate(title: "Generate FAQ", systemIcon: "questionmark.folder",
            prompt: "Create a FAQ document based on the topics discussed in this transcript."),
        ChatPromptTemplate(title: "Extract Statistics", systemIcon: "number",
            prompt: "Extract all numbers, statistics, dates, and quantitative data mentioned."),
        ChatPromptTemplate(title: "Identify Emotions", systemIcon: "heart",
            prompt: "Analyze the emotional tone and sentiment throughout this transcript, noting any significant shifts."),
    ]
}
