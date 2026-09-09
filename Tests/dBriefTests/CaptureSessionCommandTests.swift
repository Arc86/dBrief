import Foundation
import Testing
@testable import dBrief

@Suite("Capture session commands") @MainActor
struct CaptureSessionCommandTests {
    private final class ProbeFileManager: FileManager, @unchecked Sendable {
        let unreadable: String?
        let unavailable: Bool
        init(unreadable: String? = nil, unavailable: Bool = false) {
            self.unreadable = unreadable.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            self.unavailable = unavailable
            super.init()
        }
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            #expect(!Thread.isMainThread)
            if unavailable { throw CocoaError(.fileReadNoPermission) }
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            #expect(!Thread.isMainThread)
            if URL(fileURLWithPath: path).standardizedFileURL.path == unreadable { throw CocoaError(.fileReadNoPermission) }
            return try super.attributesOfItem(atPath: path)
        }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-commands-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func dependencies(_ root: URL, duration: @escaping @Sendable (URL) async -> Double = { _ in 12.5 }) -> CaptureSessionStore.Dependencies {
        let journal = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics"))
        return .init(root: { root.appendingPathComponent("recovery") }, fileManager: { ProbeFileManager() },
            duration: duration, now: { Date(timeIntervalSince1970: 1000) }, record: {
                #expect(!Thread.isMainThread); journal.record($0)
            }, create: { id, date, root in
                #expect(!Thread.isMainThread)
                return try InterruptedSessionStore.createSession(id: id, startedAt: date, rootURL: root)
            }, write: { manifest, url in
                #expect(!Thread.isMainThread)
                try InterruptedSessionStore.write(manifest, to: url)
            }, remove: { url in
                #expect(!Thread.isMainThread)
                try InterruptedSessionStore.removeSession(containing: url, finalState: .discarded)
            })
    }
    private func manifest(_ session: CaptureSessionStore.Session) throws -> InterruptedSessionManifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InterruptedSessionManifest.self, from: Data(contentsOf: session.files.manifestURL))
    }
    private func events(_ root: URL) -> [DurabilityEvent] {
        DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
    }

    @Test func pauseResumeWritesCompatibleManifestAndDiagnosticsOffMain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureSessionStore(dependencies: dependencies(root))
        let session = try await store.create(id: UUID(), startedAt: Date(timeIntervalSince1970: 50))
        let mic = session.files.captureBaseURL.appendingPathExtension("mic.caf")
        try Data([1, 2, 3]).write(to: mic)
        let state = CaptureSessionStore.CaptureState(tracks: .init(systemURL: nil, micURL: mic))
        await store.pauseResume(session, state: state, paused: true)
        #expect(try manifest(session).state == .paused)
        #expect(try manifest(session).tracks.map(\.relativePath) == ["capture.mic.caf"])
        await store.pauseResume(session, state: state, paused: false)
        #expect(try manifest(session).state == .capturing)
        #expect(try Data(contentsOf: mic) == Data([1, 2, 3]))
        #expect(events(root).map(\.name) == ["capture_paused", "capture_resumed"])
    }

    @Test func creationAndStopKeepManifestAndAudioWhileMeasuringOffMain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureSessionStore(dependencies: dependencies(root))
        let session = try await store.create(id: UUID(), startedAt: Date(timeIntervalSince1970: 50))
        #expect(try manifest(session).tracks.count == 2)
        let mic = session.files.captureBaseURL.appendingPathExtension("mic.caf")
        let audio = Data(repeating: 7, count: 99)
        try audio.write(to: mic)
        var writes = AudioCaptureWriteDiagnostics()
        writes.microphone.buffersWritten = 5; writes.microphone.droppedBuffers = 1
        let state = CaptureSessionStore.CaptureState(tracks: .init(systemURL: nil, micURL: mic), duration: 3,
                                                    microphoneEnabled: true, writes: writes)
        try await store.began(session, state: state)
        #expect(try manifest(session).tracks.map(\.relativePath) == ["capture.mic.caf"])
        let stopped = await store.stopped(session, state: state, terminating: false)
        #expect(stopped.fileSize == 99 && stopped.duration == 12.5)
        #expect(try manifest(session).state == .finalizing)
        #expect(try Data(contentsOf: mic) == audio)
        #expect(events(root).map(\.name) == ["capture_started", "capture_stopped"])
        #expect(events(root).last?.outcome == .warning)
        #expect(events(root).last?.measurements["durationMilliseconds"] == 12500)
        #expect(events(root).last?.measurements["microphoneBuffers"] == 5)
        #expect(events(root).last?.measurements["microphoneDroppedBuffers"] == 1)
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 0])
    func invalidProbeUsesFrozenTimerAndCancelledCallerStillCheckpoints(probe: Double) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureSessionStore(dependencies: dependencies(root, duration: { _ in probe }))
        let session = try await store.create(id: UUID(), startedAt: Date())
        let mic = session.files.captureBaseURL.appendingPathExtension("mic.caf")
        try Data([1]).write(to: mic)
        let state = CaptureSessionStore.CaptureState(tracks: .init(systemURL: nil, micURL: mic), duration: 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.stopped(session, state: state, terminating: false)
        }
        let result = await task.value
        #expect(result.duration == 3 && result.fileSize == 1)
        #expect(try manifest(session).state == .finalizing)
        #expect(events(root).last?.outcome == .succeeded)
    }

    @Test func terminationSkipsProbeAndRetainsEmptyRecoveryForDiagnostics() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureSessionStore(dependencies: dependencies(root, duration: { _ in
            Issue.record("Quit must not wait on a duration probe"); return 10
        }))
        let session = try await store.create(id: UUID(), startedAt: Date())
        let result = await store.stopped(session, state: .init(duration: 3), terminating: true)
        #expect(result.duration == 3 && result.fileSize == 0)
        #expect(try manifest(session).state == .finalizing)
        #expect(events(root).last?.name == "capture_checkpointed_for_termination")
        #expect(events(root).last?.outcome == .failed)
    }

    @Test func failedStopCheckpointStillPreservesReadableCaptureAndMeasurements() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var files = dependencies(root)
        files.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let store = CaptureSessionStore(dependencies: files)
        let session = try await store.create(id: UUID(), startedAt: Date())
        let mic = session.files.captureBaseURL.appendingPathExtension("mic.caf")
        try Data([1, 2]).write(to: mic)
        let result = await store.stopped(session, state: .init(tracks: .init(systemURL: nil, micURL: mic)), terminating: false)
        #expect(result.fileSize == 2)
        #expect(try manifest(session).state == .capturing)
        #expect(InterruptedSessionDiscovery.discover(in: root.appendingPathComponent("recovery")).count == 1)
    }

    @Test(arguments: ["empty", "zero", "audio", "unreadable", "unlisted", "directory", "unavailable"])
    func failedStartDeletesOnlyProvenEmptySessions(kind: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), recovery = root.appendingPathComponent("recovery")
        let directory = recovery.appendingPathComponent(id.uuidString.lowercased())
        let mic = directory.appendingPathComponent("capture.mic.caf")
        var files = dependencies(root)
        files.fileManager = { ProbeFileManager(unreadable: kind == "unreadable" ? mic.path : nil, unavailable: kind == "unavailable") }
        let store = CaptureSessionStore(dependencies: files)
        let session = try await store.create(id: id, startedAt: Date())
        switch kind {
        case "zero", "unreadable": try Data().write(to: mic)
        case "audio": try Data([1]).write(to: mic)
        case "unlisted": try Data([2]).write(to: directory.appendingPathComponent("unreported.caf"))
        case "directory": try FileManager.default.createDirectory(at: directory.appendingPathComponent("unexpected"), withIntermediateDirectories: true)
        default: break
        }
        await store.failedStart(session, state: .init(tracks: .init(systemURL: nil, micURL: mic)),
                                failure: .init(error: CocoaError(.fileWriteUnknown)))
        #expect(FileManager.default.fileExists(atPath: session.files.directoryURL.path) == !(kind == "empty" || kind == "zero"))
        #expect(events(root).last?.outcome == .failed)
    }

    @Test func createFailureRecordsOnlyRedactedFingerprint() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var files = dependencies(root)
        files.create = { _, _, _ in throw NSError(domain: NSCocoaErrorDomain, code: 640,
                                                  userInfo: [NSLocalizedDescriptionKey: "private capture title"]) }
        let store = CaptureSessionStore(dependencies: files)
        await #expect(throws: NSError.self) { try await store.create(id: UUID(), startedAt: Date()) }
        #expect(events(root).last?.name == "capture_recovery_session_created")
        let encoded = String(decoding: try JSONEncoder().encode(events(root)), as: UTF8.self)
        #expect(!encoded.contains("private capture title") && !encoded.contains(root.path))
    }
}
