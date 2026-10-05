import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor @Suite struct LiveRAMMetadataTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    private func rich(_ text: String) -> RichTranscript {
        .init(segments: [.init(start: 0, end: 1, text: text, originalText: text)])
    }

    @Test func captureValidationUsesOnlyFiniteTimeAndBoundedLocalLexicalPaths() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: f.root)
        #expect(capture.startedAt == date(10) && capture.intendedFolder == f.root)
        #expect(try LiveRAMCaptureMetadata(startedAt: date(-10)).intendedFolder == nil)
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: LiveArtifactError.corruptArtifact) { _ = try LiveRAMCaptureMetadata(startedAt: date(value)) }
        }
        let invalid = [
            URL(string: "https://example.invalid/folder")!,
            URL(string: "file://remote/private/tmp/folder")!,
            URL(string: "file:///private/tmp/a/../b")!,
            URL(string: "file:///private/tmp/folder?x=1")!,
            URL(string: "file:///private/tmp/folder#x")!,
            URL(fileURLWithPath: "/" + String(repeating: "x", count: 4_097))
        ]
        for folder in invalid {
            #expect(throws: LiveArtifactError.unsafePath) { _ = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: folder) }
        }
    }

    @Test func registrationKeepsExactCaptureAndNeverQualifiesAnArtifactOrLink() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.session, withIntermediateDirectories: true)
        let sentinel = f.session.appendingPathComponent("live-transcript.json"), bytes = Data("Opaque unrelated evidence".utf8)
        try bytes.write(to: sentinel)
        let link = f.root.appendingPathComponent("intended-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.session)
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: link)
        let calls = RAMMetadataCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) })
        let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture)
        let charge = registry.reservedPayloadBytes
        #expect(entry.artifacts.ramMetadata?.capture == capture)
        #expect(try registry.registerLegacy(f.identity, capturePersistenceAllowed: false) === entry)
        #expect(try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture) === entry)
        for changed in [try LiveRAMCaptureMetadata(startedAt: date(11), intendedFolder: link),
                        try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: f.root)] {
            #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) {
                _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: changed)
            }
        }
        let other = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        #expect(throws: LiveRecordingSessionRegistry.Failure.identityConflict) { _ = try registry.registerLegacy(other, ramCapture: capture) }
        #expect(registry.entry(recordingID: other.recordingID) == nil && !registry.owns(recordingID: other.recordingID))
        #expect(registry.reservedPayloadBytes == charge && calls.values.isEmpty)
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == f.session.path)
    }

    @Test func defaultCaptureIsFiniteAndDurableOwnersNeverSampleTheRAMClock() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let clock = RAMMetadataClock(date(.nan))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ramFinalClock: { clock.sample() })
        let before = Date.now
        let ram = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        let after = Date.now, capture = try #require(ram.artifacts.ramMetadata?.capture)
        #expect(capture.startedAt >= before && capture.startedAt <= after && capture.startedAt.timeIntervalSinceReferenceDate.isFinite)
        #expect(capture.intendedFolder == nil && ram.artifacts.ramMetadata?.lastFinalAcceptedAt == nil)
        let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let durable = try registry.registerLegacy(identity)
        try registry.captureDidClose(identity)
        try durable.artifacts.publishFinal(.init(text: "Ordinary final"))
        try durable.artifacts.publishSavedFinal(rich("Ordinary saved final"))
        #expect(durable.artifacts.ramMetadata == nil && clock.reads == 0)
    }

    @Test func onlyActuallyAcceptedChangedFinalFactsSampleAndAdvanceAge() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let clock = RAMMetadataClock(date(100)), calls = RAMMetadataCalls()
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: f.root)
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) }, ramFinalClock: { clock.sample() })
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture).artifacts
        try owner.appendLegacy([.init(start: 0, end: 1, text: "Captured prefix")]); try registry.captureDidClose(f.identity)
        let prefix = try owner.legacyContext()
        try owner.retry(); try await owner.flush()
        #expect(clock.reads == 0 && owner.ramMetadata?.lastFinalAcceptedAt == nil)
        try owner.publishFinal(.init(text: "Accepted raw final"))
        #expect(clock.reads == 1 && owner.ramMetadata?.lastFinalAcceptedAt == date(100))
        let raw = try #require(try owner.finalContext()), rawRevision = owner.acceptedRevision
        clock.value = date(150)
        try owner.publishFinal(.init(text: "Ignored later raw final"))
        #expect(clock.reads == 1 && owner.acceptedRevision == rawRevision && owner.ramMetadata?.lastFinalAcceptedAt == date(100))
        let saved = rich("Accepted rich final")
        try owner.publishSavedFinal(saved)
        #expect(clock.reads == 2 && owner.ramMetadata?.lastFinalAcceptedAt == date(150))
        let richValue = try #require(try owner.finalContext()), richRevision = owner.acceptedRevision
        clock.value = date(200)
        try owner.publishSavedFinal(saved); _ = try owner.finalContext(); _ = try owner.legacyContext()
        try owner.retry(); try await owner.flush()
        #expect(clock.reads == 2 && owner.acceptedRevision == richRevision && owner.ramMetadata?.lastFinalAcceptedAt == date(150))
        #expect(throws: LiveArtifactError.artifactTooLarge) { try owner.publishSavedFinal(rich(String(repeating: "x", count: 100_000))) }
        #expect(clock.reads == 2 && owner.acceptedRevision == richRevision && owner.ramMetadata?.lastFinalAcceptedAt == date(150))
        clock.value = date(.nan)
        #expect(throws: LiveArtifactError.corruptArtifact) { try owner.publishSavedFinal(rich("Invalid clock candidate")) }
        #expect(clock.reads == 3 && owner.acceptedRevision == richRevision && owner.ramMetadata?.lastFinalAcceptedAt == date(150))
        #expect(try owner.finalContext() == richValue)
        #expect(raw.segments.first?.text == "Accepted raw final" && prefix.segments.first?.text == "Captured prefix")
        clock.value = date(250); try owner.publishSavedFinal(rich("Accepted later final"))
        #expect(clock.reads == 4 && owner.ramMetadata?.lastFinalAcceptedAt == date(250))
        #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
    }

    @Test func rollbackCannotMakeAcceptedFinalYoungerThanItsPreviousTimeOrCapture() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let clock = RAMMetadataClock(date(5))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ramFinalClock: { clock.sample() })
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10))
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture).artifacts
        try registry.captureDidClose(f.identity); try owner.publishFinal(.init(text: "Raw"))
        #expect(owner.ramMetadata?.lastFinalAcceptedAt == date(10))
        clock.value = date(20); try owner.publishSavedFinal(rich("Rich one"))
        clock.value = date(15); try owner.publishSavedFinal(rich("Rich two"))
        #expect(owner.ramMetadata?.lastFinalAcceptedAt == date(20) && clock.reads == 3)
        #expect(owner.ramMetadata?.isOlder(than: date(20)) == false)
        #expect(owner.ramMetadata?.isOlder(than: date(21)) == true)
    }

    @Test func residentHintsReflectOriginalMetadataAndChargeEveryFolderAlongsideAudio() throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let folder = f.root.appendingPathComponent("frozen-intended", isDirectory: true)
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: folder)
        let clock = RAMMetadataClock(date(30))
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, ramFinalClock: { clock.sample() })
        let owner = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture).artifacts
        let before = try #require(registry.retentionHints.first)
        #expect(before.ram?.capture == capture && before.ram?.lastFinalAcceptedAt == nil && !before.capturePersistenceAllowed)
        #expect(before.charge == 256 + 128 + folder.absoluteString.utf8.count * 6)
        try registry.captureDidClose(f.identity); try owner.bind(to: f.audio); try owner.publishFinal(.init(text: "Final"))
        let after = try #require(registry.retentionHints.first)
        #expect(after.identity == f.identity && after.audioURL == f.audio && !after.deleted)
        #expect(after.ram == owner.ramMetadata && after.ram?.lastFinalAcceptedAt == date(30) && after.ram?.sourceRetired == false)
        #expect(after.charge == before.charge + f.audio.absoluteString.utf8.count * 6)
        #expect(before.ram?.lastFinalAcceptedAt == nil && before.audioURL == nil)
        #expect(registry.reservedPayloadBytes == LiveManagedArtifactCatalogue.metadataBytes + LiveRecordingArtifactOwner.reservationBytes)
        #expect(!FileManager.default.fileExists(atPath: f.session.path))
    }

    @Test func contentFreeAgeAndRetiredMetadataKeepTheExactCaptureWithoutDiskPolicy() throws {
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: URL(fileURLWithPath: "/private/tmp/frozen"))
        let empty = LiveRAMSourceMetadata(capture: capture)
        #expect(!empty.isOlder(than: date(10)) && empty.isOlder(than: date(11)))
        #expect(!empty.isOlder(than: date(.nan)) && !empty.isOlder(than: date(.infinity)))
        let final = try empty.acceptingFinal(at: date(20)), retired = final.retiringSource()
        #expect(retired.sourceRetired && retired.capture == capture && retired.lastFinalAcceptedAt == date(20))
        #expect(!retired.isOlder(than: date(20)) && retired.isOlder(than: date(21)))
        #expect(!empty.sourceRetired && empty.lastFinalAcceptedAt == nil && !final.sourceRetired)
        #expect(throws: LiveArtifactError.corruptArtifact) { _ = try final.acceptingFinal(at: date(.infinity)) }
        let identity = LiveSessionIdentity(recordingID: UUID(), captureSessionID: UUID())
        let hint = LiveManagedArtifactCatalogue.Hint(identity: identity, audioURL: nil, deleted: false, ram: retired)
        #expect(!hint.capturePersistenceAllowed && !hint.deleted && hint.ram == retired)
        #expect(hint.charge <= LiveManagedArtifactCatalogue.hintByteLimit)
        #expect(LiveManagedArtifactCatalogue.Hint(identity: identity, audioURL: nil, deleted: false).capturePersistenceAllowed)
    }

    @Test func heldFailedPrivateReplacementKeepsCaptureAndResourcesUntilActualReturn() async throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: f.root.appendingPathComponent("original-folder", isDirectory: true))
        let clock = RAMMetadataClock(date(100)), probe = RAMMetadataProbe(), calls = RAMMetadataCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) }, ramFinalClock: { clock.sample() })
        var original: LiveRecordingSessionRegistry.Entry? = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture)
        try registry.captureDidClose(f.identity); try original?.artifacts.bind(to: f.audio)
        try original?.artifacts.publishFinal(.init(text: "Original final"))
        var old: TranscriptContextSnapshot? = try original?.artifacts.finalContext()
        let oldValidity = try #require(original?.validity)
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        try registry.adoptReplacement(phase, attemptID: UUID()); original = nil
        let gate = LiveArtifactGate(stage: .ownerHydration)
        let canonical = f.audio.deletingPathExtension().appendingPathExtension("transcript.json")
        let resultStore = ReprocessingStore(root: f.root.appendingPathComponent("Reprocessing"))
        try JSONEncoder().encode(TranscriptionResult(text: "Failed private final")).write(to: canonical)
        clock.value = date(200)
        registry.onHydration = { [weak registry] entry in
            guard let registry else { throw CancellationError() }
            do {
                let inspection = try registry.reserveReprocessingInspection()
                defer { withExtendedLifetime(inspection) {} }
                let current = try #require(try await resultStore.managedFinal(audioURL: f.audio, identity: f.identity, nonpersistingReplacement: true))
                try await entry.artifacts.reconcileFinal(current)
            }
            let value = try #require(try entry.artifacts.finalContext())
            defer { withExtendedLifetime(value) {} }
            probe.entry = entry; probe.validity = entry.validity; probe.value = value
            probe.metadata = entry.artifacts.ramMetadata
            try await gate.enter(.ownerHydration)
            try value.contextOwnership?.requireValid()
            probe.returned = true
            throw LiveArtifactFixtureFailure.injected
        }
        var operation: Task<LiveRecordingSessionRegistry.Entry?, Error>? = Task { try await registry.finishReplacement(phase) }
        do {
            try await gate.waitForArrival(); operation?.cancel()
            #expect(probe.metadata?.capture == capture && probe.metadata?.lastFinalAcceptedAt == date(200))
            #expect(probe.entry?.isValid == true && registry.entry(recordingID: f.identity.recordingID) == nil)
            #expect(!probe.returned && calls.values.isEmpty)
            #expect(registry.reservedPayloadBytes == 2 * LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes)
            try probe.value?.contextOwnership?.requireValid()
            await gate.release()
            await #expect(throws: LiveArtifactFixtureFailure.injected) { _ = try await operation?.value }
            operation = nil
            #expect(probe.returned && registry.entry(recordingID: f.identity.recordingID) == nil)
            #expect(throws: CancellationError.self) { try probe.value?.contextOwnership?.requireValid() }
            #expect(old?.segments.first?.text == "Original final")
            let failedValidity = probe.validity
            probe.value = nil
            try await f.eventually { await MainActor.run { registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes } }
            clock.value = date(400)
            try JSONEncoder().encode(TranscriptionResult(text: "Accepted replacement final")).write(to: canonical)
            registry.onHydration = { [weak registry] entry in
                guard let registry else { throw CancellationError() }
                let inspection = try registry.reserveReprocessingInspection()
                defer { withExtendedLifetime(inspection) {} }
                let current = try #require(try await resultStore.managedFinal(audioURL: f.audio, identity: f.identity, nonpersistingReplacement: true))
                try await entry.artifacts.reconcileFinal(current)
            }
            let replacement = try #require(try await registry.finishReplacement(phase))
            #expect(replacement.artifacts.ramMetadata?.capture == capture && replacement.artifacts.ramMetadata?.lastFinalAcceptedAt == date(400))
            #expect(replacement.validity !== oldValidity && replacement.validity !== failedValidity)
            #expect(!replacement.artifacts.capturePersistenceAllowed && replacement.artifacts.isNonpersistingFinalOnly)
            #expect(try replacement.artifacts.finalContext()?.segments.first?.text == "Accepted replacement final")
            try FileManager.default.removeItem(at: canonical)
            do {
                let inspection = try registry.reserveReprocessingInspection()
                defer { withExtendedLifetime(inspection) {} }
                let cleared = try #require(try await resultStore.managedFinal(audioURL: f.audio, identity: f.identity, nonpersistingReplacement: true))
                #expect(!cleared.hasFinal)
                try await replacement.artifacts.reconcileFinal(cleared)
            }
            #expect(try replacement.artifacts.finalContext() == nil)
            #expect(replacement.artifacts.ramMetadata?.lastFinalAcceptedAt == date(400) && clock.reads == 3)
            #expect(old?.segments.first?.text == "Original final")
            old = nil
            try await f.eventually { await MainActor.run { registry.reservedPayloadBytes == LiveRecordingArtifactOwner.reservationBytes + LiveManagedArtifactCatalogue.metadataBytes } }
            #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
        } catch { await gate.release(); _ = try? await operation?.value; throw error }
    }
    @Test(arguments: [false, true])
    func pendingReplacementRejectsEveryPublicRegistrationBeforeAdmission(residentOriginal: Bool) throws {
        let f = try LiveArtifactFixture(); defer { f.remove() }
        let capture = try LiveRAMCaptureMetadata(startedAt: date(10), intendedFolder: f.root)
        let calls = RAMMetadataCalls()
        let registry = LiveRecordingSessionRegistry(artifactRoot: f.root, beforeStage: { calls.record($0) })
        let original: LiveRecordingSessionRegistry.Entry?
        if residentOriginal {
            let entry = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture)
            try registry.captureDidClose(f.identity); try entry.artifacts.bind(to: f.audio)
            original = entry
        } else { original = nil }
        let phase = try registry.beginReplacement(recordingID: f.identity.recordingID, audioURL: f.audio)
        let reserved = registry.reservedPayloadBytes
        let metadataURL = f.audio.deletingPathExtension().appendingPathExtension("json")
        let audio = try Data(contentsOf: f.audio), metadata = try Data(contentsOf: metadataURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) {
            _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture)
        }
        #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) {
            _ = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false)
        }
        #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) { _ = try registry.registerLegacy(f.identity) }
        #expect(throws: LiveRecordingSessionRegistry.Failure.unavailable) { _ = try registry.register(f.identity) }
        #expect(registry.entry(recordingID: f.identity.recordingID) == nil && registry.entry(identity: f.identity) == nil)
        #expect(registry.owns(recordingID: f.identity.recordingID) == residentOriginal)
        #expect(registry.reservedPayloadBytes == reserved && registry.pendingLoads == 0 && calls.values.isEmpty)
        if let original {
            #expect(original.isValid && original.captureClosed && original.artifacts.ramMetadata?.capture == capture)
        }
        #expect(try Data(contentsOf: f.audio) == audio && Data(contentsOf: metadataURL) == metadata)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == files)
        #expect(!FileManager.default.fileExists(atPath: f.session.path))
        registry.abandonReplacement(phase)
        let admitted = try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture)
        #expect(admitted.isValid && admitted.artifacts.ramMetadata?.capture == capture)
        #expect(registry.entry(recordingID: f.identity.recordingID) === admitted)
        if let original { #expect(admitted === original && registry.reservedPayloadBytes == reserved) }
        #expect(try registry.registerLegacy(f.identity, capturePersistenceAllowed: false, ramCapture: capture) === admitted)
        #expect(calls.values.isEmpty && !FileManager.default.fileExists(atPath: f.session.path))
    }

}

@MainActor private final class RAMMetadataClock {
    var value: Date
    private(set) var reads = 0
    init(_ value: Date) { self.value = value }
    func sample() -> Date { reads += 1; return value }
}
private final class RAMMetadataCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [LiveArtifactStage] = []
    func record(_ value: LiveArtifactStage) { lock.withLock { stages.append(value) } }
    var values: [LiveArtifactStage] { lock.withLock { stages } }
}
@MainActor private final class RAMMetadataProbe {
    weak var entry: LiveRecordingSessionRegistry.Entry?
    var validity: RecordingDerivativeValidity?
    var value: TranscriptContextSnapshot?
    var metadata: LiveRAMSourceMetadata?
    var returned = false
}
