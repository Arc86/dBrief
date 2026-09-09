import Foundation
import Testing
@testable import dBrief

struct ProfileMatcherTests {
    private func profile(_ id: String = "00000000-0000-0000-0000-000000000001", rules: [ProfileMatchRule], priority: Int = 0) -> MeetingProfile {
        var profile = MeetingProfile(id: UUID(uuidString: id)!, name: "Matched")
        profile.automaticMatchingEnabled = true
        profile.matchingRules = rules
        profile.matchPriority = priority
        return profile
    }

    @Test func matchesAllContextFieldsAndExplainsEachRule() throws {
        let rules: [ProfileMatchRule] = [.init(field: .title, value: "renewal"), .init(field: .callApplication, value: "Teams"),
            .init(field: .calendarTitle, value: "ACME"), .init(field: .calendarNotes, value: "budget"),
            .init(field: .calendarLocation, value: "Amsterdam"), .init(field: .attendeeDomain, value: "acme.com")]
        let context = ProfileMatchContext(title: "Q4 Renewal", callApplication: "Microsoft Teams",
            calendarTitle: "Acme check-in", calendarNotes: "Discuss budget", calendarLocation: "Amsterdam Office",
            attendeeEmails: ["Ada@ACME.com"])
        let match = try #require(ProfileMatcher.match(profiles: [profile(rules: rules)], context: context))
        #expect(match.reasons.count == rules.count)
        #expect(match.reasons.contains { $0.contains("acme.com") })
        var mismatch = context
        mismatch.calendarNotes = "Delivery"
        #expect(ProfileMatcher.match(profiles: [profile(rules: rules)], context: mismatch) == nil)
    }

    @Test func emptyDisabledAndLookalikeDomainsDoNotMatch() {
        let context = ProfileMatchContext(title: "", attendeeEmails: ["a@notacme.com", "b@acme.com.evil", "c@sub.acme.com", "d@acmé.com"])
        for value in ["", " ", "acme.com", "*.acme.com", "a@acme.com"] {
            #expect(ProfileMatcher.match(profiles: [profile(rules: [.init(field: .attendeeDomain, value: value)])], context: context) == nil)
        }
        #expect(ProfileMatcher.match(profiles: [profile(rules: [])], context: context) == nil)
        var disabled = profile(rules: [.init(field: .title, value: "meet")])
        disabled.automaticMatchingEnabled = false
        #expect(ProfileMatcher.match(profiles: [disabled], context: .init(title: "Meeting")) == nil)
    }

    @Test func prioritySpecificityAndStableIDResolveConflicts() throws {
        let context = ProfileMatchContext(title: "Meeting", callApplication: "Teams")
        let first = profile(rules: [.init(field: .title, value: "meet")])
        var second = profile("00000000-0000-0000-0000-000000000002", rules: first.matchingRules)
        for profiles in [[first, second], [second, first]] {
            #expect(ProfileMatcher.match(profiles: profiles, context: context)?.profileID == first.id)
        }
        second.matchingRules.append(.init(field: .callApplication, value: "Teams"))
        #expect(ProfileMatcher.match(profiles: [first, second], context: context)?.profileID == second.id)
        second.matchPriority = -1
        #expect(ProfileMatcher.match(profiles: [second, first], context: context)?.profileID == first.id)
    }

    @Test func oldProfilesDoNotEnableMatching() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","preset":"custom"}
        """.utf8)
        let old = try JSONDecoder().decode(MeetingProfile.self, from: data)
        #expect(!old.automaticMatchingEnabled)
        #expect(old.matchingRules.isEmpty)
        let configured = profile(rules: [.init(field: .title, value: "Meet")], priority: 5)
        #expect(try JSONDecoder().decode(MeetingProfile.self, from: JSONEncoder().encode(configured)) == configured)
    }

    @Test func defersChangesWhileWorkerIsBusyThenAppliesMatch() {
        let baseline = MeetingProfile(name: "Original")
        let matched = profile(rules: [.init(field: .title, value: "sales")])
        var state = RecordingProfileSelection()
        let context = ProfileMatchContext(title: "Sales call")
        #expect(state.evaluate(profiles: [baseline, matched], context: context, activeID: baseline.id, workerBusy: true) == nil)
        #expect(state.isDeferred)
        #expect(state.match?.profileID == matched.id)
        #expect(state.evaluate(profiles: [baseline, matched], context: context, activeID: baseline.id, workerBusy: false) == matched.id)
        #expect(!state.isDeferred)
    }

    @Test func manualChoiceWinsOverLateCalendarAndContextUpdates() {
        let baseline = MeetingProfile(name: "Original")
        let matched = profile(rules: [.init(field: .calendarTitle, value: "sales")])
        var state = RecordingProfileSelection()
        _ = state.evaluate(profiles: [baseline, matched], context: .init(title: ""), activeID: baseline.id, workerBusy: true)
        state.chooseManually(baseline.id)
        #expect(state.evaluate(profiles: [baseline, matched], context: .init(title: "", calendarTitle: "Sales"),
                               activeID: baseline.id, workerBusy: false) == nil)
        #expect(state.isManual)
        #expect(state.appliedID == baseline.id)
    }

    @Test func removedMatchRestoresOriginalAndExternalChoiceIsRespected() {
        let baseline = MeetingProfile(name: "Original")
        let manual = MeetingProfile(name: "Manual")
        let matched = profile(rules: [.init(field: .calendarTitle, value: "sales")])
        let profiles = [baseline, manual, matched]
        var state = RecordingProfileSelection()
        #expect(state.evaluate(profiles: profiles, context: .init(title: "", calendarTitle: "Sales"),
                               activeID: baseline.id, workerBusy: false) == matched.id)
        #expect(state.evaluate(profiles: profiles, context: .init(title: ""), activeID: matched.id, workerBusy: false) == baseline.id)
        #expect(state.evaluate(profiles: profiles, context: .init(title: "", calendarTitle: "Sales"),
                               activeID: manual.id, workerBusy: false) == nil)
        #expect(state.isManual)
    }

    @Test func settingsChoiceBeforeCalendarArrivesCancelsAutomaticSelection() {
        let baseline = MeetingProfile(name: "Original")
        let chosen = MeetingProfile(name: "Chosen in Settings")
        let matched = profile(rules: [.init(field: .calendarTitle, value: "sales")])
        var state = RecordingProfileSelection(baselineID: baseline.id)
        #expect(state.evaluate(profiles: [baseline, chosen, matched], context: .init(title: "", calendarTitle: "Sales"),
                               activeID: chosen.id, workerBusy: false) == nil)
        #expect(state.isManual)
        #expect(state.appliedID == chosen.id)
    }

    @Test func nextUnmatchedRecordingReturnsToSavedManualProfile() {
        let baseline = MeetingProfile(name: "Manual fallback")
        let sales = profile(rules: [.init(field: .title, value: "sales")])
        var first = RecordingProfileSelection(baselineID: baseline.id)
        #expect(first.evaluate(profiles: [baseline, sales], context: .init(title: "Sales"), activeID: baseline.id,
                               workerBusy: false, manualID: baseline.id) == sales.id)
        var next = RecordingProfileSelection(baselineID: baseline.id)
        #expect(next.evaluate(profiles: [baseline, sales], context: .init(title: "Unrelated"), activeID: sales.id,
                              workerBusy: true, manualID: baseline.id) == nil)
        #expect(next.isDeferred)
        #expect(next.evaluate(profiles: [baseline, sales], context: .init(title: "Unrelated"), activeID: sales.id,
                              workerBusy: false, manualID: baseline.id) == baseline.id)
        #expect(!next.isManual)
    }

    @Test @MainActor func automaticRoutingDoesNotPersistAsManualChoice() throws {
        let settings = AppSettings()
        let savedProfiles = settings.profiles
        let savedID = settings.activeProfileId
        defer { settings.profiles = savedProfiles; settings.setActiveProfile(savedID) }
        let fallback = settings.activeProfile
        let matched = settings.createProfile(name: "Automatic routing test")
        let recordingID = UUID()
        settings.routeAutomatically(to: matched.id, for: recordingID)
        #expect(settings.activeProfile.id == matched.id)
        #expect(settings.activeProfileId == fallback.id)
        // Reopening settings does not inherit a recording's automatic route.
        #expect(AppSettings().activeProfile.id == fallback.id)
        settings.finishAutomaticRouting(for: UUID())
        #expect(settings.activeProfile.id == matched.id)
        settings.finishAutomaticRouting(for: recordingID)
        #expect(settings.activeProfile.id == fallback.id)
        #expect(settings.automaticProfileRecordingID == nil)
        settings.routeAutomatically(to: matched.id, for: recordingID)
        #expect(RecordingManager.retranscriptionProfileID(for: recordingID, settings: settings) == matched.id)
        // A History retry must not inherit another recording's automatic route.
        #expect(RecordingManager.retranscriptionProfileID(for: UUID(), settings: settings) == fallback.id)
        #expect(settings.automaticProfileRecordingID == nil)
        settings.routeAutomatically(to: matched.id, for: UUID())
        settings.setActiveProfile(fallback.id)
        #expect(settings.automaticProfileId == nil)
        #expect(settings.automaticProfileRecordingID == nil)
        #expect(settings.activeProfile.id == fallback.id)
    }

    @Test func queuedProfileSurvivesRoundTripAndLegacyItemsUseFallback() throws {
        let profileID = UUID()
        let item = QueueItem(transcribe: true, summary: true, actionItems: false, tags: false, profileID: profileID)
        let decoded = try JSONDecoder().decode(QueueItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.profileID == profileID)
        let legacy = Data(#"{"transcribe":true,"summary":false,"actionItems":false,"tags":false}"#.utf8)
        #expect(try JSONDecoder().decode(QueueItem.self, from: legacy).profileID == nil)
    }

    @Test func retainedChoiceSurvivesWorkerCleanupButYieldsToLaterSettingsChoice() {
        let fallback = UUID(), workerProfile = UUID(), laterChoice = UUID()
        var selection = RecordingProfileSelection()
        selection.chooseManually(workerProfile, savedManualID: fallback)
        #expect(selection.retainedManualChoice(savedManualID: fallback) == workerProfile)
        #expect(selection.isManual)
        #expect(!selection.isDeferred)
        #expect(selection.retainedManualChoice(savedManualID: laterChoice) == laterChoice)
        #expect(selection.reviewProfileID(savedManualID: laterChoice) == laterChoice)
    }

    @Test func reviewProfileIsIndependentOfAnotherWorkersRoute() {
        let fallback = UUID(), matched = UUID(), laterChoice = UUID()
        var selection = RecordingProfileSelection(baselineID: fallback)
        #expect(selection.reviewProfileID(savedManualID: fallback) == fallback)
        selection.chooseManually(matched, savedManualID: fallback)
        #expect(selection.reviewProfileID(savedManualID: fallback) == matched)
        #expect(selection.reviewProfileID(savedManualID: laterChoice) == laterChoice)
    }

    @Test func matchingBusyWorkersProfileRetainsChoiceWithoutTakingOwnership() {
        let baseline = MeetingProfile(name: "Local fallback")
        let matched = profile(rules: [.init(field: .title, value: "sales")])
        var selection = RecordingProfileSelection(baselineID: baseline.id)
        #expect(selection.evaluate(profiles: [baseline, matched], context: .init(title: "Sales"),
            activeID: matched.id, workerBusy: true, manualID: baseline.id) == nil)
        #expect(!selection.isDeferred)
        #expect(selection.appliedID == matched.id)
        #expect(selection.reviewProfileID(savedManualID: baseline.id) == matched.id)
        selection.chooseManually(selection.reviewProfileID(savedManualID: baseline.id), savedManualID: baseline.id)
        #expect(selection.retainedManualChoice(savedManualID: baseline.id) == matched.id)
    }

    @Test func releasingTemporaryRouteDoesNotBecomeManualOverride() {
        let baseline = MeetingProfile(name: "Fallback")
        let matched = profile(rules: [.init(field: .title, value: "sales")])
        var selection = RecordingProfileSelection()
        let context = ProfileMatchContext(title: "Sales")
        #expect(selection.evaluate(profiles: [baseline, matched], context: context, activeID: baseline.id,
            workerBusy: false, manualID: baseline.id) == matched.id)
        #expect(selection.evaluate(profiles: [baseline, matched], context: context, activeID: baseline.id,
            workerBusy: false, manualID: baseline.id) == matched.id)
        #expect(!selection.isManual)
    }
}
