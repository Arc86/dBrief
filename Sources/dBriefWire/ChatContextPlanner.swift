import Foundation

public enum ChatContextPlanner {
    /// Complete question/answer pairs, oldest first, excluding the in-flight turn.
    public static func history(from messages: [(role: ChatTurnMessage.Role, content: String)]) -> [ChatTurnMessage] {
        var out: [ChatTurnMessage] = []
        var pendingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingQuestion = message.content
            case .assistant:
                guard let q = pendingQuestion, !message.content.isEmpty else { pendingQuestion = nil; continue }
                out += [.init(role: .user, content: q), .init(role: .assistant, content: message.content)]
                pendingQuestion = nil
            }
        }
        return out
    }
}
