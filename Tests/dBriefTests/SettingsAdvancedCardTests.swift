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

    @Test func searchTargetOpensTheCardOnFirstRender() {
        let sections: Set<SettingsSectionID> = [.transcriptionChunking]
        #expect(SettingsAdvancedCard<EmptyView>.isOpen(stored: false, request: SettingsSearchRequest(section: .transcriptionChunking), sections: sections))
        #expect(SettingsAdvancedCard<EmptyView>.isOpen(stored: true, request: nil, sections: sections))
        #expect(!SettingsAdvancedCard<EmptyView>.isOpen(stored: false, request: nil, sections: sections))
    }
}
