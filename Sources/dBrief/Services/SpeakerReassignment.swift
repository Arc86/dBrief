import Foundation

enum ReassignScope { case theseSegments, allOfSpeaker }

enum SpeakerChoice: Equatable {
    case existing(speakerId: String)
    case new(name: String)
}

struct SpeakerCandidate: Identifiable, Equatable {
    let id: String              // existing speakerId, or "name:"+normalized for a name-only entry
    let displayName: String
    let existingSpeakerId: String?
    let isCurrent: Bool
}

enum SpeakerReassignment {

    static func segmentCount(in transcript: RichTranscript, speakerId: String?) -> Int {
        guard let speakerId else { return 0 }
        return transcript.segments.reduce(0) { $0 + ($1.speakerId == speakerId ? 1 : 0) }
    }

    static func apply(
        _ choice: SpeakerChoice,
        to transcript: RichTranscript,
        segmentIds: Set<UUID>,
        scope: ReassignScope,
        newId: String
    ) -> RichTranscript {
        var out = transcript

        // 1. Resolve target id (and append a label for a genuinely new name).
        let targetId: String
        switch choice {
        case .existing(let id):
            targetId = id
        case .new(let rawName):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return transcript }
            if let match = out.speakerLabels.first(where: { normalize($0.displayName) == normalize(name) }) {
                targetId = match.id
            } else {
                targetId = newId
                out.speakerLabels.append(SpeakerLabel(id: newId, displayName: name))
            }
        }

        // 2. Origin speaker = speakerId of the first targeted segment (a turn shares one).
        // `origin` may be nil (an undiarized segment) — that is a valid reassignment,
        // so only abort when no targeted segment exists at all.
        guard let originSegment = out.segments.first(where: { segmentIds.contains($0.id) })
        else { return transcript }
        let origin = originSegment.speakerId
        if origin == targetId { return transcript }   // targetId is non-nil; nil origin proceeds

        // 3. Rewrite.
        for i in out.segments.indices {
            switch scope {
            case .theseSegments:
                if segmentIds.contains(out.segments[i].id) { out.segments[i].speakerId = targetId }
            case .allOfSpeaker:
                if out.segments[i].speakerId == origin { out.segments[i].speakerId = targetId }
            }
        }

        // 4. Orphan-label cleanup (never drop the target's label).
        let live = Set(out.segments.compactMap { $0.speakerId })
        out.speakerLabels.removeAll { $0.id != targetId && !live.contains($0.id) }

        // 5. meSpeakerId transfer if the origin was "me" and is now gone.
        if let origin, out.meSpeakerId == origin, !live.contains(origin) {
            out.meSpeakerId = targetId
        }

        return out
    }

    static func candidates(
        in transcript: RichTranscript,
        currentSpeakerId: String?,
        participants: [String],
        calendarAttendees: [String]
    ) -> [SpeakerCandidate] {
        func label(for id: String) -> String {
            transcript.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
        }

        // Existing speakers in first-appearance order.
        var seenIds: [String] = []
        for seg in transcript.segments {
            if let id = seg.speakerId, !seenIds.contains(id) { seenIds.append(id) }
        }

        var result: [SpeakerCandidate] = seenIds.map { id in
            SpeakerCandidate(id: id, displayName: label(for: id),
                             existingSpeakerId: id, isCurrent: id == currentSpeakerId)
        }
        // Current speaker first.
        result.sort { ($0.isCurrent ? 0 : 1) < ($1.isCurrent ? 0 : 1) }

        // Name-only candidates: names not already an existing speaker's display name.
        var takenNames = Set(result.map { normalize($0.displayName) })
        for name in participants + calendarAttendees {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalize(trimmed)
            if takenNames.contains(key) { continue }
            takenNames.insert(key)
            result.append(SpeakerCandidate(id: "name:" + key, displayName: trimmed,
                                           existingSpeakerId: nil, isCurrent: false))
        }
        return result
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
