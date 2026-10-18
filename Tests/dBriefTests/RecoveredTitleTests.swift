import Foundation
import Testing
@testable import dBrief

@Suite("Recovered generated title")
struct RecoveredTitleTests {
    private let plan = MarkdownExportPlan(destination: URL(fileURLWithPath: "/tmp/n.md"), content: "x",
                                          generatedTitle: " 2026 F1 Singapore GP ")

    @Test func prefersTheFrozenExportTitleThenTheSidecar() {
        #expect(RecordingManager.recoveredGeneratedTitle(exportPlan: plan, sidecarTitle: "Other") == "2026 F1 Singapore GP")
        #expect(RecordingManager.recoveredGeneratedTitle(exportPlan: nil, sidecarTitle: "From sidecar") == "From sidecar")
        let blank = MarkdownExportPlan(destination: plan.destination, content: "x", generatedTitle: "  ")
        #expect(RecordingManager.recoveredGeneratedTitle(exportPlan: blank, sidecarTitle: nil) == nil)
        #expect(RecordingManager.recoveredGeneratedTitle(exportPlan: nil, sidecarTitle: nil) == nil)
    }
}
