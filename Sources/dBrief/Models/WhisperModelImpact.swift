import Foundation

struct WhisperModelImpact {
    let level: Int?
    let fraction: Double?
    var label: String {
        guard let fraction else { return "Estimate unavailable" }
        if fraction > 1 { return "Estimated model memory exceeds installed RAM" }
        if fraction > 0.5 { return "High memory demand" }
        if fraction > 0.25 { return "Noticeable memory demand" }
        return "Lower memory demand"
    }
    static func evaluate(estimatedRuntimeBytes: UInt64?, physicalMemoryBytes: UInt64) -> Self {
        guard let bytes = estimatedRuntimeBytes, bytes > 0, physicalMemoryBytes > 0 else {
            return Self(level: nil, fraction: nil)
        }
        let gib = Double(bytes) / 1_073_741_824
        let level = gib <= 1 ? 1 : gib <= 2 ? 2 : gib <= 3 ? 3 : gib <= 5 ? 4 : 5
        return Self(level: level, fraction: Double(bytes) / Double(physicalMemoryBytes))
    }
}
