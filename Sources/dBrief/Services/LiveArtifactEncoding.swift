import Foundation

/// Preflight the app's synthesized Codable artifact schemas before JSONEncoder
/// allocates output. Conservative bounds include escaping, base64, metadata,
/// cardinality and nesting; rejection preserves the caller's recoverable value.
/// This is internal to these concrete schemas, not a generic custom-Encoder API.
enum LiveArtifactEncoding {
    static func estimatedBytes(_ value: Any, limit: Int) throws -> Int {
        guard limit > 0 && limit <= 32 * 1_024 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
        var remaining = limit
        try measure(value, depth: 0, remaining: &remaining)
        return limit - remaining
    }
    static func encode<T: Encodable>(_ value: T, limit: Int, beforeEncoding: () -> Void = {}) throws -> Data {
        guard limit > 0 && limit <= 32 * 1_024 * 1_024 else { throw LiveArtifactError.artifactTooLarge }
        var remaining = limit
        try measure(value, depth: 0, remaining: &remaining)
        beforeEncoding()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let result = try encoder.encode(value)
        guard result.count <= limit else { throw LiveArtifactError.artifactTooLarge }
        return result
    }
    private static func add(_ bytes: Int, remaining: inout Int) throws {
        guard bytes >= 0, bytes <= remaining else { throw LiveArtifactError.artifactTooLarge }
        remaining -= bytes
    }
    private static func string(_ value: String, remaining: inout Int) throws {
        let count = value.utf8.count
        // Every UTF8 byte can require at most a six-byte JSON escape. Check
        // before multiplying so even an adversarial value cannot overflow.
        guard count <= remaining / 6 else { throw LiveArtifactError.artifactTooLarge }
        try add(count * 6, remaining: &remaining); try add(2, remaining: &remaining)
    }
    private static func measure(_ value: Any, depth: Int, remaining: inout Int) throws {
        guard depth <= 64 else { throw LiveArtifactError.artifactTooLarge }
        if let value = value as? String { try string(value, remaining: &remaining); return }
        if let value = value as? URL { try string(value.absoluteString, remaining: &remaining); return }
        if let value = value as? Data {
            guard value.count <= remaining / 4 * 3 - 2 else { throw LiveArtifactError.artifactTooLarge }
            try add((value.count + 2) / 3 * 4 + 2, remaining: &remaining); return
        }
        if value is UUID || value is Date || value is Bool || value is any BinaryInteger || value is Float || value is Double {
            try add(128, remaining: &remaining); return
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.children.count <= 100_000, let style = mirror.displayStyle, style != .class else { throw LiveArtifactError.artifactTooLarge }
        try add(128, remaining: &remaining)
        for child in mirror.children {
            // A comma for every collection entry and a colon for keyed fields.
            // Container overhead alone cannot bound many empty string entries.
            try add(2, remaining: &remaining)
            if let label = child.label { try string(label, remaining: &remaining) }
            try measure(child.value, depth: depth + 1, remaining: &remaining)
        }
    }
}
