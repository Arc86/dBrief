import Foundation

public struct ParakeetModelInfo: Identifiable, Sendable {
    public let id: String          // "v2", "v3", "ultra", "redux" or "phonon2"
    public let displayName: String
    public let estimatedMemoryMB: Int
    public let isEnglishOnly: Bool
    /// Oldest macOS major version FluidAudio can run this variant on.
    public let minimumMacOSMajor: Int

    public init(id: String, displayName: String, estimatedMemoryMB: Int,
                isEnglishOnly: Bool = false, minimumMacOSMajor: Int = 14) {
        self.id = id
        self.displayName = displayName
        self.estimatedMemoryMB = estimatedMemoryMB
        self.isEnglishOnly = isEnglishOnly
        self.minimumMacOSMajor = minimumMacOSMajor
    }

    public static let defaultID = "v3"

    /// The 25 languages NVIDIA lists for parakeet-tdt-0.6b-v3
    /// (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). v3, Ultra and Redux are
    /// re-trainings of v3, so every multilingual variant shares this set.
    public static let languageCodes: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    public static let variants: [ParakeetModelInfo] = [
        ParakeetModelInfo(
            id: "v2",
            displayName: "Parakeet TDT 0.6B v2 (English)",
            estimatedMemoryMB: 1_500,
            isEnglishOnly: true
        ),
        ParakeetModelInfo(
            id: "v3",
            displayName: "Parakeet TDT 0.6B v3 (Multilingual)",
            estimatedMemoryMB: 1_800
        ),
        // v3 post-trained for accuracy; same architecture and int8 encoder as v3.
        ParakeetModelInfo(
            id: "ultra",
            displayName: "Parakeet Ultra (Multilingual, most accurate)",
            estimatedMemoryMB: 1_800
        ),
        // Ternary re-training of v3 (~220 MB download); packed low-bit weights need macOS 15.
        ParakeetModelInfo(
            id: "redux",
            displayName: "Parakeet Redux (Multilingual, smallest download)",
            estimatedMemoryMB: 1_200,
            minimumMacOSMajor: 15
        ),
        // Quantization-aware re-training of v3 for English (~360 MB download); fastest
        // v3-family encoder on the ANE. Palettized weights need macOS 15.
        ParakeetModelInfo(
            id: "phonon2",
            displayName: "Parakeet Phonon-2 (English, fastest)",
            estimatedMemoryMB: 1_500,
            isEnglishOnly: true,
            minimumMacOSMajor: 15
        ),
    ]

    public static var currentMacOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Variants this Mac can run, in catalog order.
    public static var available: [ParakeetModelInfo] { available(macOSMajor: currentMacOSMajor) }

    public static func available(macOSMajor: Int) -> [ParakeetModelInfo] {
        variants.filter { $0.minimumMacOSMajor <= macOSMajor }
    }

    /// The variant that will actually run: unknown ids and variants this OS
    /// cannot run resolve to the default, so UI, provenance and the helper agree.
    public static func find(_ id: String, macOSMajor: Int = currentMacOSMajor) -> ParakeetModelInfo {
        available(macOSMajor: macOSMajor).first { $0.id == id }
            ?? variants.first { $0.id == defaultID }!
    }
}
