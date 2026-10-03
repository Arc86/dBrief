import Foundation
import Testing
import dBriefWire
@testable import dBrief

extension LiveArtifactDurabilityTests {
@Suite("Live checkpoint recovery proof")
struct LiveArtifactCheckpointValidationTests {
    @Test(arguments: ["restart-gap", "preparation-gap", "historical-preparation-gap"])
    func recoveryCannotHideAQualifiedClockGap(kind: String) async throws {
        let f = LiveTranscriptFixture(), store = LiveTranscriptStore(identity: f.identity)
        if kind == "restart-gap" {
            let original = f.epoch()
            #expect(await store.beginEpoch(owner: f.identity, epoch: original) == .accepted)
            #expect(await store.admit(f.event(original, 0, f.progress(1))) == .accepted)
            #expect(await store.admit(f.event(original, 1, .committed(f.segment(original, 0, 0, 1)))) == .accepted)
        }
        let aligned = f.epoch(origin: 3_000_000_000)
        #expect(await store.beginEpoch(owner: f.identity, epoch: aligned) == .accepted)
        if kind == "restart-gap" {
            #expect(await store.admit(f.event(aligned, 0, f.progress(1))) == .accepted)
            #expect(await store.admit(f.event(aligned, 1, .committed(f.segment(aligned, 0, 0, 1)))) == .accepted)
        } else if kind == "historical-preparation-gap" {
            #expect(await store.beginEpoch(owner: f.identity, epoch: f.epoch(origin: nil)) == .accepted)
        }
        let checkpoint = await store.checkpoint()
        try checkpoint.validate()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        let coverage = try #require(object["coverage"] as? [[String: Any]])
        object["coverage"] = coverage.filter { $0["epochID"] != nil }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let decoded = try JSONDecoder().decode(LiveTranscriptCheckpoint.self, from: bytes)
        #expect(throws: LiveTranscriptCheckpoint.Failure.invalidCheckpoint) { try decoded.validate() }
        let disk = try LiveArtifactFixture(); defer { disk.remove() }
        let session = disk.root.appendingPathComponent(f.identity.captureSessionID.uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let url = session.appendingPathComponent("live-transcript.json")
        try bytes.write(to: url)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: disk.root)
        await #expect(throws: LiveTranscriptCheckpoint.Failure.invalidCheckpoint) { _ = try await writer.recover() }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: ["missing-coverage", "repeated-coverage", "hole", "overlap", "settled-frontier",
                      "asr-frontier", "high-cutoff", "low-cutoff", "missing-cutoff", "missing-lane"])
    func validJSONCannotInventSettledEvidence(kind: String) async throws {
        let f = LiveTranscriptFixture(), epoch = f.epoch(), store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: epoch) == .accepted)
        #expect(await store.admit(f.event(epoch, 0, f.progress(3))) == .accepted)
        #expect(await store.admit(f.event(epoch, 1, .committed(f.segment(epoch, 0, 0, 1)))) == .accepted)
        #expect(await store.admit(f.event(epoch, 2, .committed(f.segment(epoch, 1, 1, 2)))) == .accepted)
        let checkpoint = await store.checkpoint()
        try checkpoint.validate() // An open checkpoint may have an unsettled captured suffix.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        var coverage = try #require(object["coverage"] as? [[String: Any]])
        var lanes = try #require(object["lanes"] as? [[String: Any]])
        switch kind {
        case "missing-coverage": object["coverage"] = []
        case "repeated-coverage": coverage.append(coverage[0]); object["coverage"] = coverage
        case "hole":
            coverage.removeFirst(); object["coverage"] = coverage
            var segments = try #require(object["segments"] as? [[String: Any]])
            segments.removeFirst(); object["segments"] = segments
        case "overlap":
            let overlap = LiveCoverageInterval(epochID: epoch.id, source: epoch.source, range: f.range(epoch, 0, 1), kind: .processedSilence)
            coverage.insert(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(overlap)) as? [String: Any]), at: 1)
            object["coverage"] = coverage
        case "settled-frontier":
            lanes[0]["settledSampleEnd"] = 48_000; lanes[0]["settledMeetingNanoseconds"] = 3_000_000_000
            object["lanes"] = lanes; object["cutoffNanoseconds"] = 3_000_000_000
        case "asr-frontier":
            var progress = try #require(lanes[0]["progress"] as? [String: Any])
            progress["consumedSampleEnd"] = 16_000; progress["asrConsumedSampleEnd"] = 16_000
            lanes[0]["progress"] = progress; object["lanes"] = lanes
        case "high-cutoff": object["cutoffNanoseconds"] = 3_000_000_000
        case "low-cutoff": object["cutoffNanoseconds"] = 1_000_000_000
        case "missing-cutoff": object.removeValue(forKey: "cutoffNanoseconds")
        default: object["lanes"] = []
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let decoded = try JSONDecoder().decode(LiveTranscriptCheckpoint.self, from: bytes)
        #expect(throws: LiveTranscriptCheckpoint.Failure.invalidCheckpoint) { try decoded.validate() }
        #expect(throws: LiveTranscriptCheckpoint.Failure.invalidCheckpoint) { _ = try LiveTranscriptStore(restoring: decoded) }
        let disk = try LiveArtifactFixture(); defer { disk.remove() }
        let session = disk.root.appendingPathComponent(f.identity.captureSessionID.uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let url = session.appendingPathComponent("live-transcript.json")
        try bytes.write(to: url)
        let writer = LiveSessionArtifactStore(identity: f.identity, rootURL: disk.root)
        await #expect(throws: LiveTranscriptCheckpoint.Failure.invalidCheckpoint) { _ = try await writer.recover() }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func restartClockGapsAndUnconsumedLossRemainRecoverable() async throws {
        let f = LiveTranscriptFixture(), aligned = f.epoch(), unaligned = f.epoch(origin: nil), restarted = f.epoch(origin: 3_000_000_000)
        let store = LiveTranscriptStore(identity: f.identity)
        #expect(await store.beginEpoch(owner: f.identity, epoch: aligned) == .accepted)
        #expect(await store.admit(f.event(aligned, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(aligned, 1, .committed(f.segment(aligned, 0, 0, 1)))) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: unaligned) == .accepted)
        #expect(await store.admit(f.event(unaligned, 0, f.progress(1))) == .accepted)
        #expect(await store.admit(f.event(unaligned, 1, .committed(f.segment(unaligned, 0, 0, 1)))) == .accepted)
        #expect(await store.beginEpoch(owner: f.identity, epoch: restarted) == .accepted)
        #expect(await store.admit(f.event(restarted, 0, f.progress(2, consumed: 1))) == .accepted)
        #expect(await store.admit(f.event(restarted, 1, .committed(f.segment(restarted, 0, 0, 1)))) == .accepted)
        #expect(await store.admit(f.event(restarted, 2, f.settlement(restarted, 1, 2, .gap(.overload)))) == .accepted)
        #expect(await store.admit(f.event(restarted, 3, .availability(.unavailable))) == .accepted)
        let checkpoint = try JSONDecoder().decode(LiveTranscriptCheckpoint.self, from: JSONEncoder().encode(await store.checkpoint()))
        try checkpoint.validate()
        let restored = try LiveTranscriptStore(restoring: checkpoint)
        #expect(await restored.snapshot() == store.snapshot())
        #expect(await restored.projection().segments.count == 3)
    }
}
}
