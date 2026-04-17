import Foundation

struct ParakeetModelInfo: Identifiable, Sendable {
    let id: String          // HuggingFace folder name, e.g. "nvidia_parakeet-tdt-0.6b-v3"
    let displayName: String
    let estimatedMemoryMB: Int

    static let variants: [ParakeetModelInfo] = [
        ParakeetModelInfo(
            id: "nvidia_parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            estimatedMemoryMB: 1_500
        ),
        ParakeetModelInfo(
            id: "nvidia_parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            estimatedMemoryMB: 1_500
        ),
    ]

    static func find(_ id: String) -> ParakeetModelInfo {
        variants.first(where: { $0.id == id }) ?? variants[1]
    }
}
