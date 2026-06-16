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
        guard let origin = out.segments.first(where: { segmentIds.contains($0.id) })?.speakerId
        else { return transcript }
        if origin == targetId { return transcript }

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
        if out.meSpeakerId == origin && !live.contains(origin) {
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
        // Implemented in Task 2.
        []
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
