import Foundation
import Testing
import dBriefWire
@testable import dBrief

@MainActor
struct TranscriptSpellingParsingTests {
    @Test("parses a bare JSON array")
    func bareArray() {
        let raw = #"[{"from":"service now","to":"ServiceNow"}]"#
        let out = TranscriptSpellingService.parseCorrections(raw)
        #expect(out == [SpellingCorrection(from: "service now", to: "ServiceNow")])
    }

    @Test("extracts the array from prose and code fences")
    func wrappedArray() {
        let raw = """
        Sure! Here are the corrections:
        ```json
        [
          {"from": "itsm", "to": "ITSM"},
          {"from": "service now", "to": "ServiceNow"}
        ]
        ```
        Let me know if you need more.
        """
        let out = TranscriptSpellingService.parseCorrections(raw)
        #expect(out.count == 2)
        #expect(out.first == SpellingCorrection(from: "itsm", to: "ITSM"))
    }

    @Test("empty array and malformed output yield no corrections")
    func emptyAndMalformed() {
        #expect(TranscriptSpellingService.parseCorrections("[]").isEmpty)
        #expect(TranscriptSpellingService.parseCorrections("no json here").isEmpty)
        #expect(TranscriptSpellingService.parseCorrections("").isEmpty)
    }

    @Test("vocabulary terms split on commas, semicolons, and newlines")
    func vocabSplitting() {
        let terms = TranscriptSpellingService.vocabularyTerms(from: "ServiceNow, ITSM;\n Kubernetes ")
        #expect(terms == ["ServiceNow", "ITSM", "Kubernetes"])
    }
}
