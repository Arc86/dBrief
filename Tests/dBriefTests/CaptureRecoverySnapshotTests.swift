import Foundation
import Testing
@testable import dBrief

@Suite("Capture recovery snapshots")
struct CaptureRecoverySnapshotTests {
    @Test(arguments: [InterruptedSessionManifest.State.capturing, .paused, .finalizing])
    func snapshotKeepsOnlyImmediateSessionTracksWithoutReadingFiles(state: InterruptedSessionManifest.State) {
        let root = URL(fileURLWithPath: "/nonexistent-capture-snapshot/session")
        let manifestURL = root.appendingPathComponent("session.json")
        let id = UUID(), date = Date(timeIntervalSince1970: 100)
        let own = root.appendingPathComponent("microphone.caf")
        let foreign = root.deletingLastPathComponent().appendingPathComponent("other/system.caf")
        let manifest = InterruptedSessionManifest(captureID: id, startedAt: date, state: state,
            manifestURL: manifestURL, capturedTracks: .init(systemURL: foreign, micURL: own))
        #expect(manifest.id == id && manifest.startedAt == date && manifest.state == state)
        #expect(manifest.version == InterruptedSessionManifest.currentVersion)
        #expect(manifest.tracks == [.init(kind: .microphone, relativePath: "microphone.caf")])
        let nested = InterruptedSessionManifest(captureID: id, startedAt: date, state: state,
            manifestURL: manifestURL, capturedTracks: .init(systemURL: root.appendingPathComponent("nested/system.caf"), micURL: nil))
        #expect(nested.tracks.isEmpty)
    }

    @Test func finalizationSnapshotUsesFrozenRecordingInputsAndRequiresManifestURL() {
        let root = URL(fileURLWithPath: "/nonexistent-capture-snapshot/session")
        let id = UUID(), date = Date(timeIntervalSince1970: 100)
        var tracks = CapturedTracks(systemURL: root.appendingPathComponent("system.caf"), micURL: root.appendingPathComponent("mic.caf"))
        let snapshot = ProcessingPipeline.FinalizationRecovery.capture(id: id, startedAt: date,
            manifestURL: root.appendingPathComponent("session.json"), tracks: tracks)
        tracks = .init(systemURL: nil, micURL: nil)
        #expect(snapshot?.manifest.state == .finalizing)
        #expect(snapshot?.manifest.tracks.map(\.relativePath) == ["mic.caf", "system.caf"])
        #expect(ProcessingPipeline.FinalizationRecovery.capture(id: id, startedAt: date, manifestURL: nil, tracks: tracks) == nil)
    }
}
