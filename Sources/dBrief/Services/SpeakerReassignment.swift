import Foundation

enum ReassignScope { case theseSegments, allOfSpeaker }

enum SpeakerChoice: Equatable {
    case existing(speakerId: String)
    case new(name: String)
}

struct SpeakerCandidate: Identifiable, Equatable {
    enum Source: Equatable { case existingSpeaker, meeting, library }
    let id: String              // existing speakerId, or "name:"+normalized for a name-only entry
    let displayName: String
    let existingSpeakerId: String?
    let isCurrent: Bool
    let source: Source
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
        calendarAttendees: [String],
        knownPeople: [String] = []
    ) -> [SpeakerCandidate] {
        func label(for id: String) -> String {
            transcript.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
        }

        // Existing speakers in first-appearance order.
        var seenIds: [String] = []
        var seenIdSet = Set<String>()
        for seg in transcript.segments {
            if let id = seg.speakerId, seenIdSet.insert(id).inserted { seenIds.append(id) }
        }

        var result: [SpeakerCandidate] = seenIds.map { id in
            SpeakerCandidate(id: id, displayName: label(for: id),
                             existingSpeakerId: id, isCurrent: id == currentSpeakerId,
                             source: .existingSpeaker)
        }
        // Current speaker first.
        result.sort { ($0.isCurrent ? 0 : 1) < ($1.isCurrent ? 0 : 1) }

        // Name-only candidates: names not already an existing speaker's display name.
        // Sources, in priority order: typed participants + calendar attendees (`.meeting`),
        // then known people from the voice library (`.library`), de-duped by `takenNames`
        // so a library person already in the meeting stays in the meeting group only.
        var takenNames = Set(result.map { normalize($0.displayName) })
        let tagged: [(String, SpeakerCandidate.Source)] =
            (participants + calendarAttendees).map { ($0, .meeting) } +
            knownPeople.map { ($0, .library) }
        for (name, source) in tagged {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalize(trimmed)
            if takenNames.contains(key) { continue }
            takenNames.insert(key)
            result.append(SpeakerCandidate(id: "name:" + key, displayName: trimmed,
                                           existingSpeakerId: nil, isCurrent: false,
                                           source: source))
        }
        return result
    }

    /// Rename a speaker's display label, keeping its identity (`speakerId`) and all its
    /// segments. If `newName` (normalized) already belongs to a *different* speaker, the two
    /// **swap** display names — so no two speakers share a name and no speaker is ever lost
    /// (this is the fix for diarization mixing up who's who). No segment is moved.
    /// `personId`, when non-nil, links the renamed speaker to a voice-library
    /// person (set on the label). A no-op early-return is skipped when a
    /// `personId` is supplied so the link is still recorded even if the name
    /// didn't change.
    static func rename(_ transcript: RichTranscript, speakerId: String, to rawName: String, personId: String? = nil) -> RichTranscript {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return transcript }
        var out = transcript

        let currentName = displayName(in: out, id: speakerId)
        if normalize(currentName) == normalize(newName), personId == nil { return transcript }  // no change

        if let otherId = speakerOwning(name: newName, in: out, excluding: speakerId) {
            // Swap: the other speaker inherits this speaker's current name.
            setLabel(&out, id: otherId, name: currentName)
        }
        setLabel(&out, id: speakerId, name: newName)
        if let personId, let i = out.speakerLabels.firstIndex(where: { $0.id == speakerId }) {
            out.speakerLabels[i].personId = personId
        }
        return out
    }

    /// The effective display name of a speaker id: its label, or the raw id when unlabeled.
    private static func displayName(in transcript: RichTranscript, id: String) -> String {
        transcript.speakerLabels.first(where: { $0.id == id })?.displayName ?? id
    }

    /// A speaker id (present in segments or labels) other than `excluding` whose effective
    /// display name matches `name` (normalized), or nil.
    private static func speakerOwning(name: String, in transcript: RichTranscript, excluding: String) -> String? {
        let key = normalize(name)
        var ids: [String] = []
        var idSet = Set<String>()
        for seg in transcript.segments {
            if let id = seg.speakerId, idSet.insert(id).inserted { ids.append(id) }
        }
        for label in transcript.speakerLabels where idSet.insert(label.id).inserted { ids.append(label.id) }
        return ids.first { $0 != excluding && normalize(displayName(in: transcript, id: $0)) == key }
    }

    private static func setLabel(_ transcript: inout RichTranscript, id: String, name: String) {
        if let i = transcript.speakerLabels.firstIndex(where: { $0.id == id }) {
            transcript.speakerLabels[i].displayName = name
        } else {
            transcript.speakerLabels.append(SpeakerLabel(id: id, displayName: name))
        }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
