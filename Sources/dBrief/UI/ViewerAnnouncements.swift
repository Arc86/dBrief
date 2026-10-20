import SwiftUI

/// Speaks the viewer's status changes that are otherwise only visual: a save error,
/// a finished copy or analysis, and the "Speaker names changed" offer.
struct ViewerAnnouncements: ViewModifier {
    let saveError: String?
    let copied: Bool
    let isGenerating: Bool
    let hasInsights: Bool
    let offerReanalysis: Bool
    let announcer: AccessibilityAnnouncer

    func body(content: Content) -> some View {
        content
            .onChange(of: saveError) { _, error in
                if let error { announcer.announce(error, priority: .high) }
            }
            .onChange(of: copied) { _, copied in
                if copied { announcer.announce(String(localized: "Copied")) }
            }
            .onChange(of: isGenerating) { wasGenerating, generating in
                if wasGenerating, !generating, hasInsights { announcer.announce(String(localized: "Analysis ready")) }
            }
            .onChange(of: offerReanalysis) { _, offered in
                if offered { announcer.announce(String(localized: "Speaker names changed. You can regenerate the analysis.")) }
            }
    }
}

extension View {
    /// Speaks `text` whenever it changes to a non-empty value: a status or error line
    /// that appears without moving focus.
    func announcing(_ text: String?, priority: AnnouncementPriority = .normal) -> some View {
        onChange(of: text) { _, text in
            if let text { AccessibilityAnnouncer.shared.announce(text, priority: priority) }
        }
    }
}

extension SpokenSummaryService.Phase {
    /// What VoiceOver says when the spoken summary moves on; one line per step, so
    /// download progress isn't read out.
    var announcement: String? {
        switch self {
        case .idle: nil
        case .rewriting: String(localized: "Writing the spoken summary")
        case .preparingVoice: String(localized: "Preparing the voice")
        case .synthesizing: String(localized: "Creating audio")
        case .ready: String(localized: "Spoken summary ready")
        case .failed(let message): String(localized: "Couldn't create the spoken summary. \(message)")
        }
    }

    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

/// What VoiceOver says when the assistant finishes: the error, or the first sentence
/// of the answer, so the user knows without leaving the question field.
enum ChatAnnouncement {
    static func finished(_ answer: String) -> (text: String, priority: AnnouncementPriority) {
        let plain = answer
            .replacingOccurrences(of: #"[*_#`>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.hasPrefix("Error:") { return (plain, .high) }
        guard !plain.isEmpty else { return (String(localized: "Answer ready"), .normal) }
        let sentence = firstSentence(plain)
        return (String(localized: "Answer ready. \(sentence)"), .normal)
    }

    static func firstSentence(_ text: String, limit: Int = 200) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<line.index(after: end.lowerBound)])
        }
        guard sentence.count > limit else { return sentence }
        return String(sentence.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
