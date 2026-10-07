import Foundation
import Testing
import dBriefWire
@testable import dBrief

@Suite struct ChatIndexTests {
    let windows = [TranscriptWindow(index: 0, start: 0, end: 9, text: "[00:00:00] A: one"),
                   TranscriptWindow(index: 1, start: 10, end: 19, text: "[00:00:10] B: two")]

    @Test func vectorsRoundTripThroughBinaryStorage() throws {
        let index = ChatIndex(windows: windows, vectors: [[0.5, -1], [2, 0.25]], model: "m")
        let decoded = try JSONDecoder().decode(ChatIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded.vectors == [[0.5, -1], [2, 0.25]])
    }

    @Test func renamedSpeakerInvalidatesIndex() {
        let index = ChatIndex(windows: windows, vectors: [[1], [1]], model: "m")
        let renamed = [TranscriptWindow(index: 0, start: 0, end: 9, text: "[00:00:00] Alice: one"), windows[1]]
        #expect(index.isValid(for: windows, model: "m"))
        #expect(!index.isValid(for: renamed, model: "m"))
        #expect(!index.isValid(for: windows, model: "other-model"))
    }

    @Test func emptyVectorIndexIsConstructible() {
        let index = ChatIndex(windows: windows, vectors: [], model: "m")
        #expect(index.dims == 0)
        #expect(index.vectors.isEmpty)
        #expect(index.vectorData.isEmpty)
    }

    @Test func mismatchedVectorDataIsInvalid() {
        var index = ChatIndex(windows: windows, vectors: [[1, 2], [3, 4]], model: "m")
        #expect(index.isValid(for: windows, model: "m"))
        index.vectorData = index.vectorData.dropLast(4)
        #expect(!index.isValid(for: windows, model: "m"))
    }

    @Test func loadRejectsMismatchedVectorData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chatindex.json")
        defer { try? FileManager.default.removeItem(at: url) }
        var index = ChatIndex(windows: windows, vectors: [[1, 2], [3, 4]], model: "m")
        index.vectorData = index.vectorData.dropLast(4)
        try JSONEncoder().encode(index).write(to: url)
        #expect(await ChatIndexStore().load(from: url) == nil)
    }

    @Test func storeBuildsOnceThenReuses() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chatindex.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatIndexStore()
        let calls = Counter()
        let embed: @Sendable ([String]) async throws -> [[Float]] = { texts in
            await calls.bump(); return texts.map { _ in [1, 0] }
        }
        _ = try await store.index(for: windows, at: url, embed: embed)
        _ = try await store.index(for: windows, at: url, embed: embed)
        #expect(await calls.value == 1)
    }

    @Test func emptyVectorIndexIsNeverSaved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".chatindex.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ChatIndexStore()
        let index = try await store.index(for: windows, at: url, embed: { _ in [] })
        #expect(index.vectors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) { try await store.save(index, to: url) }
    }

    @Test func sidecarIsRegisteredForCleanup() {
        #expect(RetentionCleanup.transcriptSuffixes.contains(".chatindex.json"))
        #expect(ReprocessingStore.allowedSuffixes.contains("chatindex.json"))
    }
}

actor Counter { var value = 0; func bump() { value += 1 } }
