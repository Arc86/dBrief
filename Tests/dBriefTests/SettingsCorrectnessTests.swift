import Foundation
import Testing
@testable import dBrief

/// Settings that said one thing and did another (UX audit batch 5).
@Suite(.serialized) @MainActor struct SettingsCorrectnessTests {
    @MainActor private final class Fixture {
        let settings = AppSettings()
        private let oldProfiles: [MeetingProfile]
        private let oldActive: UUID
        private let oldLanguage: String
        private let oldRecordings: URL
        private let oldTranscripts: URL
        init() {
            oldProfiles = settings.profiles
            oldActive = settings.activeProfileId
            oldLanguage = settings.transcriptionLanguage
            oldRecordings = settings.recordingFolderURL
            oldTranscripts = settings.transcriptionFolderURL
        }
        func restore() {
            settings.profiles = oldProfiles
            settings.activeProfileId = oldActive
            settings.transcriptionLanguage = oldLanguage
            settings.recordingFolderURL = oldRecordings
            settings.transcriptionFolderURL = oldTranscripts
        }
    }

    /// A profile's language reached Apple Speech and Parakeet but not local Whisper.
    @Test func profileLanguageReachesWhisper() {
        let f = Fixture()
        defer { f.restore() }
        f.settings.transcriptionLanguage = "en"
        var dutch = MeetingProfile(name: "Dutch meetings")
        dutch.overrides.transcriptionLanguage = "nl"
        f.settings.profiles = f.settings.profiles + [dutch]
        f.settings.setActiveProfile(dutch.id)
        #expect(f.settings.whisperRuntimeConfig.language == "nl")
    }

    /// Auto-delete swept only the active profile's folders.
    @Test func cleanupCoversEveryProfilesFolders() throws {
        let f = Fixture()
        defer { f.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-folders-\(UUID())")
        let global = root.appendingPathComponent("Recordings"), notes = root.appendingPathComponent("Notes")
        let sales = root.appendingPathComponent("Sales")
        for folder in [global, notes, sales] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        f.settings.recordingFolderURL = global
        f.settings.transcriptionFolderURL = notes
        var profile = MeetingProfile(name: "Sales")
        profile.overrides.recordingFolderPath = sales.path
        f.settings.profiles = f.settings.profiles + [profile]
        let recordings = Set(f.settings.retentionFolders(for: .recordings).map(\.standardizedFileURL.path))
        #expect(recordings == Set([global, sales].map(\.standardizedFileURL.path)))
        let transcripts = Set(f.settings.retentionFolders(for: .transcripts).map(\.standardizedFileURL.path))
        #expect(transcripts == Set([global, notes, sales].map(\.standardizedFileURL.path)))
    }

    /// A profile that used a remote engine had no visible place to add its provider.
    @Test func providerCardsFollowEveryProfilesEngine() {
        let f = Fixture()
        defer { f.restore() }
        f.settings.profiles = f.settings.profiles.map { var p = $0; p.overrides.transcriptionEngine = nil; p.overrides.aiEngine = nil; return p }
        let globalUsesRemote = f.settings.transcriptionEngine == .remoteEndpoint
        #expect(f.settings.usesTranscriptionEngineAnywhere(.remoteEndpoint) == globalUsesRemote)
        var remote = MeetingProfile(name: "Remote")
        remote.overrides.transcriptionEngine = .remoteEndpoint
        remote.overrides.aiEngine = .localCLI
        f.settings.profiles = f.settings.profiles + [remote]
        #expect(f.settings.usesTranscriptionEngineAnywhere(.remoteEndpoint))
        #expect(f.settings.usesAIEngineAnywhere(.localCLI))
    }

    /// "Results language" was labelled Gemma-only and hidden for the other engines that use it.
    @Test func resultsLanguageAppliesToEveryUnifiedEngine() {
        #expect(AppSettings.AIEngine.qwenLocal.usesResultsLanguage)
        #expect(AppSettings.AIEngine.appleIntelligence.usesResultsLanguage)
        #expect(AppSettings.AIEngine.localCLI.usesResultsLanguage)
        #expect(!AppSettings.AIEngine.remoteEndpoint.usesResultsLanguage)
    }

    /// Watched-folder imports took the global task toggles but the active profile's
    /// engine, folders and AI: one recording, two sets of rules.
    @Test func watchedFolderImportsUseTheActiveProfileForEveryChoice() {
        let f = Fixture()
        defer { f.restore() }
        var profile = MeetingProfile(name: "No summaries")
        profile.overrides.autoTranscribe = true
        profile.overrides.autoSummary = false
        f.settings.profiles = f.settings.profiles + [profile]
        f.settings.setActiveProfile(profile.id)
        let tasks = f.settings.watchedFolderTasks
        #expect(tasks.transcribe && !tasks.summary)
    }
}
