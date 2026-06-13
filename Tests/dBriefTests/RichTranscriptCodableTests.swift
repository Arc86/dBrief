import Foundation
@testable import dBrief
import Testing

@Suite("RichTranscript Codable")
struct RichTranscriptCodableTests {

    @Test("legacy JSON without meSpeakerId still decodes")
    func legacyDecode() throws {
        let json = """
        {"version":1,"segments":[{"id":"\(UUID().uuidString)","start":0,"end":1,"text":"hi","originalText":"hi"}],"speakerLabels":[]}
        """
        let data = Data(json.utf8)
        let t = try JSONDecoder().decode(RichTranscript.self, from: data)
        #expect(t.meSpeakerId == nil)
        #expect(t.segments.count == 1)
    }

    @Test("meSpeakerId round-trips through encode/decode")
    func meSpeakerRoundTrip() throws {
        var t = RichTranscript(segments: [
            RichSegment(start: 0, end: 1, text: "hi", originalText: "hi", speakerId: "Speaker 1"),
        ])
        t.meSpeakerId = "Speaker 1"
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(RichTranscript.self, from: data)
        #expect(decoded.meSpeakerId == "Speaker 1")
    }
}
