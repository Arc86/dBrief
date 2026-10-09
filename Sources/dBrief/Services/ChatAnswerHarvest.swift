import Foundation

/// Turns chat answers into recording content: action items, a summary section,
/// or the whole conversation as Markdown. Pure, so it is unit-tested without UI.
enum ChatAnswerHarvest {
    // MARK: Action items

    /// One action item per list line of `answer`. A label line that names known
    /// people ("Vera Elsen", "**Maarten + Jesper**") sets the owner of the items
    /// below it, written as `[Owner] task` so `ActionItemParser` groups them.
    static func actionItems(from answer: String, knownOwners: [String]) -> [String] {
        var owners: [String]?
        var items: [String] = []
        var seen = Set<String>()
        for raw in answer.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let body = listItemBody(line) {
                var text = clean(body)
                while text.hasSuffix(":") { text.removeLast() }
                text = text.trimmingCharacters(in: .whitespaces)
                guard text.count >= 3 else { continue }
                let item = owners.map { "[\($0.joined(separator: "/"))] \(text)" } ?? text
                if seen.insert(item.lowercased()).inserted { items.append(item) }
            } else {
                owners = matchOwners(clean(line), knownOwners: knownOwners)
            }
        }
        return items
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^(?:[-*+•]|\d+[.)])\s+"#)
    private static let headingMarker = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    private static let citation = try! NSRegularExpression(pattern: #"\s*\[[0-9:\s,;–—\-]+\](?:\s*/\s*\[[0-9:\s,;–—\-]+\])*"#)
    private static let parenthetical = try! NSRegularExpression(pattern: #"\s*\([^)]*\)"#)

    private static func listItemBody(_ line: String) -> String? {
        let ns = NSRange(line.startIndex..., in: line)
        guard let match = listMarker.firstMatch(in: line, range: ns),
              let range = Range(match.range, in: line) else { return nil }
        return String(line[range.upperBound...])
    }

    /// Plain text: no heading marks, emphasis, code ticks or timestamp citations.
    private static func clean(_ text: String) -> String {
        var result = replacing(headingMarker, in: text, with: "")
        result = replacing(citation, in: result, with: "")
        for mark in ["**", "__", "`"] { result = result.replacingOccurrences(of: mark, with: "") }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The known people a label line names, or nil when it names anyone else.
    private static func matchOwners(_ label: String, knownOwners: [String]) -> [String]? {
        var text = replacing(parenthetical, in: label, with: "").trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(":") { text.removeLast() }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "+&/,"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " en ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var owners: [String] = []
        for part in parts {
            guard let owner = knownOwner(part, in: knownOwners) else { return nil }
            if !owners.contains(owner) { owners.append(owner) }
        }
        return owners
    }

    private static func knownOwner(_ name: String, in known: [String]) -> String? {
        let key = name.lowercased()
        return known.first { $0.lowercased() == key }
            ?? known.first { $0.split(separator: " ").first?.lowercased() == key }
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Summary

    /// `summary` with the answer appended as its own `###` section, titled after the question.
    static func summary(_ summary: String, adding answer: String, question: String?) -> String {
        let section = "### \(sectionTitle(for: question))\n\n\(demotingHeadings(in: answer, to: 4))"
        let base = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? section : base + "\n\n" + section
    }

    /// A template's short title when the question is one, else the question shortened.
    static func sectionTitle(for question: String?) -> String {
        guard let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            return "From Ask dBrief"
        }
        if let template = ChatPromptTemplate.defaults.first(where: { $0.prompt == question }) {
            return template.title
        }
        return SavedChatPrompt.title(for: question, maxLength: 80)
    }

    /// Headings in an answer become at least `level` deep and `---` rules are dropped,
    /// so the answer can't end the `##` section it is placed in.
    static func demotingHeadings(in text: String, to level: Int) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 { return nil }
                let hashes = trimmed.prefix { $0 == "#" }.count
                guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return line }
                return String(repeating: "#", count: max(hashes, level)) + trimmed.dropFirst(hashes)
            }
            .joined(separator: "\n")
    }

    // MARK: Conversation

    /// Each exchange as `### question` followed by the answer. Unanswered questions,
    /// errors and reasoning are left out.
    static func conversationBody(_ messages: [ChatMessage]) -> String {
        var blocks: [String] = []
        var question: String?
        for message in messages {
            switch message.role {
            case .user:
                question = message.content
            case .assistant:
                let answer = message.displayParts.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let asked = question, !answer.isEmpty, !answer.hasPrefix("Error:") else { continue }
                let heading = asked.split(whereSeparator: \.isNewline).joined(separator: " ")
                blocks.append("### \(heading)\n\n\(demotingHeadings(in: answer, to: 4))")
                question = nil
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A standalone Markdown document of the conversation.
    static func conversationDocument(_ messages: [ChatMessage], title: String) -> String {
        "# Ask dBrief: \(title)\n\n" + conversationBody(messages) + "\n"
    }
}
