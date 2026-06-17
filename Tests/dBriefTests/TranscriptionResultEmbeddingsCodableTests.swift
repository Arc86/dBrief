import Foundation
import Testing
@testable import dBriefWire

@Suite("TranscriptionResult speakerEmbeddings codable")
struct TranscriptionResultEmbeddingsCodableTests {
    @Test("Round-trips speaker embeddings")
    func roundTrips() throws {
        let r = TranscriptionResult(
            text: "hi",
            segments: [.init(start: 0, end: 1, text: "hi", speaker: "Speaker 1")],
            speakerEmbeddings: ["Speaker 1": [0.1, 0.2, 0.3]]
        )
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        #expect(back.speakerEmbeddings?["Speaker 1"] == [0.1, 0.2, 0.3])
    }

    @Test("Legacy JSON without the field decodes to nil")
    func legacyDecodesNil() throws {
        let json = #"{"text":"hi","segments":[],"language":null,"warnings":null,"speakerCount":null}"#
        let back = try JSONDecoder().decode(TranscriptionResult.self, from: Data(json.utf8))
        #expect(back.speakerEmbeddings == nil)
        #expect(back.text == "hi")
    }
}
