import Foundation

/// Parsed metadata for HuggingFace Whisper model folder names.
/// Examples:
/// - `openai_whisper-small` → displayName: "Whisper Small", family: "small", estimatedMemoryMB: 2048
/// - `openai_whisper-small.en` → displayName: "Whisper Small (English)", isEnglishOnly: true
/// - `openai_whisper-large-v3_turbo_954MB` → displayName: "Whisper Large V3 Turbo (954 MB)", isTurbo: true, quantizedSizeMB: 954
/// - `distil-whisper_distil-large-v3_turbo_600MB` → displayName: "Distil Large V3 Turbo (600 MB)"
/// - `openai_whisper-large-v3-v20240930_626MB` → displayName: "Whisper Large V3 Sep24 (626 MB)"
struct WhisperModelInfo: Sendable {
    let originalName: String
    let displayName: String
    let family: String
    let isEnglishOnly: Bool
    let isTurbo: Bool
    let quantizedSizeMB: Int?
    let estimatedMemoryMB: Int

    /// Parse a HuggingFace model folder name into structured metadata.
    static func parse(_ modelName: String) -> WhisperModelInfo {
        let originalName = modelName

        // Extract components
        let isEnglishOnly = modelName.contains(".en")
        let isTurbo = modelName.contains("_turbo")

        // Extract quantized size if present (e.g., "954MB" at end)
        var cleanName = modelName
        var quantizedSizeMB: Int? = nil
        if let sizeMatch = modelName.range(of: #"_(\d+)MB$"#, options: .regularExpression) {
            let sizeStr = String(modelName[sizeMatch]).dropFirst().dropLast(2)
            quantizedSizeMB = Int(sizeStr)
            cleanName = String(modelName[..<sizeMatch.lowerBound])
        }

        // Remove .en suffix for family extraction
        if cleanName.hasSuffix(".en") {
            cleanName = String(cleanName.dropLast(3))
        }

        // Determine family from model name
        let family = extractFamily(from: cleanName)

        // Build display name
        let displayName = buildDisplayName(
            family: family,
            isEnglishOnly: isEnglishOnly,
            isTurbo: isTurbo,
            quantizedSizeMB: quantizedSizeMB
        )

        // Calculate estimated memory
        let estimatedMemoryMB = calculateMemory(
            family: family,
            quantizedSizeMB: quantizedSizeMB
        )

        return WhisperModelInfo(
            originalName: originalName,
            displayName: displayName,
            family: family,
            isEnglishOnly: isEnglishOnly,
            isTurbo: isTurbo,
            quantizedSizeMB: quantizedSizeMB,
            estimatedMemoryMB: estimatedMemoryMB
        )
    }

    /// Extract the model family from a cleaned model name.
    private static func extractFamily(from cleanName: String) -> String {
        // Remove prefixes: "openai_whisper-" or "distil-whisper_distil-"
        var name = cleanName
        var isDistil = false

        if name.hasPrefix("openai_whisper-") {
            name = String(name.dropFirst("openai_whisper-".count))
        } else if name.hasPrefix("distil-whisper_distil-") {
            name = String(name.dropFirst("distil-whisper_distil-".count))
            isDistil = true
        }

        // Remove turbo suffix
        if name.hasSuffix("_turbo") {
            name = String(name.dropLast("_turbo".count))
        }

        // For distil models, reconstruct as "distil-<rest>"
        if isDistil {
            name = "distil-" + name
        }

        // Normalize: v3-v20240930 → large-v3-v20240930, etc.
        // If it starts with a family name directly, use it
        if name.hasPrefix("tiny") { return "tiny" }
        if name.hasPrefix("base") { return "base" }
        if name.hasPrefix("small") { return "small" }
        if name.hasPrefix("medium") { return "medium" }
        if name.hasPrefix("large-v2") { return "large-v2" }
        if name.hasPrefix("large-v3-v") { return "large-v3-v20240930" } // e.g., "large-v3-v20240930"
        if name.hasPrefix("large-v3") { return "large-v3" }
        if name.hasPrefix("large") { return "large" }
        if name.hasPrefix("distil-large-v3") { return "distil-large-v3" }
        if name.hasPrefix("distil") { return "distil-large-v3" } // fallback for distil variants

        return name // fallback
    }

    /// Build a human-readable display name.
    private static func buildDisplayName(
        family: String,
        isEnglishOnly: Bool,
        isTurbo: Bool,
        quantizedSizeMB: Int?
    ) -> String {
        var displayName = ""

        // Family name
        let familyDisplay: String
        switch family {
        case "tiny":
            familyDisplay = "Whisper Tiny"
        case "base":
            familyDisplay = "Whisper Base"
        case "small":
            familyDisplay = "Whisper Small"
        case "medium":
            familyDisplay = "Whisper Medium"
        case "large-v2":
            familyDisplay = "Whisper Large V2"
        case "large-v3":
            familyDisplay = "Whisper Large V3"
        case "large-v3-v20240930":
            familyDisplay = "Whisper Large V3 Sep24"
        case "distil-large-v3":
            familyDisplay = "Distil Large V3"
        default:
            familyDisplay = family.replacingOccurrences(of: "-", with: " ").capitalized
        }

        displayName = familyDisplay

        // Turbo suffix
        if isTurbo {
            displayName += " Turbo"
        }

        // English-only suffix
        if isEnglishOnly {
            displayName += " (English)"
        }

        // Quantized size suffix
        if let sizeMB = quantizedSizeMB {
            displayName += " (\(sizeMB) MB)"
        }

        return displayName
    }

    /// Calculate estimated memory in MB based on family and quantization.
    private static func calculateMemory(
        family: String,
        quantizedSizeMB: Int?
    ) -> Int {
        // Base memory by family (in MB)
        let baseMemory: Int
        switch family {
        case "tiny":
            baseMemory = 500
        case "base":
            baseMemory = 800
        case "small":
            baseMemory = 2048
        case "medium":
            baseMemory = 3072
        case "large-v2", "large-v3", "large-v3-v20240930", "large", "distil-large-v3":
            baseMemory = 5120
        default:
            baseMemory = 3072 // conservative default
        }

        // If quantized, add 1GB buffer
        if let quantizedSize = quantizedSizeMB {
            return quantizedSize + 1024
        }

        return baseMemory
    }

    /// Fallback list of core Whisper models for offline use.
    static let fallbackModels: [WhisperModelInfo] = [
        parse("openai_whisper-tiny"),
        parse("openai_whisper-tiny.en"),
        parse("openai_whisper-base"),
        parse("openai_whisper-base.en"),
        parse("openai_whisper-small"),
        parse("openai_whisper-small.en"),
        parse("openai_whisper-medium"),
        parse("openai_whisper-medium.en"),
        parse("openai_whisper-large-v3_turbo_934MB"),
        parse("openai_whisper-large-v3_turbo_934MB.en"),
        parse("openai_whisper-large-v3_1550MB"),
        parse("openai_whisper-large-v3_1550MB.en"),
        parse("distil-whisper_distil-medium.en_600MB"),
        parse("distil-whisper_distil-large-v3_turbo_600MB"),
        parse("distil-whisper_distil-large-v3_turbo_600MB.en"),
        parse("openai_whisper-large-v3-v20240930_626MB"),
    ]
}

// MARK: - Comparable

extension WhisperModelInfo: Comparable {
    private static let familyOrder: [String: Int] = [
        "tiny": 0,
        "base": 1,
        "small": 2,
        "medium": 3,
        "large-v2": 4,
        "large-v3": 5,
        "large-v3-v20240930": 6,
        "distil-large-v3": 7,
    ]

    static func < (lhs: WhisperModelInfo, rhs: WhisperModelInfo) -> Bool {
        // 1. Compare by family order
        let lhsFamilyOrder = familyOrder[lhs.family] ?? 99
        let rhsFamilyOrder = familyOrder[rhs.family] ?? 99

        if lhsFamilyOrder != rhsFamilyOrder {
            return lhsFamilyOrder < rhsFamilyOrder
        }

        // 2. Non-English before English (if same family)
        if lhs.isEnglishOnly != rhs.isEnglishOnly {
            return !lhs.isEnglishOnly // false < true, so non-English comes first
        }

        // 3. Non-turbo before turbo (if same family and English status)
        if lhs.isTurbo != rhs.isTurbo {
            return !lhs.isTurbo // false < true, so non-turbo comes first
        }

        // 4. Full before quantized (if same family, English status, and turbo status)
        let lhsIsQuantized = lhs.quantizedSizeMB != nil
        let rhsIsQuantized = rhs.quantizedSizeMB != nil

        if lhsIsQuantized != rhsIsQuantized {
            return !lhsIsQuantized // false < true, so non-quantized comes first
        }

        // 5. If both quantized, smaller size first
        if let lhsSize = lhs.quantizedSizeMB, let rhsSize = rhs.quantizedSizeMB {
            return lhsSize < rhsSize
        }

        // 6. Fallback: stable sort by original name
        return lhs.originalName < rhs.originalName
    }

    static func == (lhs: WhisperModelInfo, rhs: WhisperModelInfo) -> Bool {
        return lhs.originalName == rhs.originalName
    }
}
