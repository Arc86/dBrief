import Foundation

/// Read-only presentation of a particular profile. Never activates a profile to
/// inspect it: the editor, an automatic route and a recording can all differ.
@MainActor
struct SettingsProfileScope {
    enum Field: String, CaseIterable, Identifiable {
        case language, vocabulary, transcriptionEngine, transcriptionService
        case aiEnabled, aiEngine, aiProvider, analysisEffort, calendarEffort
        case summaryPrompt, actionsPrompt, tagsPrompt
        case transcriptionTask, summaryTask, actionsTask, tagsTask, calendarParticipantsTask
        case recordingFolder, transcriptFolder, obsidianVault, obsidianFolder
        case tickTickList, todoistProject, notionDestination
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
            case .analysisEffort: \.localCLIReasoningEffort
            case .calendarEffort: \.calendarCLIReasoningEffort
            case .summaryPrompt: \.summaryPrompt
            case .actionsPrompt: \.actionItemsPrompt
            case .tagsPrompt: \.tagsPrompt
            case .transcriptionTask: \.autoTranscribe
            case .summaryTask: \.autoSummary
            case .actionsTask: \.autoActionItems
            case .tagsTask: \.autoTags
            case .calendarParticipantsTask: \.autoLoadCalendarParticipants
            case .recordingFolder: \.recordingFolderPath
            case .transcriptFolder: \.transcriptionFolderPath
            case .obsidianVault: \.obsidianVaultPath
            case .obsidianFolder: \.obsidianDefaultFolderRelativePath
            case .tickTickList: \.tickTickProjectID
            case .todoistProject: \.todoistProjectID
            case .notionDestination: \.notionParentID
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
            add(id, label, baseline, override, format: { $0 ? String(localized: "On") : String(localized: "Off") })
        }
        func provider(_ id: Field, _ label: String, _ baseline: Endpoint?,
                      _ overrideID: UUID?, _ endpoints: [Endpoint]) {
            guard fields.contains(id) else { return }
            let endpoint = overrideID.flatMap { id in endpoints.first { $0.id == id } }
            let missing = overrideID != nil && endpoint == nil
            rows.append(Summary(id: id, label: label,
                                defaultValue: baseline?.name ?? String(localized: "Not configured"),
                                profileValue: (endpoint ?? baseline)?.name ?? String(localized: "Not configured"),
                                isOverridden: overrideID != nil,
                                note: missing ? String(localized: "Selected provider is unavailable; using the app default.") : nil))
        }
        func destination(_ id: Field, _ label: String, _ baseline: URL, _ override: String?) {
            guard fields.contains(id) else { return }
            let resolved = settings.resolvedFolderURL(overridePath: override, fallback: baseline)
            let emptyOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            // Only overrides are shown; skip the disk check for app-default rows.
            let unavailable = override != nil && !Self.isDirectory(resolved)
            rows.append(Summary(id: id, label: label, defaultValue: baseline.path,
                                profileValue: resolved.path, isOverridden: override != nil,
                                note: emptyOverride ? String(localized: "Empty destination; using the app default.")
                                : unavailable ? String(localized: "Destination is unavailable. It is kept for recovery; choose an accessible folder.") : nil))
        }

        let engine = overrides.transcriptionEngine ?? settings.transcriptionEngine
        let languageNote: String?
        if engine == .parakeetLocal {
            languageNote = String(localized: "Parakeet does not use the profile language override. It is kept for other engines.")
        } else if engine == .localWhisper && overrides.transcriptionLanguage != nil {
            languageNote = String(localized: "This engine’s current transcription pass uses the app language setting. The profile override is kept.")
        } else {
            languageNote = nil
        }
        if fields.contains(.language) {
            func languageLabel(_ code: String, engine: AppSettings.TranscriptionEngine) -> String {
                if code.isEmpty { return engine == .appleSpeech ? String(localized: "System language") : String(localized: "Auto-detect") }
                return Locale.current.localizedString(forIdentifier: code) ?? code
            }
            rows.append(Summary(id: .language, label: String(localized: "Audio language"),
                                defaultValue: languageLabel(settings.transcriptionLanguage, engine: settings.transcriptionEngine),
                                profileValue: languageLabel(overrides.transcriptionLanguage ?? settings.transcriptionLanguage, engine: engine),
                                isOverridden: overrides.transcriptionLanguage != nil, note: languageNote))
        }
        add(.vocabulary, String(localized: "Vocabulary"), settings.customVocabulary, overrides.customVocabulary,
            format: { $0.isEmpty ? String(localized: "No custom terms") : $0.joined(separator: ", ") })
        add(.transcriptionEngine, String(localized: "Transcription engine"), settings.transcriptionEngine, overrides.transcriptionEngine,
            format: { $0.displayName })
        provider(.transcriptionService, String(localized: "Transcription service"), settings.defaultTranscriptionEndpoint,
                 overrides.transcriptionEndpointId, settings.transcriptionEndpoints)
        toggle(.aiEnabled, String(localized: "AI analysis"), settings.aiProcessingEnabled, overrides.aiProcessingEnabled)
        add(.aiEngine, String(localized: "AI engine"), settings.aiEngine, overrides.aiEngine, format: { $0.displayName })
        provider(.aiProvider, String(localized: "AI provider"), settings.defaultAIEndpoint, overrides.aiEndpointId, settings.aiEndpoints)
        add(.analysisEffort, String(localized: "AI analysis CLI effort"), settings.localCLIConfig.effort,
            overrides.localCLIReasoningEffort, format: { Self.effortName($0) },
            note: (overrides.aiEngine ?? settings.aiEngine) != .localCLI
                ? String(localized: "Saved, but inactive until Local CLI is selected as the AI engine.")
                : settings.localCLIConfig.effortProvider == .commandDefault
                ? String(localized: "Saved, but inactive until the effort provider is Claude Code.") : nil)
        add(.calendarEffort, String(localized: "Calendar CLI effort"), settings.calendarCLIConfig.effort,
            overrides.calendarCLIReasoningEffort, format: { Self.effortName($0) },
            note: settings.effectiveCalendarSource != .claudeCLI
                ? String(localized: "Saved, but inactive until Claude CLI is the calendar source.")
                : settings.calendarCLIConfig.modelID?.lowercased().contains("haiku") == true
                ? String(localized: "Saved, but not applicable to the selected Haiku model.") : nil)
        add(.summaryPrompt, String(localized: "Summary prompt"), settings.summaryPrompt, overrides.summaryPrompt, format: { $0 })
        add(.actionsPrompt, String(localized: "Action items prompt"), settings.actionItemsPrompt, overrides.actionItemsPrompt, format: { $0 })
        add(.tagsPrompt, String(localized: "Tags prompt"), settings.tagsPrompt, overrides.tagsPrompt, format: { $0 })
        toggle(.transcriptionTask, String(localized: "Transcription task"), settings.autoTranscribe, overrides.autoTranscribe)
        toggle(.summaryTask, String(localized: "Summary task"), settings.autoSummary, overrides.autoSummary)
        toggle(.actionsTask, String(localized: "Action items task"), settings.autoActionItems, overrides.autoActionItems)
        toggle(.tagsTask, String(localized: "Tags task"), settings.autoTags, overrides.autoTags)
        toggle(.calendarParticipantsTask, String(localized: "Calendar attendees"), settings.autoLoadCalendarParticipants,
               overrides.autoLoadCalendarParticipants)
        destination(.recordingFolder, String(localized: "Recording folder"), settings.recordingFolderURL, overrides.recordingFolderPath)
        destination(.transcriptFolder, String(localized: "Transcript folder"), settings.transcriptionFolderURL, overrides.transcriptionFolderPath)

        // Match effectiveObsidianVaultURL: unlike recording destinations, an
        // unavailable vault override falls back to the app's configured vault.
        if fields.contains(.obsidianVault) {
            let vaultPath = overrides.obsidianVaultPath
            let vaultURL = vaultPath.flatMap { path -> URL? in
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return Self.isDirectory(url) ? url : nil
            }
            rows.append(Summary(id: .obsidianVault, label: String(localized: "Obsidian vault"),
                                defaultValue: settings.obsidianVaultURL?.path ?? String(localized: "Not configured"),
                                profileValue: (vaultURL ?? settings.obsidianVaultURL)?.path ?? String(localized: "Not configured"),
                                isOverridden: vaultPath != nil,
                                note: vaultPath != nil && vaultURL == nil ? String(localized: "Vault override is empty or unavailable; using the app default.") : nil))
        }
        add(.obsidianFolder, String(localized: "Obsidian notes folder"), settings.obsidianDefaultFolderRelativePath,
            overrides.obsidianDefaultFolderRelativePath, format: { $0.isEmpty ? String(localized: "Vault root") : $0 })
        func taskList(_ id: Field, _ label: String, baseName: String?, overrideID: String?, overrideName: String?) {
            guard fields.contains(id) else { return }
            let profileName = overrideID.map { $0.isEmpty ? String(localized: "Inbox") : overrideName ?? String(localized: "Unnamed") } ?? baseName ?? String(localized: "Inbox")
            rows.append(Summary(id: id, label: label, defaultValue: baseName ?? String(localized: "Inbox"), profileValue: profileName,
                                isOverridden: overrideID != nil, note: nil))
        }
        taskList(.tickTickList, String(localized: "TickTick list"), baseName: settings.integrations.tickTick.projectName,
                 overrideID: overrides.tickTickProjectID, overrideName: overrides.tickTickProjectName)
        taskList(.todoistProject, String(localized: "Todoist project"), baseName: settings.integrations.todoist.projectName,
                 overrideID: overrides.todoistProjectID, overrideName: overrides.todoistProjectName)
        if fields.contains(.notionDestination) {
            let notion = settings.integrations.notion
            let baseName = notion.parentID.isEmpty ? String(localized: "Not chosen") : notion.parentName ?? String(localized: "Untitled")
            let overrideID = overrides.notionParentID.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(Summary(id: .notionDestination, label: String(localized: "Notion destination"), defaultValue: baseName,
                                profileValue: overrideID == nil ? baseName : overrides.notionParentName ?? String(localized: "Untitled"),
                                isOverridden: overrideID != nil, note: nil))
        }
        summaries = rows
    }

    func summary(for field: Field) -> Summary {
        // Every field is added exactly once by the initializer.
        summaries.first { $0.id == field }!
    }

    func summary(for keyPath: AnyKeyPath) -> Summary? {
        summaries.first { $0.id.keyPath == keyPath }
    }

    private static func effortName(_ effort: CLIReasoningEffort) -> String {
        switch effort {
        case .cliDefault: String(localized: "CLI default")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra high")
        case .max: String(localized: "Maximum")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
