import Testing
import dBriefWire
@testable import dBrief

struct ModelPickerListTests {
    @Test func ratingWords() {
        #expect(ModelRatingKind.speed.word(5) == "Very fast")
        #expect(ModelRatingKind.speed.word(1) == "Very slow")
        #expect(ModelRatingKind.accuracy.word(4) == "Very good")
        #expect(ModelRatingKind.accuracy.word(1) == "Basic")
        #expect(ModelRatingKind.accuracy.word(9) == "Excellent")   // clamps
        #expect(ModelRatingKind.speed.word(0) == "Very slow")       // clamps
    }
}
