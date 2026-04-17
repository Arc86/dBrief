import Foundation

struct ParakeetModelInfo: Identifiable, Sendable {
    let id: String          // "v2" or "v3"
    let displayName: String
    let estimatedMemoryMB: Int

    static let variants: [ParakeetModelInfo] = [
        ParakeetModelInfo(
            id: "v2",
            displayName: "Parakeet TDT 0.6B v2 (English)",
            estimatedMemoryMB: 1_500
        ),
        ParakeetModelInfo(
            id: "v3",
            displayName: "Parakeet TDT 0.6B v3 (Multilingual)",
            estimatedMemoryMB: 1_800
        ),
    ]

    static func find(_ id: String) -> ParakeetModelInfo {
        variants.first(where: { $0.id == id }) ?? variants[1]
    }
}
