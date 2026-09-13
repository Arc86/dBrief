import Testing
@testable import dBrief
import dBriefWire

struct WhisperModelImpactTests {
    private let gib: UInt64 = 1_073_741_824

    @Test func memoryBoundaries() {
        for (size, expected) in [(1, 1), (2, 2), (3, 3), (5, 4), (6, 5)] {
            let impact = WhisperModelImpact.evaluate(estimatedRuntimeBytes: UInt64(size) * gib, physicalMemoryBytes: 16 * gib)
            #expect(impact.level == expected)
        }
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: gib + 1, physicalMemoryBytes: 8 * gib).level == 2)
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 2 * gib + 1, physicalMemoryBytes: 8 * gib).level == 3)
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 3 * gib + 1, physicalMemoryBytes: 8 * gib).level == 4)
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 5 * gib + 1, physicalMemoryBytes: 8 * gib).level == 5)
    }

    @Test func machineContext() {
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 2 * gib, physicalMemoryBytes: 8 * gib).label == "Lower memory demand")
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 2 * gib + 1, physicalMemoryBytes: 8 * gib).label == "Noticeable memory demand")
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 4 * gib, physicalMemoryBytes: 8 * gib).label == "Noticeable memory demand")
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 4 * gib + 1, physicalMemoryBytes: 8 * gib).label == "High memory demand")
        let over = WhisperModelImpact.evaluate(estimatedRuntimeBytes: 16 * gib, physicalMemoryBytes: 8 * gib)
        #expect(over.fraction == 2)
        #expect(over.label.contains("exceeds"))
    }

    @Test func unavailableInputs() {
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: nil, physicalMemoryBytes: 8 * gib).fraction == nil)
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: 0, physicalMemoryBytes: 8 * gib).level == nil)
        #expect(WhisperModelImpact.evaluate(estimatedRuntimeBytes: gib, physicalMemoryBytes: 0).fraction == nil)
    }

    @Test func verifiedCatalogAndUnknownModels() {
        for id in WhisperModelCatalog.curatedIDs {
            #expect(WhisperModelInfo.fallbackModelNames.contains(id))
        }
        #expect(!WhisperModelInfo.fallbackModelNames.contains("openai_whisper-large-v3_turbo_934MB"))
        #expect(WhisperModelCatalog.entries["custom_new-model"] == nil)
        #expect(WhisperModelInfo.parse("custom_new-model").id == "custom_new-model")
        #expect(WhisperModelCatalog.entries["distil-whisper_distil-large-v3"]?.englishOnly == true)
        #expect(WhisperModelCatalog.entries["openai_whisper-large-v3_turbo_954MB"]?.speed == 1)
        #expect(WhisperModelCatalog.entries["openai_whisper-large-v3-v20240930_turbo_632MB"]?.speed == 5)
    }

    @Test func everyVerifiedModelHasSourcedRatings() throws {
        #expect(WhisperModelCatalog.entries.count == 27)
        for (_, entry) in WhisperModelCatalog.entries {
            #expect((1...5).contains(try #require(entry.accuracy)))
            #expect((1...5).contains(try #require(entry.speed)))
            #expect(entry.ratingEvidence.hasPrefix("https://"))
            #expect(!entry.ratingMethod.isEmpty)
        }
        let distil = try #require(WhisperModelCatalog.entries["distil-whisper_distil-large-v3_594MB"])
        #expect(distil.ratingEvidence.contains("distil-whisper"))
        #expect(distil.ratingMethod.hasPrefix("Family estimate"))
    }
}
