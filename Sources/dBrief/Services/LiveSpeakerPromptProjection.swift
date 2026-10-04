import Foundation
import dBriefWire

/// Projects admitted word indices onto exact original bytes. Decoder timing is
/// never used as acoustic alignment, and concurrent tracks do not own the text.
enum LiveSpeakerPromptProjection {
    static let maximumWords = 512
    static let maximumSpans = 1_025
    private static let maximumTextBytes = 65_536

    static func key(_ track: SpeakerTrackKey) -> String {
        "\(track.source.rawValue):\(track.contextID.uuidString.lowercased()):\(track.slot)"
    }

    static func unavailable(_ text: String) -> [ChatSpeakerAttributionSpan] {
        text.isEmpty ? [] : [.init(startUTF8: 0, endUTF8: text.utf8.count, status: .unavailable, speakers: [])]
    }

    static func captured(_ segment: CommittedLiveSegment, annotations: [LiveSpeakerAnnotation],
                         identity: LiveSessionIdentity) -> [ChatSpeakerAttributionSpan]? {
        guard !annotations.isEmpty else { return nil }
        guard segment.isValid, segment.source.isCaptureSource, segment.words.count <= maximumWords,
              annotations.count <= maximumWords + 1 else { return unavailable(segment.text) }
        var words: [Int: LiveSpeakerAnnotation] = [:]
        var whole: LiveSpeakerAnnotation?
        for annotation in annotations {
            guard annotation.segmentID == segment.id,
                  LiveTranscriptCheckpoint.validAnnotation(annotation, segment: segment, identity: identity) else {
                return unavailable(segment.text)
            }
            if let word = annotation.wordIndex {
                guard words.updateValue(annotation, forKey: word) == nil else { return unavailable(segment.text) }
            } else {
                guard whole == nil else { return unavailable(segment.text) }
                whole = annotation
            }
        }
        if segment.words.isEmpty {
            let fact = assignment(whole)
            return [.init(startUTF8: 0, endUTF8: segment.text.utf8.count, status: fact.status, speakers: fact.speakers)]
        }
        let bytes = Array(segment.text.utf8)
        var cursor = segment.text.startIndex, offset = 0
        var spans: [ChatSpeakerAttributionSpan] = []
        for (index, word) in segment.words.enumerated() {
            let start = offset
            while cursor < segment.text.endIndex, segment.text[cursor].isWhitespace {
                offset += segment.text[cursor].utf8.count
                cursor = segment.text.index(after: cursor)
            }
            append(.init(startUTF8: start, endUTF8: offset, status: .unknown, speakers: []), to: &spans)
            let wordBytes = Array(word.text.utf8)
            guard !wordBytes.isEmpty, wordBytes.count <= bytes.count - offset,
                  bytes[offset..<(offset + wordBytes.count)].elementsEqual(wordBytes) else { return unavailable(segment.text) }
            let end = offset + wordBytes.count
            let byteEnd = segment.text.utf8.index(segment.text.utf8.startIndex, offsetBy: end)
            guard let next = String.Index(byteEnd, within: segment.text) else { return unavailable(segment.text) }
            let fact = assignment(words[index])
            append(.init(startUTF8: offset, endUTF8: end, status: fact.status, speakers: fact.speakers), to: &spans)
            cursor = next; offset = end
        }
        append(.init(startUTF8: offset, endUTF8: bytes.count, status: .unknown, speakers: []), to: &spans)
        return normalized(spans, text: segment.text, source: segment.source.rawValue)
    }

    /// Direct immutable callers must provide a complete, disjoint partition at
    /// character boundaries with bounded, source-scoped speaker identifiers.
    static func normalized(_ spans: [ChatSpeakerAttributionSpan], text: String, source: String) -> [ChatSpeakerAttributionSpan] {
        guard !spans.isEmpty, spans.count <= maximumSpans, text.utf8.count <= maximumTextBytes else { return unavailable(text) }
        var boundaries: Set<Int> = [0], count = 0
        for character in text { count += character.utf8.count; boundaries.insert(count) }
        var cursor = 0, result: [ChatSpeakerAttributionSpan] = [], context: UUID?
        for span in spans {
            guard span.startUTF8 == cursor, span.endUTF8 > cursor, span.endUTF8 <= count,
                  boundaries.contains(span.startUTF8), boundaries.contains(span.endUTF8),
                  span.speakers.count <= 8, Set(span.speakers).count == span.speakers.count else { return unavailable(text) }
            switch span.status {
            case .resolved: guard span.speakers.count == 1 else { return unavailable(text) }
            case .overlap: guard (2...8).contains(span.speakers.count) else { return unavailable(text) }
            case .unknown, .unavailable: guard span.speakers.isEmpty else { return unavailable(text) }
            }
            for speaker in span.speakers {
                guard speaker.utf8.count <= 96 else { return unavailable(text) }
                let parts = speaker.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == source, source == "microphone" || source == "system",
                      let id = UUID(uuidString: String(parts[1])), let slot = Int(parts[2]), (0..<8).contains(slot),
                      speaker == "\(source):\(id.uuidString.lowercased()):\(slot)" else { return unavailable(text) }
                if let context, context != id { return unavailable(text) }
                context = id
            }
            append(span, to: &result); cursor = span.endUTF8
        }
        return cursor == count ? result : unavailable(text)
    }

    /// Ranges remain relative to the unchanged original prefix. An incomplete
    /// word/activity span supplies no speaker identity.
    static func prefix(_ spans: [ChatSpeakerAttributionSpan], endUTF8: Int) -> [ChatSpeakerAttributionSpan] {
        var result: [ChatSpeakerAttributionSpan] = []
        for span in spans {
            guard span.startUTF8 < endUTF8 else { break }
            if span.endUTF8 <= endUTF8 { append(span, to: &result) }
            else {
                append(.init(startUTF8: span.startUTF8, endUTF8: endUTF8, status: .unknown, speakers: []), to: &result)
                break
            }
        }
        return result
    }

    private static func assignment(_ annotation: LiveSpeakerAnnotation?) -> (status: LiveAttributionCoverage.Status, speakers: [String]) {
        guard let annotation else { return (.unknown, []) }
        switch annotation.assignment {
        case .unknown: return (.unknown, [])
        case .track(let track): return (.resolved, [key(track)])
        case .overlap(let tracks): return (.overlap, tracks.map(key).sorted())
        }
    }

    private static func append(_ span: ChatSpeakerAttributionSpan, to spans: inout [ChatSpeakerAttributionSpan]) {
        guard span.endUTF8 > span.startUTF8 else { return }
        if let last = spans.last, last.endUTF8 == span.startUTF8, last.status == span.status, last.speakers == span.speakers {
            spans[spans.count - 1] = .init(startUTF8: last.startUTF8, endUTF8: span.endUTF8, status: last.status, speakers: last.speakers)
        } else { spans.append(span) }
    }
}
