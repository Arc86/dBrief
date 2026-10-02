import CryptoKit
import Darwin
import Foundation

struct NemotronWordErrors: Codable, Sendable, Equatable {
    var referenceWords = 0
    var hypothesisWords = 0
    var substitutions = 0
    var deletions = 0
    var insertions = 0
    var wordErrorRate: Double? {
        referenceWords == 0 ? nil : Double(substitutions + deletions + insertions) / Double(referenceWords)
    }
}

enum NemotronReferenceScorer {
    static let normalization = "canonical-unicode-posix-lowercase-letter-mark-number-words-v1"
    static func words(_ text: String) throws -> [String] {
        guard text.utf8.count <= 32768 else { throw NemotronSessionError.invalidConfiguration }
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^\\p{L}\\p{M}\\p{N}]+", with: " ", options: .regularExpression)
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count <= 512 else { throw NemotronSessionError.invalidConfiguration }
        return words
    }
    static func score(reference: [String], hypothesis: [String]) throws -> NemotronWordErrors {
        guard reference.count <= 256, hypothesis.count <= 512 else { throw NemotronSessionError.invalidConfiguration }
        // Two rows bound memory. Ties prefer diagonal, then deletion, then insertion.
        var previous = (0...hypothesis.count).map { Edits(insertions: $0) }
        for word in reference {
            var first = previous[0]; first.deletions += 1
            var row = [first]
            for (index, recognized) in hypothesis.enumerated() {
                var best = previous[index]
                if word != recognized { best.substitutions += 1 }
                var deletion = previous[index + 1]; deletion.deletions += 1
                var insertion = row[index]; insertion.insertions += 1
                if deletion.total < best.total { best = deletion }
                if insertion.total < best.total { best = insertion }
                row.append(best)
            }
            previous = row
        }
        let edits = previous[hypothesis.count]
        return .init(referenceWords: reference.count, hypothesisWords: hypothesis.count,
            substitutions: edits.substitutions, deletions: edits.deletions, insertions: edits.insertions)
    }
    private struct Edits {
        var substitutions = 0, deletions = 0, insertions = 0
        var total: Int { substitutions + deletions + insertions }
    }
}

struct NemotronReferenceUtterance: Sendable {
    let range: Range<Int64>
    let words: [String]
}

struct NemotronReferenceSet: Sendable {
    let sha256: String
    let fixtures: [String: [NemotronReferenceUtterance]]
    private struct Document: Decodable {
        struct Fixture: Decodable {
            struct Utterance: Decodable { let endSample: Int64; let text: String }
            let id: String
            let utterances: [Utterance]
        }
        let schemaVersion: Int
        let fixtures: [Fixture]
    }
    static func load(at url: URL, manifest: NemotronFixtureManifest) throws -> Self {
        // NONBLOCK lets us reject pipes/devices without waiting for a producer.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw NemotronSessionError.invalidConfiguration }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1_048_576 else { throw NemotronSessionError.invalidConfiguration }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw NemotronSessionError.invalidConfiguration }
        let document = try JSONDecoder().decode(Document.self, from: data)
        let ids = document.fixtures.map(\.id)
        guard document.schemaVersion == 1, Set(ids).count == ids.count,
              Set(ids) == Set(manifest.fixtures.map(\.id)) else { throw NemotronSessionError.invalidConfiguration }
        let byID = Dictionary(uniqueKeysWithValues: document.fixtures.map { ($0.id, $0) })
        var normalized: [String: [NemotronReferenceUtterance]] = [:]
        for fixture in manifest.fixtures {
            let references = byID[fixture.id]!.utterances
            guard references.map(\.endSample) == fixture.utteranceEnds else { throw NemotronSessionError.invalidConfiguration }
            var start: Int64 = 0, values: [NemotronReferenceUtterance] = []
            for reference in references {
                let words = try NemotronReferenceScorer.words(reference.text)
                guard words.count <= 256, reference.endSample > start else { throw NemotronSessionError.invalidConfiguration }
                values.append(.init(range: start..<reference.endSample, words: words))
                start = reference.endSample
            }
            normalized[fixture.id] = values
        }
        return .init(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fixtures: normalized)
    }
}

struct NemotronReferenceScore: Codable, Sendable {
    let normalization: String
    let status: String
    let expectedUtterances: Int
    let scoredUtterances: Int
    let plannedReferenceWords: Int
    let unscoredReferenceWords: Int
    let unscoredCommittedUtterances: Int
    let errors: NemotronWordErrors
    let wordErrorRate: Double?
    var editScoringMs: Double = 0
}

struct NemotronReferenceAccumulator: Sendable {
    let references: [NemotronReferenceUtterance]
    private var hypotheses: [Range<Int64>: [String]] = [:]
    private var retainedWords = 0, retainedBytes = 0, unscoredCommits = 0
    init(references: [NemotronReferenceUtterance]) { self.references = references }
    mutating func record(_ utterance: NemotronCommittedUtterance) {
        // Content is private in-memory scoring input, never Codable/report data.
        guard hypotheses[utterance.range] == nil,
              let words = try? NemotronReferenceScorer.words(utterance.output.text) else {
            unscoredCommits += 1; return
        }
        let bytes = words.reduce(0) { $0 + $1.utf8.count }
        guard retainedWords + words.count <= 100000, retainedBytes + bytes <= 4_194_304 else {
            unscoredCommits += 1; return
        }
        hypotheses[utterance.range] = words
        retainedWords += words.count; retainedBytes += bytes
    }
    func result(runCompleted: Bool) -> NemotronReferenceScore {
        var errors = NemotronWordErrors(), scored = 0, failures = unscoredCommits
        for reference in references {
            guard let hypothesis = hypotheses[reference.range] else { continue }
            guard let value = try? NemotronReferenceScorer.score(reference: reference.words, hypothesis: hypothesis) else {
                failures += 1; continue
            }
            errors.referenceWords += value.referenceWords; errors.hypothesisWords += value.hypothesisWords
            errors.substitutions += value.substitutions; errors.deletions += value.deletions; errors.insertions += value.insertions
            scored += 1
        }
        let ranges = Set(references.map(\.range))
        failures += hypotheses.keys.filter { !ranges.contains($0) }.count
        let complete = runCompleted && scored == references.count && failures == 0
        let plannedWords = references.reduce(0) { $0 + $1.words.count }
        return .init(normalization: NemotronReferenceScorer.normalization, status: complete ? "complete" : "incomplete",
            expectedUtterances: references.count, scoredUtterances: scored, plannedReferenceWords: plannedWords,
            unscoredReferenceWords: plannedWords - errors.referenceWords, unscoredCommittedUtterances: failures,
            errors: errors, wordErrorRate: complete ? errors.wordErrorRate : nil)
    }
}
