import Foundation

enum ChatAnswerExportFormat: Sendable {
    case markdown
    case plainText
}

/// Formats one assistant message's visible answer for sharing or saving.
enum ChatAnswerExport {
    static func payload(for message: ChatMessage, format: ChatAnswerExportFormat) -> String {
        guard message.role == .assistant else { return "" }

        let answer = message.displayParts.answer
        switch format {
        case .markdown:
            return answer
        case .plainText:
            return SpokenSummaryScript.clean(answer)
        }
    }

    /// Writes a complete UTF-8 payload atomically; callers own destination choice
    /// and surface any filesystem error without discarding the answer.
    static func write(_ payload: String, to destination: URL) throws {
        try payload.write(to: destination, atomically: true, encoding: .utf8)
    }
}
