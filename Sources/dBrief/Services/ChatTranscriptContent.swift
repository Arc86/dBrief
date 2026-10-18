import Foundation
import dBriefWire

/// What a finished recording's chat reads: speaker-attributed turns (the long-mode
/// retrieval source), their `[hh:mm:ss] Name:` text, and the speaker labels for the
/// legend. The single builder for both a new chat session and every rebind after the
/// transcript changes (rename, moved turns, speaker review, live → finished).
struct ChatTranscriptContent: Equatable {
    let turns: [TranscriptTurn]
    let text: String
    let speakerLabels: [SpeakerLabel]

    /// `fallbackText` is used when there are no segments to build turns from.
    static func make(richTranscript: RichTranscript?, fallbackText: String) -> ChatTranscriptContent {
        let labels = richTranscript?.speakerLabels ?? []
        let names = ChatTranscript.speakerNames(labels.map { (id: $0.id, displayName: $0.displayName) })
        let turns = ChatTranscript.turns((richTranscript?.segments ?? []).map {
            (start: $0.start, end: $0.end, speaker: $0.speakerId.map { names[$0] ?? $0 }, text: $0.text)
        })
        let text = turns.isEmpty ? fallbackText : ChatTranscript.format(turns)
        return ChatTranscriptContent(turns: turns, text: text, speakerLabels: labels)
    }

    /// The speaker legend as the model sees it; voice-library links don't matter.
    static func legendKey(_ labels: [SpeakerLabel]) -> [String] {
        labels.map { $0.id + "\u{1F}" + $0.displayName }
    }
}
