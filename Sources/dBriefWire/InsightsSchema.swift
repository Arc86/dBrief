import Foundation

/// JSON Schemas for grammar-constrained local generation. Keys mirror the
/// `CodingKeys` of `LocalInsightsResult` / `ChunkNotes` (snake_case on the wire).
public enum InsightsSchema {
    private static let stringArray = #"{"type":"array","items":{"type":"string"}}"#
    private static let sentiment = #"{"type":"string","enum":["Positive","Neutral","Negative"]}"#
    private static let tags = #"{"type":"array","items":{"type":"string"},"maxItems":10}"#

    public static let unified = """
    {"type":"object","properties":{\
    "title_concept":{"type":"string"},"summary":{"type":"string"},\
    "action_items":\(stringArray),"tags":\(tags),"sentiment":\(sentiment)},\
    "required":["title_concept","summary","action_items","tags","sentiment"],\
    "additionalProperties":false}
    """

    /// Final pass of map-reduce: action items are merged deterministically from the
    /// chunk notes (never re-summarized), so the reduce output omits them.
    public static let reduce = """
    {"type":"object","properties":{\
    "title_concept":{"type":"string"},"summary":{"type":"string"},\
    "tags":\(tags),"sentiment":\(sentiment)},\
    "required":["title_concept","summary","tags","sentiment"],\
    "additionalProperties":false}
    """

    /// Property order is generation order (xgrammar keeps declaration order), so the
    /// high-value lists come first and survive a closure at the output cap; the
    /// open-ended key points go last.
    public static let chunkNotes = """
    {"type":"object","properties":{\
    "action_items":\(stringArray),"decisions":\(stringArray),\
    "people":\(stringArray),"key_points":\(stringArray)},\
    "required":["action_items","decisions","people","key_points"],\
    "additionalProperties":false}
    """
}
