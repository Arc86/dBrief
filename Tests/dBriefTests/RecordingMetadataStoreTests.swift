import Foundation
import Testing
@testable import dBrief

@Suite("Serialized recording metadata")
struct RecordingMetadataStoreTests {
    private func fixture() throws -> (URL, RecordingMetadataPayload) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("meeting.wav")
        try Data([1]).write(to: audio)
        return (audio, .init(recordingID: UUID(), dateISO8601: "2026-09-08T09:00:00Z",
                            durationSeconds: 10, meetingTitle: "Meeting", masterFileName: audio.lastPathComponent,
                            segmentFileNames: [], warnings: []))
    }
    private func metadata(_ audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension("json") }

    @Test func concurrentFieldUpdatesAndCompletionPreserveEveryField() async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let store = RecordingMetadataStore()
        let url = metadata(audio)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object["futureField"] = ["keep": [1, 2, 3]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let stamp = ProcessingCompletionStamp(jobID: UUID(), completedAt: Date(timeIntervalSince1970: 100))
        async let title: Void = store.update(.generatedTitle("New title"), audioURL: audio)
        async let people: Void = store.update(.meetingContext(participants: ["Alice"], calendarAttendees: ["Bob"]), audioURL: audio)
        async let completed: Void = store.record(stamp, audioURL: audio, fallback: payload)
        _ = try await (title, people, completed)
        let saved = try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: url))
        #expect(saved.generatedTitle == "New title")
        #expect(saved.participants == ["Alice"] && saved.calendarAttendees == ["Bob"])
        #expect(saved.recordingID == payload.recordingID && saved.lastProcessingCompletion == stamp)
        object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((object["futureField"] as? [String: [Int]])?["keep"] == [1, 2, 3])
    }

    @Test func optionalEditsLeaveMissingAndInvalidMetadataUntouched() async throws {
        let (audio, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let url = metadata(audio)
        let store = RecordingMetadataStore()
        try await store.update(.generatedTitle("Title"), audioURL: audio)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        for data in [Data("corrupt".utf8), Data("{}".utf8)] {
            try data.write(to: url)
            try await store.update(.meetingContext(participants: ["Alice"], calendarAttendees: []), audioURL: audio)
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func failedWriteLeavesPreviousMetadataAndVerificationRejectsChangedBytes() async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let url = metadata(audio)
        let original = try JSONEncoder().encode(payload)
        try original.write(to: url)
        let failing = RecordingMetadataStore(files: .init(write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        await #expect(throws: CocoaError.self) { try await failing.update(.generatedTitle("Title"), audioURL: audio) }
        #expect(try Data(contentsOf: url) == original)
        let altered = RecordingMetadataStore(files: .init(write: { _, target in try original.write(to: target, options: .atomic) }))
        await #expect(throws: RecordingMetadataStore.Failure.self) {
            try await altered.update(.generatedTitle("Title"), audioURL: audio)
        }
    }

    @Test @MainActor func creationAndAllUpdatesPerformIOOffMainThread() async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let store = RecordingMetadataStore(files: .init(read: { url in
            #expect(!Thread.isMainThread)
            return try Data(contentsOf: url)
        }, write: { bytes, url in
            #expect(!Thread.isMainThread)
            try bytes.write(to: url, options: .atomic)
        }))
        try await store.create(payload, at: metadata(audio))
        try await store.update(.generatedTitle("Title"), audioURL: audio)
        try await store.update(.meetingContext(participants: ["Alice"], calendarAttendees: []), audioURL: audio)
        try await store.record(.init(jobID: UUID(), completedAt: .now), audioURL: audio, fallback: payload)
    }

    @Test func cancellationDuringAtomicWriteRetainsEvidenceWithoutAcknowledgingIt() async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let url = metadata(audio)
        let store = RecordingMetadataStore(files: .init(write: { bytes, target in
            try bytes.write(to: target, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let stamp = ProcessingCompletionStamp(jobID: UUID(), completedAt: .now)
        let task = Task { try await store.record(stamp, audioURL: audio, fallback: payload) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: url)).lastProcessingCompletion == stamp)
    }

    @Test(arguments: ["create", "update", "complete"])
    func alreadyCancelledWorkNeverTouchesMetadata(operation: String) async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let store = RecordingMetadataStore(files: .init(read: { _ in
            Issue.record("Cancelled metadata operation read storage"); return Data()
        }, write: { _, _ in Issue.record("Cancelled metadata operation wrote storage") },
        changed: { Issue.record("Cancelled metadata operation announced a change") }))
        let url = metadata(audio)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            switch operation {
            case "create": try await store.create(payload, at: url)
            case "update": try await store.update(.generatedTitle("Title"), audioURL: audio)
            default: try await store.record(.init(jobID: UUID(), completedAt: .now), audioURL: audio, fallback: payload)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test(arguments: ["writeFailure", "cancelAfterWrite"])
    @MainActor func importRetainsItsSourceUntilMetadataIsAcknowledged(failure: String) async throws {
        let (source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let original = try Data(contentsOf: source)
        let store = RecordingMetadataStore(files: .init(write: { bytes, target in
            if failure == "writeFailure" { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: target, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let finalizer = RecordingFinalizer(metadataStore: store)
        let recording = Recording(fileURL: source, meetingTitleDraft: "Retry fixture")
        let output = source.deletingLastPathComponent().appendingPathComponent("output")
        let task = Task {
            try await finalizer.importExistingAudio(sourceURL: source, snapshot: RecordingFinalizationSnapshot(recording: recording),
                                                    baseFolder: output, segmentationEnabled: false)
        }
        if failure == "writeFailure" {
            await #expect(throws: CocoaError.self) { _ = try await task.value }
        } else {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        #expect(try Data(contentsOf: source) == original)
        let files = try #require(FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let master = try #require(files.first { $0.pathExtension == "wav" })
        #expect(try Data(contentsOf: master) == original)
        if failure == "cancelAfterWrite" {
            let saved = try #require(files.first { $0.pathExtension == "json" })
            #expect(try JSONDecoder().decode(RecordingMetadataPayload.self, from: Data(contentsOf: saved)).recordingID == recording.id)
        }
    }

    @Test func cancellationDuringReadNeverWritesAnEdit() async throws {
        let (audio, payload) = try fixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let bytes = try JSONEncoder().encode(payload)
        let store = RecordingMetadataStore(files: .init(read: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return bytes
        }, write: { _, _ in Issue.record("Cancelled read must not produce a write") }))
        let task = Task { try await store.update(.generatedTitle("Title"), audioURL: audio) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}
