import Testing
@testable import dBrief

@Suite struct AppleChatBackendTests {
    struct Overflow: Error {}
    struct Other: Error {}
    let isOverflow: (Error) -> Bool = { $0 is Overflow }

    @Test func overflowOnFirstAttemptRetriesShrunkOnce() {
        #expect(AppleChatAttempt.next(after: Overflow(), attempt: .first, isOverflow: isOverflow) == .retryShrunk)
        #expect(AppleChatAttempt.next(after: Overflow(), attempt: .retryShrunk, isOverflow: isOverflow) == nil)
    }

    @Test func otherErrorsDoNotRetry() {
        #expect(AppleChatAttempt.next(after: Other(), attempt: .first, isOverflow: isOverflow) == nil)
    }

    @Test func overflowMessagePointsToFullScan() {
        #expect(AppleChatAttempt.overflowMessage.contains("Check the whole recording"))
    }

    /// Live chat (and the scan's own errors) has no scan button to point to.
    @Test func overflowMessageWithoutScanDoesNotMentionIt() {
        #expect(!AppleChatAttempt.overflowMessage(canScan: false).contains("Check the whole recording"))
        #expect(AppleChatAttempt.overflowMessage(canScan: true) == AppleChatAttempt.overflowMessage)
    }
}

@Suite struct AppleChatContextTests {
    let count: (String) -> Int = { $0.count }

    @Test func shortTranscriptIsKeptWhole() {
        let text = "[00:00:01] A: hi\n[00:00:02] B: hello"
        #expect(AppleChatContext.recentTail(text, budgetTokens: 1_000, countTokens: count) == text)
    }

    @Test func longTranscriptKeepsTheMostRecentWholeLines() {
        let lines = (0..<50).map { "[00:00:\(String(format: "%02d", $0))] A: line \($0)" }
        let tail = AppleChatContext.recentTail(lines.joined(separator: "\n"), budgetTokens: 100, countTokens: count)
        #expect(count(tail) <= 100)
        #expect(tail.hasSuffix(lines[49]))
        #expect(!tail.contains(lines[0]))
        #expect(tail.split(separator: "\n").allSatisfy { lines.contains(String($0)) })
    }

    @Test func oversizedLastLineIsCutFromTheFront() {
        let tail = AppleChatContext.recentTail("short\n" + String(repeating: "x", count: 500) + "END",
                                               budgetTokens: 50, countTokens: count)
        #expect(count(tail) <= 50)
        #expect(tail.hasSuffix("END"))
    }
}

#if canImport(FoundationModels)
import Foundation
import dBriefWire

/// Real on-device call through the long-mode prompt shape. Opt-in only:
/// `DBRIEF_APPLE_CHAT_SMOKE=1 swift test --filter AppleChatSmokeTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_APPLE_CHAT_SMOKE"] == "1"))
struct AppleChatSmokeTests {
    @Test func longModeQuestionGetsAnAnswer() async throws {
        guard #available(macOS 26, *) else { return }
        let profile = AppleChatBackend.profile
        #expect(profile.fullTranscriptTokens > 0)
        let instructions = ChatContextPlanner.longModeSystemPrompt(
            overview: "MEETING SUMMARY:\nThe team agreed to ship the beta on Friday.", speakerLegend: "- S1: Alice")
        let prompt = ChatContextPlanner.freshSessionPrompt(
            history: "", excerpts: "[00:31:05] Alice: Let's ship the beta on Friday, after QA signs off.",
            question: "When does the beta ship?")
        #expect(await AppleChatBackend.tokenCount(instructions + prompt) > 0)
        let answer = try await AppleChatBackend.respond(instructions: instructions, prompt: prompt)
        print("Apple chat smoke answer: \(answer)")
        #expect(!answer.isEmpty)
    }
}
#endif
