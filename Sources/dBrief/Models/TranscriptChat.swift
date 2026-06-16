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
