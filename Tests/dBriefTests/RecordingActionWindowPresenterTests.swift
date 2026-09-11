import SwiftUI
import Testing
@testable import dBrief

@Suite("Recording action window presentation")
struct RecordingActionWindowPresenterTests {
    @Test("Menu-bar recording history routes actions to an owned window")
    @MainActor
    func menuBarHistoryUsesWindowPresentation() {
        let view = RecordingHistoryView(expanded: .constant(true))
        #expect(view.recordingActionPresentationStyle == .window)
    }
}
