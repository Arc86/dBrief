import Foundation
import Testing
@testable import dBrief

@Suite("Chat timestamp links")
@MainActor
struct ChatTimestampLinkTests {
    @Test("Timestamps parse to seconds, out-of-range fields are rejected")
    func parsing() {
        #expect(ChatTimestampLink.seconds(from: "00:12:34") == 754)
        #expect(ChatTimestampLink.seconds(from: "1:02:03") == 3723)
        #expect(ChatTimestampLink.seconds(from: "12:34") == 754)
        #expect(ChatTimestampLink.seconds(from: "00:61:00") == nil)
        #expect(ChatTimestampLink.seconds(from: "12") == nil)
        #expect(ChatTimestampLink.seconds(from: "a:bc") == nil)
    }

    @Test("Seek URLs round-trip and ignore other schemes")
    func urls() {
        let url = ChatTimestampLink.url(seconds: 754)
        #expect(ChatTimestampLink.seconds(from: url) == 754)
        #expect(ChatTimestampLink.seconds(from: URL(string: "https://754")!) == nil)
    }

    @Test("Every timestamp in a citation group is found; other brackets are not")
    func citations() {
        let text = "Alice agreed [00:01:05, 00:02:10]. See [notes] and [12:34–13:00]."
        let found = ChatTimestampLink.citations(in: text).map(\.seconds)
        #expect(found == [65, 130, 754, 780])
        #expect(ChatTimestampLink.citations(in: "Version 1.2 at 10:30 [draft]").isEmpty)
    }

    @Test("Rendered chat answers link citations only when asked")
    func rendering() {
        let source = "- Ship it [00:00:42]"
        let linked = MarkdownText.render(source, linksTimestamps: true)
        let links = linked.runs.compactMap(\.link)
        #expect(links == [ChatTimestampLink.url(seconds: 42)])
        #expect(String(linked.characters) == "• Ship it [00:00:42]")
        #expect(MarkdownText.render(source).runs.allSatisfy { $0.link == nil })
    }

    @Test("Follow-up prompts skip questions already asked")
    func followUps() {
        let asked = [ChatMessage(role: .user, content: ChatPromptTemplate.summarize.prompt),
                     ChatMessage(role: .assistant, content: "Done")]
        let titles = ChatPromptTemplate.followUps(after: asked).map(\.title)
        #expect(titles.count == 3)
        #expect(!titles.contains(ChatPromptTemplate.summarize.title))
    }
}
