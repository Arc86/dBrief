import Foundation
import dBriefWire
import Testing

struct VocabularyCorrectionTests {
    private func result(_ text: String, segments: [TranscriptionResult.Segment]) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: segments)
    }
    private func seg(_ text: String, _ start: Double, _ end: Double, words: [TranscriptionResult.Word]? = nil) -> TranscriptionResult.Segment {
        TranscriptionResult.Segment(start: start, end: end, text: text, words: words)
    }
    private func word(_ w: String, _ s: Double, _ e: Double) -> TranscriptionResult.Word {
        TranscriptionResult.Word(word: w, start: s, end: e)
    }

    @Test("corrects casing/spacing across text, segments, and words")
    func correctsEverywhere() {
        let input = result(
            "We logged it in service now today.",
            segments: [seg("We logged it in service now today.", 0, 3,
                           words: [word("service", 1, 1.5), word("now", 1.5, 2)])]
        )
        let out = VocabularyCorrection.apply(
            [SpellingCorrection(from: "service now", to: "ServiceNow")],
            vocabulary: ["ServiceNow", "ITSM"],
            to: input
        )
        #expect(out.text == "We logged it in ServiceNow today.")
        #expect(out.segments[0].text == "We logged it in ServiceNow today.")
    }

    @Test("corrects single-token word entries")
    func correctsWordTokens() {
        let input = result(
            "itsm process",
            segments: [seg("itsm process", 0, 2, words: [word("itsm", 0, 1), word("process", 1, 2)])]
        )
        let out = VocabularyCorrection.apply(
            [SpellingCorrection(from: "itsm", to: "ITSM")],
            vocabulary: ["ITSM"],
            to: input
        )
        #expect(out.text == "ITSM process")
        #expect(out.segments[0].words?.first?.word == "ITSM")
    }

    @Test("ignores corrections whose target is not a vocabulary term")
    func rejectsNonVocabTarget() {
        let input = result("the meeting was great", segments: [seg("the meeting was great", 0, 2)])
        let out = VocabularyCorrection.apply(
            [SpellingCorrection(from: "great", to: "terrible")],  // not in vocab — must be ignored
            vocabulary: ["ServiceNow"],
            to: input
        )
        #expect(out.text == "the meeting was great")
    }

    @Test("does not touch unrelated text")
    func preservesUnrelatedText() {
        let input = result("kubernetes and the weather", segments: [seg("kubernetes and the weather", 0, 2)])
        let out = VocabularyCorrection.apply(
            [SpellingCorrection(from: "kubernetes", to: "Kubernetes")],
            vocabulary: ["Kubernetes"],
            to: input
        )
        #expect(out.text == "Kubernetes and the weather")
    }

    @Test("whole-word matching does not corrupt substrings")
    func wholeWordOnly() {
        // "it" must not be replaced inside "itinerary".
        let input = result("the itinerary", segments: [seg("the itinerary", 0, 2)])
        let out = VocabularyCorrection.apply(
            [SpellingCorrection(from: "it", to: "IT")],
            vocabulary: ["IT"],
            to: input
        )
        #expect(out.text == "the itinerary")
    }

    @Test("empty corrections or vocabulary leaves the transcript unchanged")
    func noOpCases() {
        let input = result("hello world", segments: [seg("hello world", 0, 1)])
        #expect(VocabularyCorrection.apply([], vocabulary: ["X"], to: input).text == "hello world")
        #expect(VocabularyCorrection.apply([SpellingCorrection(from: "hello", to: "Hello")], vocabulary: [], to: input).text == "hello world")
    }
}
