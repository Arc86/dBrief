import Foundation

/// Topology of the output actually produced by finalization. AAC/DSP time
/// alignment remains uncalibrated until the physical capture/playback gate.
struct RecordingPlaybackMapping: Codable, Sendable, Equatable {
    enum Method: String, Codable, Sendable { case rawTrackCopy, encodedAAC }
    let schemaVersion: Int
    let method: Method
    let sourceRoles: [AudioTrackWriter.Role]

    static func rawTrackCopy(_ role: AudioTrackWriter.Role) -> Self {
        .init(schemaVersion: 1, method: .rawTrackCopy, sourceRoles: [role])
    }
    static func encodedAAC(_ tracks: CapturedTracks) -> Self {
        .init(schemaVersion: 1, method: .encodedAAC,
              sourceRoles: [(tracks.systemURL != nil ? .system : nil), (tracks.micURL != nil ? .mic : nil)].compactMap { $0 })
    }
    func masterFrames(for role: AudioTrackWriter.Role, savedTrack: LiveAudioFrameRange) -> LiveAudioFrameRange? {
        guard schemaVersion == 1, method == .rawTrackCopy, sourceRoles == [role], savedTrack.isValid else { return nil }
        return savedTrack
    }
}
