import Foundation
import Testing
import dBriefWire

@Suite struct InsightsSchemaTests {
    private func object(_ s: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    @Test func unifiedSchemaMatchesLocalInsightsResultKeys() throws {
        let schema = try object(InsightsSchema.unified)
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["title_concept", "summary", "action_items", "tags", "sentiment"])
        let props = try #require(schema["properties"] as? [String: Any])
        let sentiment = try #require(props["sentiment"] as? [String: Any])
        #expect(sentiment["enum"] as? [String] == ["Positive", "Neutral", "Negative"])
        let tags = try #require(props["tags"] as? [String: Any])
        #expect(tags["maxItems"] as? Int == 10)
    }

    @Test func schemaValidOutputDecodesAsLocalInsightsResult() throws {
        let sample = #"{"title_concept":"T","summary":"S\n- a","action_items":["[A] to x"],"tags":["t"],"sentiment":"Neutral"}"#
        let result = try LocalInsightsDecoder.decodeAndNormalize(sample)
        #expect(result.summary == "S\n- a")
    }

    @Test func reduceSchemaHasNoActionItems() throws {
        let props = try #require(try object(InsightsSchema.reduce)["properties"] as? [String: Any])
        #expect(props["action_items"] == nil)
        #expect(props["summary"] != nil && props["title_concept"] != nil)
    }

    @Test func chunkNotesSchemaKeys() throws {
        let required = try #require(try object(InsightsSchema.chunkNotes)["required"] as? [String])
        #expect(required == ["action_items", "decisions", "people", "key_points"])
    }

    /// xgrammar emits properties in declaration order (ordered picojson keys), so the
    /// high-value lists come first and survive a closure at the output cap.
    @Test func chunkNotesSchemaDeclaresHighValueListsFirst() throws {
        let schema = InsightsSchema.chunkNotes
        let positions = try ["\"action_items\":", "\"decisions\":", "\"people\":", "\"key_points\":"].map {
            try #require(schema.range(of: $0)).lowerBound
        }
        #expect(positions == positions.sorted())
    }
}
