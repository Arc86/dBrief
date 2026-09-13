import Foundation

/// Verified folder identities; ratings are editorial guidance, never benchmarks.
public struct WhisperCatalogEntry: Sendable {
    public let englishOnly: Bool
    public let runtimeGiB: Double
    public let accuracy: Int?
    public let speed: Int?
    public let role: String?
    public let evidence: String
    public let ratingEvidence: String
    public let ratingMethod: String
    public let verifiedOn = "2026-09-13"
}

public enum WhisperModelCatalog {
    public static let curatedIDs = [
        "openai_whisper-tiny", "openai_whisper-small", "openai_whisper-medium",
        "openai_whisper-large-v3-v20240930_turbo_632MB", "openai_whisper-large-v3"
    ]

    public static let entries: [String: WhisperCatalogEntry] = {
        var result: [String: WhisperCatalogEntry] = [:]
        func add(_ id: String, _ ram: Double, _ quality: Int? = nil, _ speed: Int? = nil, _ role: String? = nil) {
            let distil = id.hasPrefix("distil-whisper_")
            let septemberTurbo = id.contains("v20240930")
            // Only verified IDs reach this function. Unknown downloads never inherit a rating.
            // Argmax's _turbo suffix alone is NOT OpenAI's pruned September Turbo model.
            let familyQuality = distil || septemberTurbo ? 4 : id.contains("large-v3") ? 5 : id.contains("large-v2") ? 4 : 3
            let familySpeed = septemberTurbo ? 5 : distil ? 4 : id.contains("large") ? 1 : 4
            let variant = id.contains("_turbo") || id.hasSuffix("MB")
            result[id] = WhisperCatalogEntry(
                englishOnly: id.contains(".en") || id.hasPrefix("distil-whisper_"),
                runtimeGiB: ram, accuracy: quality ?? familyQuality, speed: speed ?? familySpeed, role: role,
                evidence: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main",
                ratingEvidence: distil ? "https://huggingface.co/distil-whisper/distil-large-v3" : "https://github.com/openai/whisper#available-models-and-languages",
                ratingMethod: variant
                    ? "Family estimate: inherits the parent model's broad accuracy and speed bands. Compression and Core ML optimizations can change both; this exact variant has not been benchmarked in dBrief."
                    : "Research-based estimate: editorial five-point bands from the model author's published tradeoffs. These are not measured results on your Mac; language, audio and decoding settings affect performance.")
        }
        // Coarse ordering follows OpenAI's documented size/speed tradeoffs.
        // Core ML RAM figures are planning estimates, not CUDA VRAM figures.
        for suffix in ["", ".en"] {
            add("openai_whisper-tiny" + suffix, 0.5, 1, 5, suffix.isEmpty ? "Lightest" : nil)
            add("openai_whisper-base" + suffix, 0.8, 2, 4)
            add("openai_whisper-small" + suffix, 2, 3, 4, suffix.isEmpty ? "Balanced" : nil)
            add("openai_whisper-medium" + suffix, 3, 4, 2, suffix.isEmpty ? "Higher accuracy" : nil)
        }
        add("openai_whisper-small_216MB", 1.3)
        add("openai_whisper-small.en_217MB", 1.3)
        add("openai_whisper-large-v2", 5, 4, 1)
        add("openai_whisper-large-v2_949MB", 2)
        add("openai_whisper-large-v2_turbo", 5)
        add("openai_whisper-large-v2_turbo_955MB", 2)
        add("openai_whisper-large-v3", 5, 5, 1, "Quality first")
        add("openai_whisper-large-v3_947MB", 2)
        add("openai_whisper-large-v3_turbo", 5)
        add("openai_whisper-large-v3_turbo_954MB", 2)
        add("openai_whisper-large-v3-v20240930", 2)
        add("openai_whisper-large-v3-v20240930_547MB", 1.6)
        add("openai_whisper-large-v3-v20240930_626MB", 1.7)
        add("openai_whisper-large-v3-v20240930_turbo", 2)
        add("openai_whisper-large-v3-v20240930_turbo_632MB", 1.7, nil, nil, "Recommended")
        add("distil-whisper_distil-large-v3", 4)
        add("distil-whisper_distil-large-v3_594MB", 1.6)
        add("distil-whisper_distil-large-v3_turbo", 4)
        add("distil-whisper_distil-large-v3_turbo_600MB", 1.6)
        return result
    }()
}
