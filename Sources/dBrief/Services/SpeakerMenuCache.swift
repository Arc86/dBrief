import Foundation

/// What a speaker's rename/move menu offers. Identical for every turn of the
/// same speaker, so it is computed once per speaker instead of once per row.
struct SpeakerMenuData: Equatable {
    var meetingNames: [String]
    var libraryNames: [String]
    var others: [SpeakerMoveTarget]
    var segmentCount: Int
}

/// SwiftUI `Menu` builds its items eagerly, so building each row's menu scanned
/// the whole transcript (candidates + segment counts) once per row on every
/// render — rows × segments. This memoizes the result per speaker until the
/// transcript, participants, attendees or known people change.
@MainActor
final class SpeakerMenuCache {
    struct Inputs {
        /// Bumped whenever the transcript is replaced; avoids comparing it per row.
        var revision: Int
        var transcript: RichTranscript
        var participants: [String]
        var attendees: [String]
        var knownPeople: [String]
    }

    private struct Key: Equatable {
        var revision: Int
        var participants: [String]
        var attendees: [String]
        var knownPeople: [String]
    }

    private var key: Key?
    private var bySpeaker: [String: SpeakerMenuData] = [:]
    /// How many times data was actually computed (for tests).
    private(set) var computeCount = 0

    func data(for speakerId: String?, inputs: Inputs) -> SpeakerMenuData {
        let current = Key(revision: inputs.revision, participants: inputs.participants,
                          attendees: inputs.attendees, knownPeople: inputs.knownPeople)
        if key != current {
            key = current
            bySpeaker = [:]
        }
        let id = speakerId ?? ""
        if let cached = bySpeaker[id] { return cached }

        computeCount += 1
        let cands = SpeakerReassignment.candidates(
            in: inputs.transcript,
            currentSpeakerId: speakerId,
            participants: inputs.participants,
            calendarAttendees: inputs.attendees,
            knownPeople: inputs.knownPeople)
        let data = SpeakerMenuData(
            meetingNames: cands.filter { $0.source == .meeting }.map(\.displayName),
            libraryNames: cands.filter { $0.source == .library }.map(\.displayName),
            others: cands.compactMap { c -> SpeakerMoveTarget? in
                guard let sid = c.existingSpeakerId, !c.isCurrent else { return nil }
                return SpeakerMoveTarget(id: sid, displayName: c.displayName)
            },
            segmentCount: SpeakerReassignment.segmentCount(in: inputs.transcript, speakerId: speakerId))
        bySpeaker[id] = data
        return data
    }
}
