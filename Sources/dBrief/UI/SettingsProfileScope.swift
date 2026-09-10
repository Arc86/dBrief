import Foundation

/// Read-only presentation of a particular profile. Never activates a profile to
/// inspect it: the editor, an automatic route and a recording can all differ.
@MainActor
struct SettingsProfileScope {
    enum Field: String, CaseIterable, Identifiable {
        case language, vocabulary, transcriptionEngine, transcriptionService
        case aiEnabled, aiEngine, aiProvider, summaryPrompt, actionsPrompt, tagsPrompt
        case transcriptionTask, summaryTask, actionsTask, tagsTask
        case recordingFolder, transcriptFolder, obsidianVault, obsidianFolder
        var id: String { rawValue }

        var keyPath: PartialKeyPath<MeetingProfileOverrides> {
            switch self {
            case .language: \.transcriptionLanguage
            case .vocabulary: \.customVocabulary
            case .transcriptionEngine: \.transcriptionEngine
            case .transcriptionService: \.transcriptionEndpointId
            case .aiEnabled: \.aiProcessingEnabled
            case .aiEngine: \.aiEngine
            case .aiProvider: \.aiEndpointId
            case .summaryPrompt: \.summaryPrompt
            case .actionsPrompt: \.actionItemsPrompt
            case .tagsPrompt: \.tagsPrompt
            case .transcriptionTask: \.autoTranscribe
            case .summaryTask: \.autoSummary
            case .actionsTask: \.autoActionItems
            case .tagsTask: \.autoTags
            case .recordingFolder: \.recordingFolderPath
            case .transcriptFolder: \.transcriptionFolderPath
            case .obsidianVault: \.obsidianVaultPath
            case .obsidianFolder: \.obsidianDefaultFolderRelativePath
            }
        }
    }

    struct Summary: Identifiable {
        let id: Field
        let label: String
        let defaultValue: String
        let profileValue: String
        let isOverridden: Bool
        let note: String?
    }

    let profile: MeetingProfile
    let savedProfile: MeetingProfile?
    let isAutomatic: Bool
    let summaries: [Summary]

    init(settings: AppSettings, profile selectedProfile: MeetingProfile? = nil, fields: [Field] = Field.allCases) {
        let profile = selectedProfile ?? settings.activeProfile
        self.profile = profile
        savedProfile = settings.profiles.first { $0.id == settings.activeProfileId }
        isAutomatic = settings.automaticProfileId == profile.id
        let overrides = profile.overrides
        var rows: [Summary] = []
        func add<T: Sendable>(_ id: Field, _ label: String, _ baseline: T, _ override: T?,
                    format: (T) -> String, note: String? = nil) {
            guard fields.contains(id) else { return }
            rows.append(Summary(id: id, label: label, defaultValue: format(baseline),
                                profileValue: format(override ?? baseline),
                                isOverridden: override != nil, note: note))
        }
        func toggle(_ id: Field, _ label: String, _ baseline: Bool, _ override: Bool?) {
            add(id, label, baseline, override, format: { $0 ? "On" : "Off" })
        }
        func provider(_ id: Field, _ label: String, _ baseline: Endpoint?,
                      _ overrideID: UUID?, _ endpoints: [Endpoint]) {
            guard fields.contains(id) else { return }
            let endpoint = overrideID.flatMap { id in endpoints.first { $0.id == id } }
            let missing = overrideID != nil && endpoint == nil
            rows.append(Summary(id: id, label: label,
                                defaultValue: baseline?.name ?? "Not configured",
                                profileValue: (endpoint ?? baseline)?.name ?? "Not configured",
                                isOverridden: overrideID != nil,
                                note: missing ? "Selected provider is unavailable; using the app default." : nil))
        }
        func destination(_ id: Field, _ label: String, _ baseline: URL, _ override: String?) {
            guard fields.contains(id) else { return }
            let resolved = settings.resolvedFolderURL(overridePath: override, fallback: baseline)
            let emptyOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let unavailable = !Self.isDirectory(resolved)
            rows.append(Summary(id: id, label: label, defaultValue: baseline.path,
                                profileValue: resolved.path, isOverridden: override != nil,
                                note: emptyOverride ? "Empty destination; using the app default."
                                : unavailable ? "Destination is unavailable. It is kept for recovery; choose an accessible folder." : nil))
        }

        let engine = overrides.transcriptionEngine ?? settings.transcriptionEngine
        let languageNote: String?
        if engine == .parakeetLocal {
            languageNote = "Parakeet does not use the profile language override. It is kept for other engines."
        } else if engine == .localWhisper && overrides.transcriptionLanguage != nil {
            languageNote = "This engine’s current transcription pass uses the app language setting. The profile override is kept."
        } else {
            languageNote = nil
        }
        if fields.contains(.language) {
            func languageLabel(_ code: String, engine: AppSettings.TranscriptionEngine) -> String {
                if code.isEmpty { return engine == .appleSpeech ? "System language" : "Auto-detect" }
                return Locale.current.localizedString(forIdentifier: code) ?? code
            }
            rows.append(Summary(id: .language, label: "Audio language",
                                defaultValue: languageLabel(settings.transcriptionLanguage, engine: settings.transcriptionEngine),
                                profileValue: languageLabel(overrides.transcriptionLanguage ?? settings.transcriptionLanguage, engine: engine),
                                isOverridden: overrides.transcriptionLanguage != nil, note: languageNote))
        }
        add(.vocabulary, "Vocabulary", settings.customVocabulary, overrides.customVocabulary,
            format: { $0.isEmpty ? "No custom terms" : $0.joined(separator: ", ") })
        add(.transcriptionEngine, "Transcription engine", settings.transcriptionEngine, overrides.transcriptionEngine,
            format: { $0.displayName })
        provider(.transcriptionService, "Transcription service", settings.defaultTranscriptionEndpoint,
                 overrides.transcriptionEndpointId, settings.transcriptionEndpoints)
        toggle(.aiEnabled, "AI analysis", settings.aiProcessingEnabled, overrides.aiProcessingEnabled)
        add(.aiEngine, "AI engine", settings.aiEngine, overrides.aiEngine, format: { $0.displayName })
        provider(.aiProvider, "AI provider", settings.defaultAIEndpoint, overrides.aiEndpointId, settings.aiEndpoints)
        add(.summaryPrompt, "Summary prompt", settings.summaryPrompt, overrides.summaryPrompt, format: { $0 })
        add(.actionsPrompt, "Action items prompt", settings.actionItemsPrompt, overrides.actionItemsPrompt, format: { $0 })
        add(.tagsPrompt, "Tags prompt", settings.tagsPrompt, overrides.tagsPrompt, format: { $0 })
        toggle(.transcriptionTask, "Transcription task", settings.autoTranscribe, overrides.autoTranscribe)
        toggle(.summaryTask, "Summary task", settings.autoSummary, overrides.autoSummary)
        toggle(.actionsTask, "Action items task", settings.autoActionItems, overrides.autoActionItems)
        toggle(.tagsTask, "Tags task", settings.autoTags, overrides.autoTags)
        destination(.recordingFolder, "Recording folder", settings.recordingFolderURL, overrides.recordingFolderPath)
        destination(.transcriptFolder, "Transcript folder", settings.transcriptionFolderURL, overrides.transcriptionFolderPath)

        // Match effectiveObsidianVaultURL: unlike recording destinations, an
        // unavailable vault override falls back to the app's configured vault.
        if fields.contains(.obsidianVault) {
            let vaultPath = overrides.obsidianVaultPath
            let vaultURL = vaultPath.flatMap { path -> URL? in
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return Self.isDirectory(url) ? url : nil
            }
            rows.append(Summary(id: .obsidianVault, label: "Obsidian vault",
                                defaultValue: settings.obsidianVaultURL?.path ?? "Not configured",
                                profileValue: (vaultURL ?? settings.obsidianVaultURL)?.path ?? "Not configured",
                                isOverridden: vaultPath != nil,
                                note: vaultPath != nil && vaultURL == nil ? "Vault override is empty or unavailable; using the app default." : nil))
        }
        add(.obsidianFolder, "Obsidian notes folder", settings.obsidianDefaultFolderRelativePath,
            overrides.obsidianDefaultFolderRelativePath, format: { $0.isEmpty ? "Vault root" : $0 })
        summaries = rows
    }

    func summary(for field: Field) -> Summary {
        // Every field is added exactly once by the initializer.
        summaries.first { $0.id == field }!
    }

    func summary(for keyPath: AnyKeyPath) -> Summary? {
        summaries.first { $0.id.keyPath == keyPath }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
