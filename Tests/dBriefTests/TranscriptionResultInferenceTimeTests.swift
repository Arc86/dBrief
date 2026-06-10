import Testing
import Foundation
@testable import dBriefWire

@Suite("TranscriptionResult.inferenceTime")
struct TranscriptionResultInferenceTimeTests {
    @Test("inferenceTime survives a JSON round-trip")
    func roundTripWithValue() throws {
        let r = TranscriptionResult(text: "hi", inferenceTime: 12.5)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        #expect(decoded.inferenceTime == 12.5)
    }

    @Test("Legacy JSON without inferenceTime decodes as nil")
    func legacyDecodesNil() throws {
        let legacy = #"{"text":"hi","segments":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: legacy)
        #expect(decoded.inferenceTime == nil)
    }
}
