import SwiftUI
import Testing
@testable import dBrief

struct SettingsAdvancedCardTests {
    @Test func expandsOnlyForSearchRequestsInsideTheCard() {
        let sections: Set<SettingsSectionID> = [.audioQuality]
        #expect(SettingsAdvancedCard<EmptyView>.shouldExpand(request: SettingsSearchRequest(section: .audioQuality), sections: sections))
        #expect(!SettingsAdvancedCard<EmptyView>.shouldExpand(request: SettingsSearchRequest(section: .audioInput), sections: sections))
        #expect(!SettingsAdvancedCard<EmptyView>.shouldExpand(request: nil, sections: sections))
    }
}
