import Foundation
import Testing
@testable import dBrief

@Suite("Capture session recovery")
struct CaptureSessionRecoveryTests {
    private final class ProbeFileManager: FileManager, @unchecked Sendable {
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            #expect(!Thread.isMainThread)
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            #expect(!Thread.isMainThread)
            return try super.attributesOfItem(atPath: path)
        }
    }
    private actor Audit {
        var ids: [UUID] = []
        func add(_ id: UUID) { ids.append(id) }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func session(_ id: UUID, in root: URL, time: Double = 1, mic: Bool = true) throws -> InterruptedCaptureSession {
        let session = try InterruptedSessionStore.createSession(id: id, startedAt: Date(timeIntervalSince1970: time),
                                                               rootURL: root.appendingPathComponent("recovery"))
        if mic { try Data(repeating: 1, count: 30).write(to: session.captureBaseURL.appendingPathExtension("mic.caf")) }
        try Data(repeating: 2, count: 70).write(to: session.captureBaseURL.appendingPathExtension("system.caf"))
        return session
    }
    private func dependencies(_ root: URL, duration: @escaping @Sendable (URL) async -> Double = { _ in 4 }) -> CaptureSessionStore.Dependencies {
        let journal = DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics"))
        return .init(root: { root.appendingPathComponent("recovery") }, fileManager: { ProbeFileManager() },
                     duration: duration, now: { Date(timeIntervalSince1970: 1000) }, record: { event in
            #expect(!Thread.isMainThread)
            journal.record(event)
        })
    }
    private func events(_ root: URL) -> [DurabilityEvent] {
        DurabilityJournal(directoryURL: root.appendingPathComponent("diagnostics")).recentEvents()
    }

    @Test @MainActor func recoveryMeasuresOffMainAndFinalizesNewestFirstWithCapturedContext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let older = UUID(), newer = UUID()
        let oldSession = try session(older, in: root, time: 1, mic: false)
        let newSession = try session(newer, in: root, time: 2)
        let output = root.appendingPathComponent("master.m4a")
        try Data(repeating: 3, count: 150).write(to: output)
        let context = PrivacyTrace.Context(receiptURL: root.appendingPathComponent("privacy.json"), recordingID: newer)
        let audit = Audit()
        let store = CaptureSessionStore(dependencies: dependencies(root, duration: { url in
            #expect(PrivacyTrace.context?.runID == context.runID)
            #expect(url == newSession.captureBaseURL.appendingPathExtension("mic.caf")
                    || url == oldSession.captureBaseURL.appendingPathExtension("system.caf"))
            return 7.5
        }))
        let report = try await PrivacyTrace.$context.withValue(context) {
            try await store.recoverInterrupted { @MainActor input in
                #expect(input.duration == 7.5)
                #expect(input.fileSize == (input.candidate.manifest.id == newer ? 100 : 70))
                #expect(PrivacyTrace.context?.runID == context.runID)
                await audit.add(input.candidate.manifest.id)
                return output
            }
        }
        #expect(report == .init(recovered: 2, failed: 0))
        #expect(await audit.ids == [newer, older])
        let logged = events(root)
        #expect(logged.map(\.name) == ["interrupted_capture_discovered", "interrupted_capture_recovered",
                                     "interrupted_capture_discovered", "interrupted_capture_recovered"])
        #expect(logged.map(\.outcome) == [.warning, .succeeded, .warning, .succeeded])
        #expect(logged.first?.measurements["trackBytes"] == 100)
        #expect(logged.last?.measurements["masterBytes"] == 150)
        #expect(logged.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: 1000) })
        #expect(FileManager.default.fileExists(atPath: newSession.manifestURL.path))
    }

    @Test func failedSessionRetainsEvidenceAndLaterSessionStillRecovers() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let failing = UUID(), succeeding = UUID()
        let failedSession = try session(failing, in: root, time: 2)
        _ = try session(succeeding, in: root, time: 1)
        let output = root.appendingPathComponent("master.m4a")
        try Data([1, 2]).write(to: output)
        let report = try await CaptureSessionStore(dependencies: dependencies(root)).recoverInterrupted { input in
            if input.candidate.manifest.id == failing {
                throw NSError(domain: NSCocoaErrorDomain, code: 640,
                              userInfo: [NSLocalizedDescriptionKey: "private title and raw response"])
            }
            return output
        }
        #expect(report == .init(recovered: 1, failed: 1))
        #expect(events(root).map(\.outcome) == [.warning, .failed, .warning, .succeeded])
        #expect(events(root)[1].measurements["microphoneTrackBytes"] == 30)
        let encoded = String(decoding: try JSONEncoder().encode(events(root)), as: UTF8.self)
        #expect(!encoded.contains("private title"))
        #expect(!encoded.contains(root.path))
        #expect(FileManager.default.fileExists(atPath: failedSession.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: failedSession.captureBaseURL.appendingPathExtension("mic.caf").path))
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 0]) func selectedSessionUsesZeroForInvalidDuration(seconds: Double) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = UUID()
        _ = try session(selected, in: root)
        _ = try session(UUID(), in: root)
        let report = try await CaptureSessionStore(dependencies: dependencies(root, duration: { _ in seconds }))
            .recoverInterrupted(only: selected) { input in
                #expect(input.candidate.manifest.id == selected)
                #expect(input.duration == 0)
                return root.appendingPathComponent("missing-master.m4a")
            }
        #expect(report == .init(recovered: 1, failed: 0))
        #expect(events(root).count == 2)
        #expect(events(root).last?.measurements["masterBytes"] == 0)
    }

    @Test func emptyDiscoveryDoesNotFinalizeOrRecord() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let report = try await CaptureSessionStore(dependencies: dependencies(root)).recoverInterrupted { _ in
            Issue.record("No candidate to finalize"); return root
        }
        #expect(report == .init(recovered: 0, failed: 0))
        #expect(events(root).isEmpty)
    }

    @Test(arguments: [false, true]) func cancellationBeforeFinalizationIsNotARecoveryFailure(atEntry: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try session(UUID(), in: root)
        let store = CaptureSessionStore(dependencies: dependencies(root, duration: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return 1
        }))
        let task = Task {
            if atEntry { withUnsafeCurrentTask { $0?.cancel() } }
            return try await store.recoverInterrupted { _ in
                Issue.record("Cancellation must stop finalization"); return root
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events(root).map(\.outcome) == (atEntry ? [] : [.warning]))
    }

    @Test func committedSuccessIsRecordedBeforeCancelledCallerReturns() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try session(UUID(), in: root)
        let output = root.appendingPathComponent("committed.m4a")
        let store = CaptureSessionStore(dependencies: dependencies(root))
        let task = Task {
            try await store.recoverInterrupted { _ in
                try Data([1, 2, 3]).write(to: output)
                withUnsafeCurrentTask { $0?.cancel() }
                return output
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events(root).map(\.outcome) == [.warning, .succeeded])
        #expect(events(root).last?.measurements["masterBytes"] == 3)
        #expect(try Data(contentsOf: output) == Data([1, 2, 3]))
    }

    @Test(arguments: [false, true]) func finalizerCancellationDoesNotCountAsFailure(callerCancelled: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(UUID(), in: root, time: 2)
        _ = try self.session(UUID(), in: root, time: 1)
        let store = CaptureSessionStore(dependencies: dependencies(root))
        let task = Task {
            try await store.recoverInterrupted { _ in
                if callerCancelled {
                    withUnsafeCurrentTask { $0?.cancel() }
                    // Some backends throw an ordinary error as cancellation lands.
                    throw CocoaError(.fileWriteUnknown)
                }
                throw CancellationError()
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events(root).map(\.name) == ["interrupted_capture_discovered"])
        #expect(FileManager.default.fileExists(atPath: session.manifestURL.path))
    }
}
