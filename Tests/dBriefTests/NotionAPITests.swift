import Foundation
import Testing
@testable import dBrief

@Suite("Notion page content and requests")
struct NotionAPITests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13 UTC
    private let locale = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func bundle(summary: String? = "First point.\n\n- one\n- two", actions: [String] = ["Send deck", " "],
                        tags: [String] = ["q3", "sales"], transcript: String? = "Alice: hi\nBob: hello",
                        attendees: [String] = []) -> IntegrationContentBundle {
        IntegrationContentBundle(title: "Weekly sync", createdAt: date, durationSeconds: 3_725,
            audioFileURL: URL(fileURLWithPath: "/tmp/a.m4a"), transcript: transcript, summary: summary,
            actionItems: actions, tags: tags, sentiment: "Positive", markdown: "# ignored",
            calendarEvent: attendees.isEmpty ? nil : CalendarEvent(title: "Weekly sync",
                attendees: attendees.map { CalendarEvent.Person(name: $0, email: nil) }, body: "",
                startDate: date, endDate: date.addingTimeInterval(3600)))
    }

    private func types(_ blocks: [[String: Any]]) -> [String] { blocks.compactMap { $0["type"] as? String } }
    private func text(_ block: [String: Any]) -> String {
        let type = block["type"] as? String ?? ""
        let rich = (block[type] as? [String: Any])?["rich_text"] as? [[String: Any]] ?? []
        return rich.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
    }

    @Test func blocksFollowTheChosenFieldsInOrder() {
        let blocks = NotionAPI.blocks(for: bundle(attendees: ["Alice", "Bob"]),
            fields: [.summary, .actionItems, .tags, .sentiment, .transcript, .meetingInfo, .markdown],
            reference: "1a2b3c4d", locale: locale, timeZone: utc)
        #expect(types(blocks) == ["paragraph", "paragraph",
                                  "heading_2", "paragraph", "bulleted_list_item", "bulleted_list_item",
                                  "heading_2", "to_do",
                                  "heading_2", "paragraph",
                                  "heading_2", "paragraph",
                                  "heading_2", "paragraph"])
        #expect(text(blocks[0]) == "Sep 21, 2026 · 1 h 2 min — added by dBrief (ref 1a2b3c4d)")
        #expect(text(blocks[1]) == "Participants: Alice, Bob")
        #expect(text(blocks[4]) == "one")
        #expect(text(blocks[7]) == "Send deck")
        #expect((blocks[7]["to_do"] as? [String: Any])?["checked"] as? Bool == false)
        #expect(text(blocks[9]) == "q3, sales")
    }

    @Test func unselectedFieldsAreLeftOutButTheHeaderStays() {
        let blocks = NotionAPI.blocks(for: bundle(), fields: [.actionItems], reference: "r", locale: locale, timeZone: utc)
        #expect(types(blocks) == ["paragraph", "heading_2", "to_do"])
    }

    @Test func longTextIsSplitWithinNotionsLimit() {
        let line = String(repeating: "word ", count: 120) // 600 chars
        let transcript = Array(repeating: line, count: 10).joined(separator: "\n") + "\n" + String(repeating: "x", count: 4500)
        let blocks = NotionAPI.blocks(for: bundle(summary: nil, actions: [], tags: [], transcript: transcript),
                                      fields: [.transcript], reference: "r", locale: locale, timeZone: utc)
        let paragraphs = blocks.dropFirst(2).map(text)
        #expect(paragraphs.allSatisfy { $0.count <= NotionAPI.maxTextLength })
        #expect(paragraphs.joined().filter { !$0.isWhitespace } == transcript.filter { !$0.isWhitespace })
        // 3 + 3 + 3 + 1 lines of 600 chars, then the 4,500-char line cut into 2,000 + 2,000 + 500.
        #expect(paragraphs.count == 7)
    }

    @Test func pagePropertiesForAPageParentUseTheTitleKey() throws {
        let properties = NotionAPI.properties(title: "Weekly sync", schema: nil, date: date, tags: ["q3"])
        let title = try #require(properties["title"] as? [String: Any])
        #expect(((title["title"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String == "Weekly sync")
        #expect(properties.count == 1)
    }

    @Test func databasePropertiesFillTitleDateAndTags() throws {
        let schema = NotionSchema(titleProperty: "Meeting", dateProperty: "When", tagsProperty: "Tags")
        let properties = NotionAPI.properties(title: "Weekly sync", schema: schema, date: date,
                                              tags: ["q3, planning", " ", String(repeating: "t", count: 120)])
        #expect(properties["Meeting"] != nil)
        let start = (properties["When"] as? [String: Any]).flatMap { ($0["date"] as? [String: Any])?["start"] as? String }
        #expect(start == "2026-09-21T14:13:20Z")
        let names = ((properties["Tags"] as? [String: Any])?["multi_select"] as? [[String: String]])?.compactMap { $0["name"] }
        #expect(names == ["q3 planning", String(repeating: "t", count: 100)])
    }

    @Test func schemaPrefersNamedDateAndTagsColumns() throws {
        let data = Data(#"""
        {"object":"data_source","id":"ds","title":[{"plain_text":"Meetings"}],
         "properties":{"Name":{"type":"title"},"Created":{"type":"date"},"Date":{"type":"date"},
                       "Topics":{"type":"multi_select"},"Tags":{"type":"multi_select"},"Notes":{"type":"rich_text"}}}
        """#.utf8)
        #expect(try NotionAPI.parseSchema(data) == NotionSchema(titleProperty: "Name", dateProperty: "Date", tagsProperty: "Tags"))
        let single = Data(#"{"properties":{"Task":{"type":"title"},"Due":{"type":"date"},"Labels":{"type":"multi_select"}}}"#.utf8)
        #expect(try NotionAPI.parseSchema(single) == NotionSchema(titleProperty: "Task", dateProperty: "Due", tagsProperty: "Labels"))
        let bare = Data(#"{"properties":{"Title":{"type":"title"},"A":{"type":"date"},"B":{"type":"date"}}}"#.utf8)
        #expect(try NotionAPI.parseSchema(bare) == NotionSchema(titleProperty: "Title", dateProperty: nil, tagsProperty: nil))
        #expect(throws: NotionError.invalidResponse) { try NotionAPI.parseSchema(Data(#"{"properties":{}}"#.utf8)) }
    }

    @Test func searchResultsBecomeLabelledDestinations() throws {
        let data = Data(#"""
        {"results":[
          {"object":"page","id":"p1","parent":{"type":"workspace"},"properties":{"title":{"type":"title","title":[{"plain_text":"Team "},{"plain_text":"notes"}]}}},
          {"object":"data_source","id":"d1","title":[{"plain_text":"Meetings"}]},
          {"object":"page","id":"p2","parent":{"type":"data_source_id"},"properties":{"Name":{"type":"title","title":[{"plain_text":"A row"}]}}},
          {"object":"page","id":"p3","in_trash":true,"properties":{"title":{"type":"title","title":[{"plain_text":"Old"}]}}}
        ],"has_more":true,"next_cursor":"c2"}
        """#.utf8)
        let page = try NotionAPI.parseSearch(data)
        #expect(page.destinations == [NotionDestination(kind: .page, id: "p1", name: "Team notes"),
                                      NotionDestination(kind: .dataSource, id: "d1", name: "Meetings")])
        #expect(page.nextCursor == "c2")
    }

    @Test func requestsCarryVersionAndBearer() throws {
        let request = try NotionAPI.request("v1/pages", token: "secret", method: "POST", body: ["a": 1])
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/pages")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}
