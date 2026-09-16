import Foundation
import dBriefWire

enum SpokenSummaryInput {
    static func make(summary: String, actionItems: [String], truncateForAppleIntelligence: Bool) -> String {
        var text = "MEETING SUMMARY:\n\(summary)\n"
        if !actionItems.isEmpty { text += "\nACTION ITEMS:\n" + actionItems.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return truncateForAppleIntelligence ? UnifiedInsightsPrompt.truncateForFoundationModels(text) : text
    }
}
