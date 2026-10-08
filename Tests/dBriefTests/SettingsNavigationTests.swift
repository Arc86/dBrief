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

    @Test func sidebarFollowsTheLifeOfARecording() {
        #expect(SettingsGroup.allCases.map(\.title) == ["dBrief", "Capture", "Understand", "Deliver", ""])
        #expect(SettingsGroup.app.pages == [.general, .appearance, .permissions])
        #expect(SettingsGroup.capture.pages == [.recording, .meetings, .watchedFolders])
        #expect(SettingsGroup.understand.pages == [.transcription, .speakers, .vocabulary, .ai, .spokenVoice])
        #expect(SettingsGroup.deliver.pages == [.afterRecording, .profiles, .integrations, .storage])
        #expect(SettingsGroup.footer.pages == [.benchmark, .about])
        #expect(SettingsPage.benchmark.title == "Performance")
        #expect(SettingsPage.watchedFolders.title == "Import")
        #expect(SettingsPage.ai.title == "AI analysis")
    }

    @Test func movedSectionsRouteToTheirOwningPage() {
        #expect(SettingsDestination(section: .recordingShortcut).page == .recording)
        #expect(SettingsDestination(section: .callDetection).page == .meetings)
        #expect(SettingsDestination(section: .callPlatforms).page == .meetings)
        #expect(SettingsDestination(section: .calendar).page == .meetings)
        #expect(SettingsDestination(section: .meetingMatching).page == .meetings)
        #expect(SettingsDestination(section: .calendarCLIAdvanced).page == .meetings)
        #expect(SettingsDestination(section: .speakerIdentification).page == .speakers)
        #expect(SettingsDestination(section: .speakerLibrary).page == .speakers)
        #expect(SettingsDestination(section: .aiResultsLanguage).page == .ai)
        #expect(SettingsDestination(section: .transcriptionAdvanced).page == .transcription)
        #expect(SettingsDestination(section: .storageFolders).page == .storage)
        #expect(SettingsDestination(section: .integrations).page == .integrations)
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
        #expect(SettingsPage.meetings.profileFields == [.calendarEffort])
        #expect(!SettingsPage.ai.profileFields.contains(.calendarEffort))
    }
}
