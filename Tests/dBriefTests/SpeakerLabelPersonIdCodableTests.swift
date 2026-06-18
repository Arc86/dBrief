import Foundation
import Testing
@testable import dBrief

@Suite("SpeakerLabel personId codable")
struct SpeakerLabelPersonIdCodableTests {
    @Test("Round-trips personId")
    func roundTrips() throws {
        let label = SpeakerLabel(id: "Speaker 1", displayName: "Alice", personId: "alice")
        let data = try JSONEncoder().encode(label)
        let back = try JSONDecoder().decode(SpeakerLabel.self, from: data)
        #expect(back.personId == "alice")
        #expect(back.displayName == "Alice")
    }

    @Test("Legacy JSON without personId decodes to nil")
    func legacyDecodesNil() throws {
        let json = #"{"id":"Speaker 1","displayName":"Bob"}"#
        let back = try JSONDecoder().decode(SpeakerLabel.self, from: Data(json.utf8))
        #expect(back.personId == nil)
        #expect(back.displayName == "Bob")
    }
}
