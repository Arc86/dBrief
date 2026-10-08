import SwiftUI
import Testing
@testable import dBrief

struct SettingsPageLayoutTests {
    @Test func columnIsCentredInThePaneAndKeepsItsInsetWhenNarrow() {
        #expect(SettingsPageLayout.leadingInset(forPaneWidth: 1156) == 238)
        #expect(SettingsPageLayout.leadingInset(forPaneWidth: 700) == 32)
    }
}
