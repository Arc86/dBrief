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

    @Test func hidingAdvancedSettingsKeepsSelectionReachable() {
        for page in SettingsPage.allCases {
            let resolved = page.visibleSelection(advanced: false)
            #expect(SettingsPage.visiblePages(advanced: false).contains(resolved))
            #expect(page.visibleSelection(advanced: true) == page)
            if page != .benchmark { #expect(resolved == page) }
        }
        #expect(SettingsPage.visiblePages(advanced: false).contains(.profiles))
        #expect(SettingsPage.benchmark.visibleSelection(advanced: false) == .general)
    }

    @Test func movedSectionsRouteToTheirOwningPage() {
        #expect(SettingsDestination(section: .recordingShortcut).page == .recording)
        #expect(SettingsDestination(section: .callDetection).page == .recording)
        #expect(SettingsDestination(section: .calendar).page == .integrations)
        #expect(SettingsDestination(section: .storageFolders).page == .storage)
        #expect(SettingsDestination(section: .afterRecordingTasks).page == .afterRecording)
        let profilePolicy = SettingsDestination(section: .profileAutomation)
        #expect(profilePolicy.page == .profiles)
        #expect(profilePolicy.section == .profileAutomation)
        #expect(SettingsDestination(page: .profiles).section == nil)
    }

    @Test func profileHintsFollowMovedControls() {
        #expect(SettingsPage.general.profileFields.isEmpty)
        #expect(SettingsPage.storage.profileFields.contains(.recordingFolder))
        #expect(SettingsPage.afterRecording.profileFields.contains(.transcriptionTask))
        #expect(!SettingsPage.ai.profileFields.contains(.transcriptionTask))
    }
}
