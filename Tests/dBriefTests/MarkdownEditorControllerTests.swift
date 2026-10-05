import Foundation
import Testing
@testable import dBrief

/// Loads the real committed bundle in a WKWebView: proves the file URL, CSP,
/// script bridge and JSON transport all work end to end.
@MainActor
@Suite("Markdown editor WebKit host", .serialized)
struct MarkdownEditorControllerTests {
    private func firstLoaded(from controller: MarkdownEditorController) async -> String? {
        let (stream, continuation) = AsyncStream.makeStream(of: MarkdownEditorMessage.self)
        controller.onMessage = { continuation.yield($0) }
        for await message in stream {
            if case .loaded(let markdown) = message { return markdown }
        }
        return nil
    }

    @Test("Bundled page loads and echoes hostile markdown intact", .timeLimit(.minutes(1)))
    func roundTrip() async throws {
        let index = try #require(MarkdownEditorResources.indexURL(in: MarkdownEditorSourceBundle.resources))
        let markdown = "Overview\nQuote \" back\\slash </script> emoji 🎙️ één.\n\n* punt"
        let controller = MarkdownEditorController(indexURL: index, markdown: markdown)
        defer { controller.tearDown() }

        let loaded = try #require(await firstLoaded(from: controller))
        for fragment in ["Overview", "Quote", "slash", "script", "🎙️", "één", "punt"] {
            #expect(loaded.contains(fragment), "missing \(fragment) in \(loaded)")
        }
    }

    @Test("A web content crash reloads and restores the latest text", .timeLimit(.minutes(1)))
    func recoversFromCrash() async throws {
        let index = try #require(MarkdownEditorResources.indexURL(in: MarkdownEditorSourceBundle.resources))
        let controller = MarkdownEditorController(indexURL: index, markdown: "Eerste versie")
        defer { controller.tearDown() }
        _ = try #require(await firstLoaded(from: controller))

        controller.simulateWebContentCrashForTesting()
        let reloaded = try #require(await firstLoaded(from: controller))
        #expect(reloaded.contains("Eerste versie"))
    }
}
