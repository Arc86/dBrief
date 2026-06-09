import Foundation

public struct ParakeetModelInfo: Identifiable, Sendable {
    public let id: String          // "v2" or "v3"
    public let displayName: String
    public let estimatedMemoryMB: Int

    public init(id: String, displayName: String, estimatedMemoryMB: Int) {
        self.id = id
        self.displayName = displayName
        self.estimatedMemoryMB = estimatedMemoryMB
    }

    public static let variants: [ParakeetModelInfo] = [
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

    public static func find(_ id: String) -> ParakeetModelInfo {
        variants.first(where: { $0.id == id }) ?? variants[1]
    }
}
