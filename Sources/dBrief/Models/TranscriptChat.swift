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

    static let summarize = ChatPromptTemplate(title: "Summarize", systemIcon: "list.bullet",
        prompt: "Summarize this recording as concise bullet points.")
    static let actionItems = ChatPromptTemplate(title: "Action items", systemIcon: "checkmark.circle",
        prompt: "Extract all action items and tasks mentioned in this transcript, with who owns each one.")
    static let decisions = ChatPromptTemplate(title: "Decisions", systemIcon: "checkmark.seal",
        prompt: "List the decisions that were made, and who made them.")
    static let questions = ChatPromptTemplate(title: "Questions asked", systemIcon: "questionmark.circle",
        prompt: "Extract all questions asked during this conversation, and whether each was answered.")
    static let keyPoints = ChatPromptTemplate(title: "Key points", systemIcon: "star",
        prompt: "Identify and explain the most important points from this transcript.")
    static let numbers = ChatPromptTemplate(title: "Numbers & dates", systemIcon: "number",
        prompt: "Extract all numbers, statistics, dates, and deadlines mentioned.")
    static let openIssues = ChatPromptTemplate(title: "Open issues", systemIcon: "exclamationmark.bubble",
        prompt: "What was left unresolved or needs a follow-up?")

    /// Shown in an empty chat.
    static let starters: [ChatPromptTemplate] = [summarize, actionItems, decisions, questions]

    /// Offered under the conversation, minus the ones already asked.
    static let defaults: [ChatPromptTemplate] = starters + [keyPoints, openIssues, numbers]

    /// One prompt per person: what they committed to. Titles use the first name.
    static func people(_ names: [String], limit: Int = 3) -> [ChatPromptTemplate] {
        names.prefix(limit).map { name in
            let first = name.split(separator: " ").first.map(String.init) ?? name
            return ChatPromptTemplate(title: "What did \(first) commit to?", systemIcon: "person",
                                      prompt: "What did \(name) commit to or agree to do?")
        }
    }

    static func saved(_ prompts: [SavedChatPrompt]) -> [ChatPromptTemplate] {
        prompts.map { ChatPromptTemplate(title: $0.title, systemIcon: "bookmark", prompt: $0.prompt) }
    }

    /// Up to `limit` follow-ups not already asked in `messages`: the user's saved
    /// prompts first (at most two), then one about a person, then the built-in ones.
    static func followUps(after messages: [ChatMessage], people: [String] = [], saved: [SavedChatPrompt] = [],
                          limit: Int = 3) -> [ChatPromptTemplate] {
        let asked = Set(messages.filter { $0.role == .user }.map(\.content))
        func open(_ templates: [ChatPromptTemplate]) -> [ChatPromptTemplate] {
            templates.filter { !asked.contains($0.prompt) }
        }
        let ordered = open(Self.saved(saved)).prefix(2) + open(Self.people(people)).prefix(1) + open(defaults)
        return Array(ordered.prefix(limit))
    }
}

/// A question the user saved as a reusable chat prompt (Settings → AI analysis).
struct SavedChatPrompt: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var prompt: String

    init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }

    /// A saved prompt for `question`, titled with its first few words.
    init(question: String) {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(title: Self.title(for: prompt), prompt: prompt)
    }

    static func title(for prompt: String, maxLength: Int = 28) -> String {
        let collapsed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        var title = ""
        for word in collapsed.split(separator: " ") {
            if title.count + word.count + 1 > maxLength { break }
            title += title.isEmpty ? String(word) : " \(word)"
        }
        return (title.isEmpty ? String(collapsed.prefix(maxLength)) : title) + "…"
    }
}
