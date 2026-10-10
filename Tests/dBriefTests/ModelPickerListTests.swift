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

    private let catalog = WhisperModelInfo.fallbackModelNames + ["openai_whisper-large-v3-v20240930_547MB"]

    @Test func whisperIDsDefaultToCuratedWithRecommendedFirst() {
        let ids = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "parakeet:v3",
                                                  showEveryVariant: false, query: "")
        #expect(ids.first == WhisperModelInfo.recommendedModelID)
        #expect(Set(ids) == Set(WhisperModelCatalog.curatedIDs.filter(catalog.contains)))
        #expect(!ids.contains("parakeet:v3"))
    }

    @Test func whisperIDsKeepsNonCuratedSelection() {
        let variant = "openai_whisper-large-v3-v20240930_547MB"
        let ids = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: variant,
                                                  showEveryVariant: false, query: "")
        #expect(ids.contains(variant))
        // Even if the catalog fetch no longer lists it.
        #expect(ModelPickerAllModels.whisperIDs(modelIDs: [], selectedID: variant,
                                                showEveryVariant: false, query: "") == [variant])
    }

    @Test func everyVariantOrSearchShowsTheWholeCatalog() {
        let all = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "", showEveryVariant: true, query: "")
        #expect(Set(all) == Set(catalog))
        #expect(all.first == WhisperModelInfo.recommendedModelID)
        let searched = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "", showEveryVariant: false, query: "x")
        #expect(Set(searched) == Set(catalog))
    }
}
