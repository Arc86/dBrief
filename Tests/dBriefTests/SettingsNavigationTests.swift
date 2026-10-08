import Testing
@testable import dBrief

struct SettingsNavigationTests {
    @Test func everyPageAppearsInExactlyOneGroup() {
        let pages = SettingsGroup.allCases.flatMap(\.pages)
        #expect(pages.count == SettingsPage.allCases.count)
        #expect(Set(pages) == Set(SettingsPage.allCases))
        for group in SettingsGroup.allCases {
            #expect(group.pages.allSatisfy { $0.group == group })
        }
    }

    @Test func movedSectionsRouteToTheirOwningPage() {
        #expect(SettingsDestination(section: .recordingShortcut).page == .recording)
        #expect(SettingsDestination(section: .callDetection).page == .recording)
        #expect(SettingsDestination(section: .calendar).page == .integrations)
        #expect(SettingsDestination(section: .storageFolders).page == .storage)
        #expect(SettingsDestination(section: .afterRecordingTasks).page == .afterRecording)
        #expect(SettingsDestination(section: .appearance).page == .appearance)
        #expect(SettingsDestination(section: .typography).page == .appearance)
        #expect(SettingsDestination(section: .appBehavior).page == .general)
        let profilePolicy = SettingsDestination(section: .profileAutomation)
        #expect(profilePolicy.page == .profiles)
        #expect(profilePolicy.section == .profileAutomation)
        #expect(SettingsDestination(page: .profiles).section == nil)
    }

    @Test func adjacentPageClampsAtEnds() {
        let order = SettingsPage.sidebarOrder
        #expect(SettingsPage.adjacent(to: order[0], offset: -1) == order[0])
        #expect(SettingsPage.adjacent(to: order[order.count - 1], offset: 1) == order[order.count - 1])
        #expect(SettingsPage.adjacent(to: order[0], offset: 1) == order[1])
        #expect(Set(order) == Set(SettingsPage.allCases))
    }

    @Test func profileHintsFollowMovedControls() {
        #expect(SettingsPage.general.profileFields.isEmpty)
        #expect(SettingsPage.storage.profileFields.contains(.recordingFolder))
        #expect(SettingsPage.afterRecording.profileFields.contains(.transcriptionTask))
        #expect(!SettingsPage.ai.profileFields.contains(.transcriptionTask))
    }
}
