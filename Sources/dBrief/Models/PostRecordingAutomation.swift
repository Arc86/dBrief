import Foundation
import Observation

enum PostRecordingPolicy: String, Codable, CaseIterable, Sendable {
    case review, process, queue

    var title: String {
        switch self {
        case .review: "Review before processing"
        case .process: "Process automatically"
        case .queue: "Queue automatically"
        }
    }
}

/// Frozen intent for one completed capture. Changing profile or task defaults
/// during the countdown invalidates it instead of silently changing the action.
struct AutomaticPostRecordingRequest: Equatable, Sendable {
    let recordingID: UUID
    let profile: MeetingProfile
    let transcribe: Bool
    let summary: Bool
    let actionItems: Bool
    let tags: Bool
    let configuration: AutomaticPostRecordingConfiguration?

    init(recordingID: UUID, profile: MeetingProfile, transcribe: Bool, summary: Bool, actionItems: Bool, tags: Bool,
         configuration: AutomaticPostRecordingConfiguration? = nil) {
        self.recordingID = recordingID
        self.profile = profile
        self.transcribe = transcribe
        self.summary = summary && transcribe
        self.actionItems = actionItems && transcribe
        self.tags = tags && transcribe
        self.configuration = configuration
    }
}

/// In-memory only. Includes inherited settings and endpoint edits, not just
/// profile overrides, so a countdown cannot silently switch providers or export
/// destinations. Credentials are compared in memory and never logged/persisted.
struct AutomaticPostRecordingConfiguration: Equatable, Sendable {
    let transcriptionEndpoint: Endpoint?
    let aiEndpoint: Endpoint?
    let integrations: IntegrationSettings
    let localCLI: LocalCLIConfig
    let vocabulary: [String]
    let ignoredSegments: [String]
    let options: [String]
    let toggles: [Bool]

    @MainActor init(settings: AppSettings) {
        transcriptionEndpoint = settings.effectiveDefaultTranscriptionEndpoint
        aiEndpoint = settings.effectiveDefaultAIEndpoint
        integrations = settings.integrations
        localCLI = settings.localCLIConfig
        vocabulary = settings.effectiveCustomVocabulary
        ignoredSegments = settings.effectiveIgnoredSegments.sorted()
        options = [
            settings.effectiveTranscriptionEngine.rawValue, settings.effectiveAIEngine.rawValue,
            settings.chatFallbackEngine.rawValue, settings.effectiveTranscriptionLanguage,
            settings.transcriptionLanguage, String(describing: settings.outputLanguage),
            settings.whisperModelName, settings.parakeetModelVariant,
            settings.effectiveSummaryPrompt, settings.effectiveActionItemsPrompt, settings.effectiveTagsPrompt,
            settings.effectiveRecordingFolderURL.path, settings.effectiveTranscriptionFolderURL.path,
            settings.effectiveObsidianVaultURL?.path ?? "", settings.effectiveObsidianDefaultFolderRelativePath,
            String(describing: settings.whisperComputeUnits), String(describing: settings.speakerIdMode),
            String(settings.remoteChunkMaxUploadMB), String(settings.remoteChunkOverlapSeconds),
            String(settings.remoteChunkRetryCount)
        ]
        toggles = [settings.effectiveAIProcessingEnabled, settings.diarizationEnabled,
                   settings.effectiveRemoveFillerWords, settings.remoteChunkingEnabled,
                   settings.obsidianEnabled, settings.obsidianIncludeTranscript]
    }
}

/// A monotonic, single-consumption countdown owned by the manager, so closing
/// and reopening the popover cannot restart it or dispatch a second action.
@MainActor @Observable
final class PostRecordingAutomation {
    private(set) var request: AutomaticPostRecordingRequest?
    private(set) var secondsRemaining = 0
    private var deadline: ContinuousClock.Instant?
    var isPending: Bool { request != nil }

    func schedule(_ request: AutomaticPostRecordingRequest, now: ContinuousClock.Instant = .now) {
        cancel()
        guard request.profile.postRecordingPolicy != .review else { return }
        self.request = request
        deadline = now.advanced(by: .seconds(10))
        secondsRemaining = 10
    }

    func cancel() {
        request = nil
        deadline = nil
        secondsRemaining = 0
    }

    func claim(now: ContinuousClock.Instant = .now) -> AutomaticPostRecordingRequest? {
        guard let deadline, let request else { return nil }
        let remaining = now.duration(to: deadline).components
        secondsRemaining = max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
        guard now >= deadline else { return nil }
        cancel()
        return request
    }
}
