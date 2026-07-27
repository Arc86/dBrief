import Foundation

/// Pure, no-I/O filter/group/sort helpers for the Voice Library UI. Unit-tested
/// like `VoiceLibraryDisplay`.
enum VoiceLibraryFilter {
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case lastHeard, name, voiceprintCount
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastHeard: return "Last heard"
            case .name: return "Name"
            case .voiceprintCount: return "Voiceprints"
            }
        }
    }

    struct Group: Identifiable {
        var id: String
        var label: String
        var people: [KnownPerson]
    }

    static let noCompanyLabel = "No company"

    /// Filter by search text (name OR company substring, case-insensitive) and by an
    /// optional set of company labels (empty = all), then sort.
    static func apply(people: [KnownPerson], query: String, companies: Set<String>, sort: Sort) -> [KnownPerson] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = people.filter { person in
            let matchesQuery = q.isEmpty
                || person.name.lowercased().contains(q)
                || (person.company?.lowercased().contains(q) ?? false)
            let matchesCompany = companies.isEmpty || (person.company.map(companies.contains) ?? false)
            return matchesQuery && matchesCompany
        }
        return sorted(filtered, by: sort)
    }

    /// Groups people by company. "No company" bucket always sorts last; other groups
    /// are case-insensitive alphabetical. People within each group keep input order.
    static func grouped(people: [KnownPerson]) -> [Group] {
        var buckets: [String: [KnownPerson]] = [:]
        for person in people {
            let key = person.company?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (key?.isEmpty ?? true) ? noCompanyLabel : key!
            buckets[label, default: []].append(person)
        }
        let named = buckets.keys.filter { $0 != noCompanyLabel }
            .sorted { $0.lowercased() < $1.lowercased() }
        var groups = named.map { Group(id: $0, label: $0, people: buckets[$0]!) }
        if let none = buckets[noCompanyLabel] {
            groups.append(Group(id: noCompanyLabel, label: noCompanyLabel, people: none))
        }
        return groups
    }

    /// Distinct non-nil company labels, case-insensitive sorted.
    static func companies(in people: [KnownPerson]) -> [String] {
        let names = people.compactMap { person -> String? in
            let c = person.company?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (c?.isEmpty ?? true) ? nil : c
        }
        return Array(Set(names)).sorted { $0.lowercased() < $1.lowercased() }
    }

    private static func sorted(_ people: [KnownPerson], by sort: Sort) -> [KnownPerson] {
        switch sort {
        case .lastHeard:
            return people.sorted { a, b in
                switch (VoiceLibraryDisplay.lastSeen(a), VoiceLibraryDisplay.lastSeen(b)) {
                case let (la?, lb?): return la != lb ? la > lb : a.name.lowercased() < b.name.lowercased()
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.name.lowercased() < b.name.lowercased()
                }
            }
        case .name:
            return people.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .voiceprintCount:
            return people.sorted { a, b in
                a.voiceprints.count != b.voiceprints.count
                    ? a.voiceprints.count > b.voiceprints.count
                    : a.name.lowercased() < b.name.lowercased()
            }
        }
    }
}

/// Maps an email domain to a display company name, or nil for consumer/invalid domains.
enum CompanyName {
    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com",
        "proton.me", "protonmail.com", "aol.com", "gmx.com", "gmx.net"
    ]

    /// "acme.com" -> "Acme"; "mail.acme.co.uk" -> "Acme"; consumer/empty/invalid -> nil.
    static func fromDomain(_ domain: String?) -> String? {
        guard let raw = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        guard !consumerDomains.contains(raw) else { return nil }
        let labels = raw.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // Second-level label, skipping a trailing 2-letter ccTLD's public suffix
        // (e.g. co.uk / com.au): if the penultimate label is a known public-suffix
        // second level, take the one before it.
        let publicSecondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov"]
        var idx = labels.count - 2
        if labels.count >= 3, publicSecondLevels.contains(labels[labels.count - 2]) {
            idx = labels.count - 3
        }
        let core = labels[idx]
        guard !core.isEmpty else { return nil }
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}
