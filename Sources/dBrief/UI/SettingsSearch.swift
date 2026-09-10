import Foundation

/// Search uses only this static metadata, never user preferences or provider data.
struct SettingsSearchEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let keywords: String
    let destination: SettingsDestination
    let requiresAdvanced: Bool

    init(_ id: String, _ title: String, _ keywords: String, section: SettingsSectionID, advanced: Bool = false) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.destination = SettingsDestination(section: section)
        self.requiresAdvanced = advanced
    }

    init(page: SettingsPage) {
        id = "page.\(page.rawValue)"
        title = page.title
        switch page {
        case .voiceLibrary: keywords = "Voice Library speaker identification enroll voices diarization"
        case .ai: keywords = "AI & Models artificial intelligence"
        case .spokenVoice: keywords = "Spoken Voice text to speech read aloud"
        case .watchedFolders: keywords = "Watched Folders automatic import"
        default: keywords = page.group.title
        }
        destination = SettingsDestination(section: page.searchSection)
        requiresAdvanced = page == .benchmark
    }
}

enum SettingsSearch {
    static let entries: [SettingsSearchEntry] = SettingsPage.allCases.map(SettingsSearchEntry.init(page:)) + [
        .init("appearance", "Appearance and startup", "start login dock icon neon accents theme", section: .appearance),
        .init("advanced", "Show advanced settings", "power user mode benchmarks model options prompts", section: .appearance),
        .init("updates", "Software updates", "check now automatic update version", section: .softwareUpdate),
        .init("setup", "Setup guide", "welcome onboarding first run", section: .setupGuide),
        .init("shortcut", "Recording shortcut", "hotkey keyboard start stop", section: .recordingShortcut),
        .init("detection", "Call detection", "auto start dismiss meeting ends microphone", section: .callDetection),
        .init("platforms", "Meeting platforms", "call platforms zoom teams slack webex facetime google meet", section: .callPlatforms),
        .init("input", "Audio input device", "microphone system default refresh", section: .audioInput),
        .init("echo", "Reduce microphone echo", "echo cancellation speakers headphones", section: .echoCancellation),
        .init("indicators", "Recording indicators", "floating window status duration menu bar", section: .recordingIndicators),
        .init("quality", "Audio quality", "capture format master output codec", section: .audioQuality, advanced: true),
        .init("storage", "Recording and transcript folders", "storage path destination choose export", section: .storageFolders),
        .init("retention", "Automatic file deletion", "storage privacy retention clean up old recordings transcripts delete after", section: .storageFolders),
        .init("calendar", "Calendar connections and matching", "ical outlook microsoft calendars meetings source automatic match window", section: .calendar),
        .init("integrations", "Connected apps and exports", "integrations obsidian vault apple notes reminders notion evernote google keep onenote webhook", section: .integrations),
        .init("tasks", "After-recording task defaults", "auto transcribe summary action items tags sentiment post recording defaults", section: .afterRecordingTasks),
        .init("automation", "After-recording automation", "policy review countdown process queue automatically", section: .afterRecordingAutomation),
        .init("profile", "Profile selection and reset", "default saved name edit restore shared defaults", section: .profileIdentity),
        .init("matching", "Automatic profile selection", "matching conditions priority rules attendee domain", section: .profileMatching),
        .init("profilePolicy", "Profile automation policy", "after recording review countdown queue process", section: .profileAutomation),
        .init("profileTranscription", "Profile transcription overrides", "language vocabulary engine service inherit", section: .profileTranscription),
        .init("profileAI", "Profile AI overrides", "analysis provider prompts inherit", section: .profileAI),
        .init("profileTasks", "Profile task overrides", "transcription summary action items tags inherit", section: .profileTasks),
        .init("profileFolders", "Profile destination overrides", "recording transcript folder obsidian vault inherit", section: .profileFolders),
        .init("transcriptionEngine", "Transcription engine", "whisper parakeet apple speech remote model download", section: .transcriptionEngine),
        .init("language", "Audio language", "transcription language auto detect multilingual", section: .transcriptionLanguage),
        .init("cleanup", "Transcript cleanup", "spelling filler words punctuation", section: .transcriptionCleanup),
        .init("live", "Live transcription", "real time preview speech recording", section: .transcriptionLive),
        .init("transcriptionServices", "Transcription services", "whisper endpoints api server provider key model", section: .transcriptionServices),
        .init("chunking", "Large file handling", "chunk chunking split upload size limit remote transcription", section: .transcriptionChunking, advanced: true),
        .init("aiEnabled", "Enable AI processing", "analysis summary actions tags on off", section: .aiEnabled),
        .init("aiEngine", "AI engine", "gemma qwen apple intelligence local cli remote", section: .aiEngine),
        .init("aiModels", "AI model options", "output language gemma model download remove cache", section: .aiEngine, advanced: true),
        .init("prompts", "AI prompts", "custom summary action items tags sentiment instructions", section: .aiPrompts, advanced: true),
        .init("cli", "Local CLI configuration", "command executable claude codex test", section: .aiCLI),
        .init("chatFallback", "Chat fallback", "local cli chat engine provider", section: .aiChatFallback),
        .init("aiProviders", "AI providers", "llm endpoints api key server model test connection", section: .aiProviders),
        .init("voice", "Spoken voice", "text to speech tts qwen kokoro voice style language preview model", section: .spokenVoice),
        .init("spokenPrompt", "Spoken summary prompt", "custom script instructions read aloud", section: .spokenPrompt, advanced: true),
        .init("terms", "Vocabulary terms", "custom vocabulary acronyms names spelling edit delete", section: .vocabularyTerms),
        .init("import", "Automatic import", "watched folders watch folder files import", section: .automaticImport),
        .init("permissions", "Permissions and access", "microphone screen recording calendar system settings authorization", section: .permissions)
    ]

    static func results(for query: String) -> [SettingsSearchEntry] {
        let query = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.compactMap { entry -> (SettingsSearchEntry, Int)? in
            let title = normalize(entry.title)
            let text = normalize("\(entry.title) \(entry.keywords) \(entry.destination.page.title)")
            guard terms.allSatisfy({ text.contains($0) }) else { return nil }
            let score = title == query ? 100 : title.hasPrefix(query) ? 80 : title.contains(query) ? 60 : 10
            return (entry, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id < $1.0.id
        }.map(\.0)
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
