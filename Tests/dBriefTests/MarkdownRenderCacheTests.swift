import SwiftUI
import Testing
@testable import dBrief

@Suite(.serialized) @MainActor struct MarkdownRenderCacheTests {
    @Test func sameTextIsParsedOnce() {
        let cache = MarkdownRenderCache(limit: 8)
        let first = cache.rendered("# Title\n- one\n- two", readingFont: nil)
        for _ in 0..<50 { _ = cache.rendered("# Title\n- one\n- two", readingFont: nil) }
        #expect(cache.renderCount == 1)
        #expect(first == MarkdownText.render("# Title\n- one\n- two"))
    }

    @Test func differentTextOrFontRendersAgain() {
        let cache = MarkdownRenderCache(limit: 8)
        _ = cache.rendered("a", readingFont: nil)
        _ = cache.rendered("b", readingFont: nil)
        _ = cache.rendered("a", readingFont: .body)
        #expect(cache.renderCount == 3)
    }

    @Test func cacheIsBounded() {
        let cache = MarkdownRenderCache(limit: 2)
        _ = cache.rendered("a", readingFont: nil)
        _ = cache.rendered("b", readingFont: nil)
        _ = cache.rendered("c", readingFont: nil)
        _ = cache.rendered("a", readingFont: nil) // evicted, so rendered again
        #expect(cache.renderCount == 4)
    }

    @Test func creatingTheViewDoesNotParse() {
        let before = MarkdownRenderCache.shared.renderCount
        _ = MarkdownText("# Heading \(UUID())\nBody")
        #expect(MarkdownRenderCache.shared.renderCount == before)
    }
}
