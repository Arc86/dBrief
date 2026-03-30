import Foundation
import Testing
@testable import dBrief

struct ResultsViewTests {

    @Test func allSectionsDefaultToExpanded() {
        let collapsed = Set<ResultsView.Section>()
        #expect(!collapsed.contains(.summary))
        #expect(!collapsed.contains(.actionItems))
        #expect(!collapsed.contains(.tagsAndSentiment))
    }

    @Test func toggleCollapsesThenExpandsSection() {
        var collapsed = Set<ResultsView.Section>()

        // First toggle: collapse
        if collapsed.contains(.summary) { collapsed.remove(.summary) } else { collapsed.insert(.summary) }
        #expect(collapsed.contains(.summary))

        // Second toggle: expand
        if collapsed.contains(.summary) { collapsed.remove(.summary) } else { collapsed.insert(.summary) }
        #expect(!collapsed.contains(.summary))
    }

    @Test @MainActor func summarySectionHiddenWhenNil() {
        let recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/test.flac"))
        #expect(recording.summary == nil)
    }
}
