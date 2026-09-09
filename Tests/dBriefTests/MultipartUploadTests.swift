import Foundation
import Testing
@testable import dBrief

@Suite("File-backed multipart uploads")
struct MultipartUploadTests {
    @Test("File-backed encoding preserves binary bytes, field order, and repeated fields")
    func wireBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("input.wav")
        let bytes = Data([0, 255, 13, 10, 42])
        try bytes.write(to: audio)
        var form = MultipartFormData(boundary: "fixed")
        form.addField(name: "model", value: "whisper-1")
        form.addFile(name: "file", fileName: "audio.wav", contentType: "audio/wav", fileURL: audio)
        form.addField(name: "timestamp_granularities[]", value: "segment")
        form.addField(name: "timestamp_granularities[]", value: "word")
        var expected = Data("--fixed\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--fixed\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        expected.append(bytes)
        expected.append(Data("\r\n--fixed\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n--fixed\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nword\r\n--fixed--\r\n".utf8))
        let actual = try await form.withBodyFile(in: root) { url in
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            return try Data(contentsOf: url)
        }
        #expect(actual == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["input.wav"])
        #expect(try Data(contentsOf: audio) == bytes)
    }

    @Test("Multiple copy buffers match the existing in-memory multipart encoding")
    func multipleBuffers() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("input.wav")
        let bytes = Data((0..<2_500_123).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: audio)
        var streamed = MultipartFormData(boundary: "same")
        streamed.addFile(name: "audio_file", fileName: "input.wav", contentType: "audio/wav", fileURL: audio)
        var reference = MultipartFormData(boundary: "same")
        reference.addFile(name: "audio_file", fileName: "input.wav", contentType: "audio/wav", data: bytes)
        let actual = try await streamed.withBodyFile(in: root) { try Data(contentsOf: $0) }
        #expect(actual == (try reference.encode()))
    }

    @Test("Unreadable source removes the partial upload body and never calls transport")
    func failedPreparation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var form = MultipartFormData()
        form.addField(name: "prompt", value: "private content")
        form.addFile(name: "file", fileName: "missing.wav", contentType: "audio/wav", fileURL: root.appendingPathComponent("missing"))
        await #expect(throws: (any Error).self) {
            _ = try await form.withBodyFile(in: root) { _ in Issue.record("Transport must not run") }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Transport failure and cancellation remove prepared bodies")
    func transportCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var form = MultipartFormData()
        form.addField(name: "prompt", value: "private content")
        await #expect(throws: URLError.self) {
            try await form.withBodyFile(in: root) { _ in throw URLError(.networkConnectionLost) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: CancellationError.self) {
            try await form.withBodyFile(in: root) { _ in throw CancellationError() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("An already-cancelled task does not prepare or send a body")
    func cancelledBeforePreparation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var form = MultipartFormData()
            form.addField(name: "model", value: "whisper-1")
            _ = try await form.withBodyFile(in: root) { _ in Issue.record("Transport must not run") }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
