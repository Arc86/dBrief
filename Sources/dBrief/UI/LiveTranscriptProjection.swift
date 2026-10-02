import dBriefWire

/// Immutable display value. Faster committed lanes and ephemeral partials can
/// appear here without entering a chat snapshot ahead of its shared cutoff.
struct LiveTranscriptProjection: Sendable, Equatable {
    let segments: [CommittedLiveSegment]
    let partials: [LivePartial]
    let lanes: [LiveLaneWatermarks]
    let revision: UInt64
    let isClosed: Bool
}
