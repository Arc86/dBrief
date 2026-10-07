import Testing
import Foundation
@testable import dBrief
import dBriefWire

@Suite struct ChatContextPlannerTests {
    @Test func historyDropsPlaceholderAndCurrentQuestion() {
        let h = ChatContextPlanner.history(from: [
            (.user, "Q1"), (.assistant, "A1"), (.user, "Q2"), (.assistant, ""),
        ])
        #expect(h == [.init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1")])
    }

    @Test func historyDropsUnansweredUserTurns() {
        // A stopped request leaves a user message with an empty answer that was removed.
        let h = ChatContextPlanner.history(from: [(.user, "Q1"), (.user, "Q2"), (.assistant, "A2"), (.user, "Q3")])
        #expect(h == [.init(role: .user, content: "Q2"), .init(role: .assistant, content: "A2")])
    }

    /// Mirrors `TranscriptChatService.sendInRecordingContext`: after appending the
    /// current user message and the empty assistant placeholder, `dropLast(2)` is
    /// applied before deriving history. (Tested on the pure function: the service
    /// needs a live model to run.)
    @Test func historyAsServiceDerivesIt() {
        let messages: [(role: ChatTurnMessage.Role, content: String)] = [
            (.user, "Q1"), (.assistant, "A1"), (.user, "Q2"), (.assistant, "A2"),
            (.user, "Q3"), (.assistant, ""),
        ]
        let h = ChatContextPlanner.history(from: Array(messages.dropLast(2)))
        #expect(h == [
            .init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1"),
            .init(role: .user, content: "Q2"), .init(role: .assistant, content: "A2"),
        ])
        // First turn: nothing precedes the question.
        #expect(ChatContextPlanner.history(from: Array(messages.prefix(2).dropLast(2))).isEmpty)
    }

    // MARK: - Whole-recording scan

    @Test func scanPartPromptAsksForEvidenceOrNone() {
        let p = ChatContextPlanner.scanPartPrompt(question: "List all decisions",
            part: TranscriptChunk(index: 2, total: 4, text: "[00:30:00] A: we decided X"))
        #expect(p.user.contains("PART 2 OF 4") && p.user.contains("List all decisions"))
        #expect(p.system.contains("NONE"))
    }

    @Test func noneFindingsAreRecognized() {
        #expect(ChatContextPlanner.isNoneFinding(" none. "))
        #expect(!ChatContextPlanner.isNoneFinding("[00:30:00] decided X"))
    }

    @Test func noneDetectionIgnoresCaseAndPunctuation() {
        for text in ["NONE", "None", "none", "NONE.", "**None**", "\"none\"", "  None!\n", "(none)", "nOnE..."] {
            #expect(ChatContextPlanner.isNoneFinding(text), "\(text) should count as NONE")
        }
        for text in ["", "None of them agreed", "Nonetheless X", "No one", "NONE: but [00:01:00] X"] {
            #expect(!ChatContextPlanner.isNoneFinding(text), "\(text) should not count as NONE")
        }
    }

    @Test func findingsFitInOneGroupOnGemma() {
        let parts = (1...3).map { TranscriptChunk(index: $0, total: 3, text: "") }
        let prompts = ChatContextPlanner.scanFinalPrompts(question: "Q", findings: parts.map { ($0, "finding \($0.index)") },
                                                          budget: 16_000, countTokens: ChatEngineProfile.estimateTokens)
        #expect(prompts.count == 1 && prompts[0].label.isEmpty)
        #expect(prompts[0].user.range(of: "finding 1")!.lowerBound < prompts[0].user.range(of: "finding 3")!.lowerBound)
    }

    @Test func findingsSplitIntoGroupsWithoutLosingAnyOnSmallBudget() {
        let parts = (1...12).map { TranscriptChunk(index: $0, total: 12, text: "") }
        let findings = parts.map { ($0, "[00:\(10 + $0.index):00] " + String(repeating: "evidence ", count: 60) + "F\($0.index)") }
        let prompts = ChatContextPlanner.scanFinalPrompts(question: "Q", findings: findings,
                                                          budget: 600, countTokens: ChatEngineProfile.estimateTokens)
        #expect(prompts.count > 1)
        #expect(prompts.allSatisfy { ChatEngineProfile.estimateTokens($0.system + $0.user) <= 600 })
        for i in 1...12 { #expect(prompts.contains { $0.user.contains("F\(i)") }, "finding \(i) lost") }
        #expect(prompts.first!.label.hasPrefix("Parts 1–"))
    }

    /// Every finding lands in exactly one group, in order, with its full text intact.
    @Test func everyFindingAppearsInSomeGroup() {
        for budget in [400, 700, 1_500, 16_000] {
            let parts = (1...20).map { TranscriptChunk(index: $0, total: 20, text: "") }
            let findings = parts.map { ($0, "[01:\(10 + $0.index):00] owner-\($0.index) " + String(repeating: "x ", count: 20 * $0.index % 90)) }
            let prompts = ChatContextPlanner.scanFinalPrompts(question: "Who owns what?", findings: findings,
                                                              budget: budget, countTokens: ChatEngineProfile.estimateTokens)
            for (part, text) in findings {
                let holders = prompts.filter { $0.user.contains(text) }
                #expect(holders.count == 1, "budget \(budget): part \(part.index) appears in \(holders.count) groups")
            }
            let order = prompts.flatMap { p in findings.filter { p.user.contains($0.1) }.map { $0.0.index } }
            #expect(order == Array(1...20), "budget \(budget): findings out of order")
        }
    }

    @Test func noFindingsStillProducesOnePrompt() {
        let prompts = ChatContextPlanner.scanFinalPrompts(question: "Q", findings: [],
                                                          budget: 600, countTokens: ChatEngineProfile.estimateTokens)
        #expect(prompts.count == 1 && prompts[0].user.contains("no relevant evidence found"))
    }

    /// An oversized multi-line finding is split on line boundaries before grouping:
    /// every line survives, in order, and no prompt exceeds the budget.
    @Test func oversizedFindingIsSplitNotClipped() {
        let lines = (1...40).map { String(format: "[00:%02d:00] Owner L%02d agreed to deliver item ", $0, $0) + String(repeating: "z", count: 30) }
        let part = TranscriptChunk(index: 3, total: 9, text: "")
        let report = ChatContextPlanner.scanFinalPromptsReport(question: "Who owns what?", findings: [(part, lines.joined(separator: "\n"))],
                                                               budget: 500, countTokens: ChatEngineProfile.estimateTokens)
        #expect(report.prompts.count > 1)
        #expect(!report.clipped)
        #expect(report.prompts.allSatisfy { ChatEngineProfile.estimateTokens($0.system + $0.user) <= 500 })
        let joined = report.prompts.map(\.user).joined(separator: "\n")
        var cursor = joined.startIndex
        for line in lines {
            guard let r = joined.range(of: line, range: cursor..<joined.endIndex) else {
                Issue.record("line lost or out of order: \(line.prefix(16))"); return
            }
            cursor = r.upperBound
        }
        #expect(report.prompts.allSatisfy { $0.label == "Part 3" })
    }

    /// Only a single unsplittable line may still be clipped, and that is reported.
    @Test func unsplittableLineIsClippedAndReported() {
        let part = TranscriptChunk(index: 1, total: 2, text: "")
        let report = ChatContextPlanner.scanFinalPromptsReport(question: "Q", findings: [(part, String(repeating: "x", count: 5_000))],
                                                               budget: 400, countTokens: ChatEngineProfile.estimateTokens)
        #expect(report.clipped)
        #expect(report.prompts.allSatisfy { ChatEngineProfile.estimateTokens($0.system + $0.user) <= 400 })
        let fits = ChatContextPlanner.scanFinalPromptsReport(question: "Q", findings: [(part, "[00:01:00] short")],
                                                             budget: 400, countTokens: ChatEngineProfile.estimateTokens)
        #expect(!fits.clipped)
    }

    @Test func groupLabelsNameSinglePartsAndRanges() {
        let parts = (1...3).map { TranscriptChunk(index: $0, total: 3, text: "") }
        let findings = parts.map { ($0, String(repeating: "evidence ", count: 50) + "F\($0.index)") }
        let prompts = ChatContextPlanner.scanFinalPrompts(question: "Q", findings: findings,
                                                          budget: 250, countTokens: ChatEngineProfile.estimateTokens)
        #expect(prompts.map(\.label) == ["Part 1", "Part 2", "Part 3"])
    }

    /// Mirrors `TranscriptChatService.priorHistory`: a stopped scan and an error reply
    /// are not answers, so neither pair reaches the model's history.
    @Test @MainActor func stoppedScanAndErrorRepliesAreNotModelHistory() {
        let messages: [ChatMessage] = [
            .init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1"),
            .init(role: .user, content: "List every owner"),
            .init(role: .assistant, content: TranscriptChatService.scanStoppedNote),
            .init(role: .user, content: "Q3"), .init(role: .assistant, content: "Error: helper crashed"),
            .init(role: .user, content: "Q4"), .init(role: .assistant, content: "A4"),
            .init(role: .user, content: "Q5"), .init(role: .assistant, content: ""), // in flight
        ]
        let h = TranscriptChatService.modelHistory(from: Array(messages.dropLast(2)))
        #expect(h == [
            .init(role: .user, content: "Q1"), .init(role: .assistant, content: "A1"),
            .init(role: .user, content: "Q4"), .init(role: .assistant, content: "A4"),
        ])
    }
}
