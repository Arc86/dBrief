import Foundation

/// Incremental client-side bounds for backends that keep generating repetitive
/// output or ignore max_tokens. Counts text once, without rescanning the reply.
struct ChatResponseLimiter {
    enum StopReason: Equatable {
        case repetition
        case length

        var message: String {
            switch self {
            case .repetition: "Stopped because the response was repeating itself."
            case .length: "Stopped because the response reached the length limit."
            }
        }
    }

    private(set) var stopReason: StopReason?
    private var characterCount = 0
    private var pendingLine = ""
    private var previousLine = ""
    private var repetitions = 0

    mutating func append(_ chunk: String) -> String {
        guard stopReason == nil else { return "" }
        var accepted = ""
        for character in chunk {
            accepted.append(character)
            characterCount += 1
            if character.isNewline {
                let line = pendingLine.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingLine = ""
                if !line.isEmpty {
                    repetitions = line == previousLine ? repetitions + 1 : 1
                    previousLine = line
                    // Avoid treating separators, short table cells, or blank lines
                    // as a model loop. Eight identical substantive lines is enough.
                    if line.count >= 20, repetitions >= 8 {
                        stopReason = .repetition
                    }
                }
            } else {
                pendingLine.append(character)
            }
            if characterCount >= 65_536 { stopReason = stopReason ?? .length }
            if stopReason != nil { break }
        }
        return accepted
    }
}
