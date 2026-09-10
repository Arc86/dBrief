import Foundation

/// Keeps unfinished changes separate from the saved vocabulary.
struct VocabularyEditing {
    private struct Source {
        let terms: [String]
        let index: Int
        var term: String { terms[index] }
    }

    private var source: Source?
    var text = ""
    private(set) var error: String?
    var originalTerm: String? { source?.term }
    var isEditing: Bool { source != nil }

    mutating func begin(at index: Int, in terms: [String]) {
        guard !isEditing, terms.indices.contains(index) else { return }
        source = Source(terms: terms, index: index)
        text = terms[index]
        error = nil
    }

    mutating func cancel() {
        source = nil
        text = ""
        error = nil
    }

    mutating func save(in terms: inout [String]) {
        guard let source else { return }
        let index: Int
        if source.terms == terms {
            index = source.index
        } else {
            let matches = terms.indices.filter { terms[$0] == source.term }
            guard matches.count == 1 else {
                error = "This term changed or was removed. Cancel and choose the term again."
                return
            }
            index = matches[0]
        }
        switch Self.validate(text, in: terms, excluding: index) {
        case .success(let term):
            terms[index] = term
            cancel()
        case .failure(let failure):
            error = failure.message
        }
    }

    enum ValidationError: Error {
        case empty, duplicate

        var message: String {
            switch self {
            case .empty: "Enter a term before saving."
            case .duplicate: "This term is already in your vocabulary."
            }
        }
    }

    static func validate(_ text: String, in terms: [String], excluding index: Int? = nil) -> Result<String, ValidationError> {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .failure(.empty) }
        guard !terms.enumerated().contains(where: { offset, existing in
            offset != index && existing.caseInsensitiveCompare(term) == .orderedSame
        }) else { return .failure(.duplicate) }
        return .success(term)
    }
}
