import Foundation

struct LibraryPerson: Codable, Equatable, Sendable {
    let key: String
    let name: String

    static func normalized(_ names: [String], excluding selfNames: [String]) -> [Self] {
        func key(_ value: String) -> String {
            PersonName.display(value).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let excluded = Set((selfNames + ["me", "myself", "you", "unknown", "unknown speaker", "speaker", "unidentified"]).map(key))
        var seen = Set<String>()
        return names.compactMap { raw in
            let name = PersonName.display(raw)
            let normalized = key(name)
            guard !name.isEmpty, !excluded.contains(normalized),
                  normalized.range(of: #"^(speaker|spk)[ _-]*\d+$"#, options: .regularExpression) == nil,
                  normalized.range(of: #"^\d+$"#, options: .regularExpression) == nil,
                  seen.insert(normalized).inserted else { return nil }
            return Self(key: normalized, name: name)
        }
    }
}
