import Foundation
import Testing
@testable import dBrief

@Suite("VoiceLibraryDisplay")
struct VoiceLibraryDisplayTests {
    private func person(_ name: String, _ times: [TimeInterval]) -> KnownPerson {
        KnownPerson(id: name.lowercased(), name: name,
                    voiceprints: times.map { Voiceprint(embedding: [1], model: "t", capturedAt: Date(timeIntervalSince1970: $0)) })
    }

    @Test("lastSeen returns the newest capturedAt, nil when empty")
    func lastSeen() {
        #expect(VoiceLibraryDisplay.lastSeen(person("A", [1, 9, 3])) == Date(timeIntervalSince1970: 9))
        #expect(VoiceLibraryDisplay.lastSeen(person("B", [])) == nil)
    }

    @Test("sampleSummary pluralizes")
    func sampleSummary() {
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [1])) == "1 voiceprint")
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [1, 2, 3])) == "3 voiceprints")
        #expect(VoiceLibraryDisplay.sampleSummary(person("A", [])) == "0 voiceprints")
    }

    @Test("sortedByLastSeen is newest-first, empties last, name tiebreak")
    func sorted() {
        let people = [person("Old", [1]), person("New", [100]), person("None", []), person("alsoNew", [100])]
        let names = VoiceLibraryDisplay.sortedByLastSeen(people).map(\.name)
        #expect(names == ["alsoNew", "New", "Old", "None"])
    }

    @Test("canEnroll requires a real name, an embedding, and not-yet-enrolled")
    func canEnroll() {
        // named + embedding + fresh → yes
        #expect(VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // raw name (== speakerId) → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Speaker 1", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // blank name → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "  ", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: false))
        // no embedding → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: false, alreadyEnrolled: false))
        // already enrolled → no
        #expect(!VoiceLibraryDisplay.canEnroll(displayName: "Jesper", speakerId: "Speaker 1", hasEmbedding: true, alreadyEnrolled: true))
    }
}
