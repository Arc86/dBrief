import Foundation
import Testing
@testable import dBrief

@Suite("WebhookPayloadBuilder")
struct WebhookPayloadBuilderTests {

    @Test("streamed multipart body file is byte-identical to MultipartFormData.encode()")
    func multipartFileMatchesInMemoryEncoding() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("webhook-test-\(UUID().uuidString).m4a")
        // >1 MB so the streaming path takes more than one chunk.
        let audioBytes = Data((0..<(1_500_000)).map { UInt8(truncatingIfNeeded: $0) })
        try audioBytes.write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let metadataJSON = Data(#"{"recording_id":"abc","title":"Test"}"#.utf8)
        let boundary = "test-boundary-123"

        let bodyURL = try WebhookPayloadBuilder.writeMultipartBodyFile(
            metadataJSON: metadataJSON,
            audioURL: audioURL,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let streamed = try Data(contentsOf: bodyURL)

        var multipart = MultipartFormData(boundary: boundary)
        multipart.addField(name: "metadata", value: String(data: metadataJSON, encoding: .utf8)!)
        multipart.addFile(
            name: "audio_file",
            fileName: audioURL.lastPathComponent,
            contentType: WebhookPayloadBuilder.contentType(for: audioURL),
            data: audioBytes
        )
        let reference = multipart.encode()

        #expect(streamed == reference)
    }
}
