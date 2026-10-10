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
        let ids = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "parakeet:v3", currentID: "",
                                                  showEveryVariant: false, query: "")
        #expect(ids.first == WhisperModelInfo.recommendedModelID)
        #expect(Set(ids) == Set(WhisperModelCatalog.curatedIDs.filter(catalog.contains)))
        #expect(!ids.contains("parakeet:v3"))
    }

    @Test func whisperIDsKeepsNonCuratedSelection() {
        let variant = "openai_whisper-large-v3-v20240930_547MB"
        let ids = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: variant, currentID: variant,
                                                  showEveryVariant: false, query: "")
        #expect(ids.contains(variant))
        // Even if the catalog fetch no longer lists it.
        #expect(ModelPickerAllModels.whisperIDs(modelIDs: [], selectedID: variant, currentID: variant,
                                                showEveryVariant: false, query: "") == [variant])
    }

    @Test func everyVariantOrSearchShowsTheWholeCatalog() {
        let all = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "", currentID: "", showEveryVariant: true, query: "")
        #expect(Set(all) == Set(catalog))
        #expect(all.first == WhisperModelInfo.recommendedModelID)
        let searched = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: "", currentID: "", showEveryVariant: false, query: "x")
        #expect(Set(searched) == Set(catalog))
    }

    @Test func savedNonCuratedModelStaysListedAfterSelectingAnotherRow() {
        let variant = "openai_whisper-large-v3-v20240930_547MB"
        let ids = ModelPickerAllModels.whisperIDs(modelIDs: catalog, selectedID: WhisperModelInfo.recommendedModelID,
                                                  currentID: variant, showEveryVariant: false, query: "")
        #expect(ids.contains(variant))
        #expect(ModelPickerAllModels.listIDs(modelIDs: catalog, selectedID: WhisperModelInfo.recommendedModelID,
                                             currentID: variant, showEveryVariant: false, query: "", modernApple: false)
                    .contains(variant))
    }

    @Test func tileAccessibilityValueIncludesTheTradeOff() throws {
        let profile = try #require(LocalTranscriptionChoice.profile("parakeet:v3"))
        #expect(ModelPickerQuickPick.accessibilityValue(profile: profile, downloaded: false)
                == "Speed: Very fast, Accuracy: Very good, 25 European languages, 1.8 GB RAM, not downloaded")
        #expect(ModelPickerQuickPick.accessibilityValue(profile: nil, downloaded: true) == "downloaded")
        #expect(ModelPickerQuickPick.accessibilityValue(profile: nil, downloaded: nil) == "checking download")
    }

    @Test func downloadTextNeverClaimsBeforeTheCheckAnswers() {
        #expect(ModelPickerQuickPick.downloadText(downloaded: nil, downloadMB: 632) == "Checking…")
        #expect(ModelPickerQuickPick.downloadText(downloaded: true, downloadMB: 632) == "✓ Downloaded")
        #expect(ModelPickerQuickPick.downloadText(downloaded: false, downloadMB: 632) == "Not downloaded · 632 MB")
        #expect(ModelPickerQuickPick.downloadText(downloaded: false, downloadMB: nil) == "Not downloaded")
    }

    @Test func memoryLimitMatchesTheSuggestionRule() {
        // 8 GB Mac, Turbo + speakers = 2.2 GB (27.5%): within the 50% rule, so not a warning.
        #expect(ModelSuggestions.fitsMemory(ramGiB: 1.7, speakersGiB: 0.5, installedGiB: 8))
        #expect(!ModelSuggestions.fitsMemory(ramGiB: 5, speakersGiB: 0.5, installedGiB: 8))
        #expect(ModelSuggestions.fitsMemory(ramGiB: 3.5, speakersGiB: 0.5, installedGiB: 8))   // exactly 50%
    }

    @Test func listCountFollowsSearchAndTheVariantToggle() {
        let defaultIDs = ModelPickerAllModels.listIDs(modelIDs: catalog, selectedID: "", currentID: "",
                                                      showEveryVariant: false, query: "", modernApple: false)
        let every = ModelPickerAllModels.listIDs(modelIDs: catalog, selectedID: "", currentID: "",
                                                 showEveryVariant: true, query: "", modernApple: false)
        #expect(every.count > defaultIDs.count)
        #expect(defaultIDs.contains(LocalTranscriptionChoice.apple))
        let searched = ModelPickerAllModels.listIDs(modelIDs: catalog, selectedID: "", currentID: "",
                                                    showEveryVariant: false, query: "ultra", modernApple: false)
        #expect(searched == ["parakeet:ultra"])
    }
}
