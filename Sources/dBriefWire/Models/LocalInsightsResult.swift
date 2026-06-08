import Foundation

struct LocalInsightsResult: Codable, Sendable {
    let titleConcept: String
    let summary: String
    let actionItems: [String]
    let tags: [String]
    let sentiment: String

    enum CodingKeys: String, CodingKey {
        case titleConcept = "title_concept"
        case summary
        case actionItems = "action_items"
        case tags
        case sentiment

        // Backward compatibility with previous camelCase payloads.
        case legacyActionItems = "actionItems"
        case legacyTitleConcept = "titleConcept"
    }

    init(
        titleConcept: String = "",
        summary: String,
        actionItems: [String],
        tags: [String],
        sentiment: String
    ) {
        self.titleConcept = titleConcept
        self.summary = summary
        self.actionItems = actionItems
        self.tags = tags
        self.sentiment = sentiment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let newTitleConcept = try container.decodeIfPresent(String.self, forKey: .titleConcept)
        let legacyTitleConcept = try container.decodeIfPresent(String.self, forKey: .legacyTitleConcept)
        self.titleConcept = newTitleConcept ?? legacyTitleConcept ?? ""
        self.summary = try container.decode(String.self, forKey: .summary)
        let newActionItems = try container.decodeIfPresent([String].self, forKey: .actionItems)
        let legacyActionItems = try container.decodeIfPresent([String].self, forKey: .legacyActionItems)
        self.actionItems = newActionItems ?? legacyActionItems ?? []
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.sentiment = try container.decodeIfPresent(String.self, forKey: .sentiment) ?? "Neutral"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(titleConcept, forKey: .titleConcept)
        try container.encode(summary, forKey: .summary)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(tags, forKey: .tags)
        try container.encode(sentiment, forKey: .sentiment)
    }
}
