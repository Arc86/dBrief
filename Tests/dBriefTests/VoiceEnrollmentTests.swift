import Foundation
import Testing
@testable import dBrief

@Suite("VoiceEnrollment.enrollable")
struct VoiceEnrollmentTests {
    @Test("Selects speakers with a real name and an embedding")
    func selectsNamedWithEmbedding() {
        let labels = [
            SpeakerLabel(id: "Speaker 1", displayName: "Alice"),
            SpeakerLabel(id: "Speaker 2", displayName: "Speaker 2"), // unnamed (raw id)
        ]
        let embeddings: [String: [Float]] = ["Speaker 1": [0.1, 0.2], "Speaker 2": [0.3, 0.4]]
        let entries = VoiceEnrollment.enrollable(speakerLabels: labels, embeddings: embeddings)
        #expect(entries == [.init(name: "Alice", embedding: [0.1, 0.2])])
    }

    @Test("Skips named speakers with no embedding")
    func skipsMissingEmbedding() {
        let labels = [SpeakerLabel(id: "Speaker 1", displayName: "Bob")]
        let entries = VoiceEnrollment.enrollable(speakerLabels: labels, embeddings: [:])
        #expect(entries.isEmpty)
    }

    @Test("Skips blank display names")
    func skipsBlank() {
        let labels = [SpeakerLabel(id: "Speaker 1", displayName: "   ")]
        let entries = VoiceEnrollment.enrollable(speakerLabels: labels, embeddings: ["Speaker 1": [1]])
        #expect(entries.isEmpty)
    }

    @Test("isDuplicate: true for near-identical, false for distinct or empty set")
    func isDuplicateThreshold() {
        let existing = [Voiceprint(embedding: [1, 0], model: "t", capturedAt: Date(timeIntervalSince1970: 0))]
        #expect(VoiceEnrollment.isDuplicate([1, 0.01], against: existing, threshold: 0.97) == true)
        #expect(VoiceEnrollment.isDuplicate([0, 1], against: existing, threshold: 0.97) == false)
        #expect(VoiceEnrollment.isDuplicate([1, 0], against: [], threshold: 0.97) == false)
    }
}
