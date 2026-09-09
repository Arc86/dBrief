import Foundation
import Testing
@testable import dBrief

@MainActor struct PostRecordingAutomationTests {
    @Test func oldProfilesRemainReviewFirstAndPoliciesRoundTrip() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","preset":"custom"}
        """
        let legacy = try JSONDecoder().decode(MeetingProfile.self, from: Data(json.utf8))
        #expect(legacy.postRecordingPolicy == .review)
        let future = json.replacingOccurrences(of: "\"preset\":\"custom\"", with: "\"preset\":\"custom\",\"postRecordingPolicy\":\"unknownFuturePolicy\"")
        #expect(try JSONDecoder().decode(MeetingProfile.self, from: Data(future.utf8)).postRecordingPolicy == .review)
        for policy in PostRecordingPolicy.allCases {
            var profile = legacy
            profile.postRecordingPolicy = policy
            #expect(try JSONDecoder().decode(MeetingProfile.self, from: JSONEncoder().encode(profile)).postRecordingPolicy == policy)
        }
    }

    @Test func countdownCannotClaimEarlyOrTwice() throws {
        let state = PostRecordingAutomation()
        let start = ContinuousClock.now
        let request = request()
        state.schedule(request, now: start)
        #expect(state.secondsRemaining == 10)
        #expect(state.claim(now: start.advanced(by: .seconds(9))) == nil)
        #expect(state.secondsRemaining == 1)
        #expect(state.claim(now: start.advanced(by: .seconds(10))) == request)
        #expect(state.claim(now: start.advanced(by: .seconds(11))) == nil)
        #expect(!state.isPending)
    }

    @Test func cancelAndReplacementInvalidateOldCountdown() {
        let state = PostRecordingAutomation()
        let start = ContinuousClock.now
        state.schedule(request(), now: start)
        state.cancel()
        #expect(state.claim(now: start.advanced(by: .seconds(10))) == nil)
        let newer = request()
        state.schedule(newer, now: start.advanced(by: .seconds(8)))
        #expect(state.claim(now: start.advanced(by: .seconds(10))) == nil)
        #expect(state.claim(now: start.advanced(by: .seconds(18))) == newer)
    }

    @Test func reviewDoesNotScheduleAndDependentTasksRequireTranscription() {
        let state = PostRecordingAutomation()
        var profile = MeetingProfile(name: "Review")
        let review = AutomaticPostRecordingRequest(recordingID: UUID(), profile: profile,
            transcribe: false, summary: true, actionItems: true, tags: true)
        state.schedule(review)
        #expect(!state.isPending)
        #expect(!review.summary && !review.actionItems && !review.tags)
        profile.postRecordingPolicy = .queue
        state.schedule(.init(recordingID: UUID(), profile: profile, transcribe: true, summary: true, actionItems: true, tags: true))
        #expect(state.isPending)
    }

    private func request() -> AutomaticPostRecordingRequest {
        var profile = MeetingProfile(name: "Auto")
        profile.postRecordingPolicy = .process
        return .init(recordingID: UUID(), profile: profile, transcribe: true, summary: true, actionItems: false, tags: true)
    }

    @Test func inheritedEngineEndpointAndDestinationChangesInvalidateIntent() {
        let settings = AppSettings()
        let originalEngine = settings.transcriptionEngine
        let originalEndpoints = settings.transcriptionEndpoints
        let originalDefault = settings.defaultTranscriptionEndpointId
        let originalIntegrations = settings.integrations
        let originalFolder = settings.transcriptionFolderURL
        let originalProfiles = settings.profiles
        defer {
            settings.transcriptionEngine = originalEngine
            settings.transcriptionEndpoints = originalEndpoints
            settings.defaultTranscriptionEndpointId = originalDefault
            settings.integrations = originalIntegrations
            settings.transcriptionFolderURL = originalFolder
            settings.profiles = originalProfiles
        }
        for index in settings.profiles.indices { settings.profiles[index].overrides = .empty }
        settings.transcriptionEngine = .localWhisper
        let local = AutomaticPostRecordingConfiguration(settings: settings)
        settings.transcriptionEngine = .remoteEndpoint
        #expect(local != AutomaticPostRecordingConfiguration(settings: settings))
        let endpoint = Endpoint(name: "Test", baseURL: "https://one.example", modelName: "whisper")
        settings.transcriptionEndpoints = [endpoint]
        settings.defaultTranscriptionEndpointId = endpoint.id
        let beforeEdit = AutomaticPostRecordingConfiguration(settings: settings)
        settings.transcriptionEndpoints[0].baseURL = "https://two.example"
        #expect(beforeEdit != AutomaticPostRecordingConfiguration(settings: settings))
        let beforeFolder = AutomaticPostRecordingConfiguration(settings: settings)
        settings.transcriptionFolderURL = FileManager.default.temporaryDirectory
        #expect(beforeFolder != AutomaticPostRecordingConfiguration(settings: settings))
        let beforeIntegration = AutomaticPostRecordingConfiguration(settings: settings)
        settings.integrations.webhook.enabled.toggle()
        #expect(beforeIntegration != AutomaticPostRecordingConfiguration(settings: settings))
    }
}
