import SwiftUI
import dBriefWire

struct SettingsAITab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.viewerPalette) private var palette
    @Environment(\.settingsSearchRequest) private var searchRequest
    let editProfile: (UUID) -> Void
    @Environment(RecordingManager.self) private var recordingManager
    @State private var purgeMessage: String?
    @State private var isTestingCLI = false
    @State private var cliTestSuccess: String?
    @State private var cliTestError: String?

    var body: some View {
        @Bindable var settings = appSettings
        SettingsPageScaffold(page: .ai, notice: {
            SettingsProfileScopeView(fields: SettingsPage.ai.profileFields, editProfile: editProfile)
        }) {
            SettingsCard("Analysis", section: .aiEnabled) {
                SettingsRow("AI analysis",
                            caption: settings.aiProcessingEnabled
                                ? "Summary, action items, tags and sentiment. Profiles can override this."
                                : "Off. You can still set it up here for later or for profiles that turn it on.") {
                    Toggle("AI analysis", isOn: $settings.aiProcessingEnabled)
                }
                SettingsRow(verbatim: "Engine", caption: engineDescription(for: settings.aiEngine)) {
                    Picker("Engine", selection: $settings.aiEngine) {
                        ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                            Text(engine.isRecommended ? "\(engine.displayName) · Recommended" : engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .id(SettingsSectionID.aiEngine)
                if settings.aiEngine == .qwenLocal {
                    SettingsStackedRow {
                        TranscriptionModelCard(presentation: .init(
                            title: "Gemma 4 E4B", language: "Multilingual", footprint: "4-bit, on this Mac",
                            summary: "Downloaded once from Hugging Face. Runs analysis and chat on this Mac.")) {
                            HStack(spacing: 6) {
                                ModelDownloadButton(kind: .gemma, compact: true)
                                ModelActionsMenu(modelName: "Gemma", message: $purgeMessage) {
                                    try await recordingManager.purgeLocalQwenModel()
                                }
                            }
                        }
                    }
                    if let purgeMessage {
                        SettingsRow(verbatim: "Model download", caption: purgeMessage)
                    }
                }
            }

            if settings.aiEngine == .qwenLocal || searchRequest?.section == .aiResultsLanguage {
                SettingsCard("Results language", description: "Gemma only", section: .aiResultsLanguage) {
                    SettingsRow("Write results in") {
                        Picker("Write results in", selection: outputLanguageSelectionBinding) {
                            Text("Same as transcript").tag("matchInput")
                            Text("English").tag("english")
                            Text("Dutch").tag("dutch")
                            Text("Custom").tag("custom")
                        }
                        .pickerStyle(.menu)
                    }
                    if case .custom(let code) = settings.outputLanguage {
                        SettingsRow("Language code", caption: "Two letters, for example DE or FR.") {
                            TextField("Language code", text: Binding(
                                get: { code },
                                set: { settings.outputLanguage = .custom($0.uppercased()) }
                            ), prompt: Text(verbatim: "EN"))
                            .settingsTextField()
                            .frame(width: 80)
                        }
                    }
                }
            }

            if settings.aiEngine == .localCLI || searchRequest?.section == .aiCLI {
                SettingsCard("Local CLI", description: "Runs your command once per recording", section: .aiCLI) {
                    localCLIRows
                }
            }

            if settings.aiEngine == .localCLI || searchRequest?.section == .aiChatFallback {
                SettingsCard("Ask dBrief AI", description: "Chat beside a transcript", section: .aiChatFallback) {
                    SettingsRow("Chat uses",
                                caption: settings.chatFallbackEngine == .remoteEndpoint
                                    ? "Local CLI can't stream, so chat uses this engine with the default provider below."
                                    : "Local CLI can't stream, so chat uses this engine.") {
                        Picker("Chat uses", selection: $settings.chatFallbackEngine) {
                            ForEach(AppSettings.AIEngine.allCases.filter { $0 != .localCLI }, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            if searchRequest?.section == .aiProviders || settings.aiEngine == .remoteEndpoint
                || (settings.aiEngine == .localCLI && settings.chatFallbackEngine == .remoteEndpoint) {
                SettingsCard("Providers", description: "For remote analysis and chat", section: .aiProviders) {
                    SettingsProviderList(kind: .ai, endpoints: $settings.aiEndpoints, defaultID: $settings.defaultAIEndpointId)
                }
            }

            SettingsAdvancedCard(page: .ai, summary: "Custom prompts", sections: [.aiPrompts]) {
                SettingsCard("Prompts",
                             description: settings.aiEngine == .remoteEndpoint ? nil
                                : "On-device and CLI engines merge these into one JSON result",
                             section: .aiPrompts) {
                    PromptSettingsRow(kind: .summary)
                    PromptSettingsRow(kind: .actionItems)
                    PromptSettingsRow(kind: .tags)
                }
            }
        }
    }

    private func engineDescription(for engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence:
            "On-device Foundation Models. Requires macOS 26+ with Apple Silicon."
        case .qwenLocal:
            "On-device MLX Gemma 4 E4B 4-bit model. Downloaded once from Hugging Face."
        case .remoteEndpoint:
            "Use a remote LLM endpoint configured below."
        case .localCLI:
            "Runs a local command-line tool once per recording to produce the analysis."
        }
    }

    private var outputLanguageSelectionBinding: Binding<String> {
        return Binding<String>(
            get: {
                switch appSettings.outputLanguage {
                case .matchInput: "matchInput"
                case .english: "english"
                case .dutch: "dutch"
                case .custom: "custom"
                }
            },
            set: { value in
                switch value {
                case "english":
                    appSettings.outputLanguage = .english
                case "dutch":
                    appSettings.outputLanguage = .dutch
                case "custom":
                    let currentCode: String = {
                        if case .custom(let code) = appSettings.outputLanguage {
                            return code.isEmpty ? "EN" : code
                        }
                        return "EN"
                    }()
                    appSettings.outputLanguage = .custom(currentCode)
                default:
                    appSettings.outputLanguage = .matchInput
                }
            }
        )
    }

    private var localCLICommandBinding: Binding<String> {
        Binding(
            get: { appSettings.localCLIConfig.command },
            set: { appSettings.localCLIConfig.command = $0 }
        )
    }

    @ViewBuilder
    private var localCLIRows: some View {
        SettingsRow("Command", caption: "Must print a JSON object (title_concept, summary, action_items, tags, sentiment). Runs with your login shell's PATH.") {
            Menu("Load template") {
                ForEach(LocalCLIConfig.templates) { template in
                    Button(template.name) {
                        appSettings.localCLIConfig.command = template.command
                        appSettings.localCLIConfig.effortProvider = template.effortProvider
                        appSettings.localCLIConfig.effort = template.effort
                        appSettings.localCLIConfig.modelID = nil
                        cliTestSuccess = nil
                        cliTestError = nil
                    }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
        SettingsStackedRow {
            VStack(alignment: .leading, spacing: 6) {
                NativeTextView(text: localCLICommandBinding, monospaced: true, accessibilityName: "Local CLI command")
                    .frame(height: 70)
                Text("Prompts arrive as DBRIEF_SYSTEM_PROMPT, DBRIEF_USER_PROMPT and DBRIEF_FULL_PROMPT, and on stdin. If a tool isn't found, use its absolute path (`which <tool>`).")
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if appSettings.localCLIConfig.supportsClaudeModel {
            ClaudeModelPicker(modelID: Binding(
                get: { appSettings.localCLIConfig.modelID },
                set: { modelID in
                    appSettings.localCLIConfig.modelID = modelID
                    cliTestSuccess = nil
                    cliTestError = nil
                }
            ))
        }
        SettingsRow("Timeout") {
            Picker("Timeout", selection: Binding(
                get: { appSettings.localCLIConfig.timeoutSeconds },
                set: { appSettings.localCLIConfig.timeoutSeconds = $0 }
            )) {
                ForEach([15, 30, 45, 60, 90, 120, 180, 300, 600, 900, 1200, 1800, 3600], id: \.self) { secs in
                    Text(secs >= 60 ? "\(secs / 60) min" : "\(secs) s").tag(secs)
                }
            }
            .pickerStyle(.menu)
        }
        SettingsRow("Effort provider",
                    caption: appSettings.localCLIConfig.effortProvider == .claude
                        ? nil : "Choose Claude Code for a Claude wrapper command. Other commands keep their own settings.") {
            Picker("Effort provider", selection: Binding(
                get: { appSettings.localCLIConfig.effortProvider },
                set: { provider in
                    appSettings.localCLIConfig.effortProvider = provider
                    cliTestSuccess = nil
                    cliTestError = nil
                }
            )) {
                Text("Command default").tag(CLIEffortProvider.commandDefault)
                Text("Claude Code").tag(CLIEffortProvider.claude)
            }
            .pickerStyle(.menu)
        }
        if appSettings.localCLIConfig.effortProvider == .claude {
            SettingsRow("Reasoning effort", caption: "Applies to this child process. An inline environment assignment can override it.") {
                CLIReasoningEffortPicker(title: "Reasoning effort", selection: Binding(
                    get: { appSettings.localCLIConfig.effort },
                    set: { effort in
                        appSettings.localCLIConfig.effort = effort
                        cliTestSuccess = nil
                        cliTestError = nil
                    }
                ), recommendation: .medium)
            }
        }
        SettingsRow("Test the command") {
            HStack(spacing: 8) {
                if isTestingCLI { ProgressView().controlSize(.small) }
                Button("Test command") { testCLICommand() }
                    .buttonStyle(.settingsSecondary)
                    .disabled(isTestingCLI || appSettings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if let cliTestSuccess {
            SettingsStackedRow {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsStatusPill("Command ran", kind: .success)
                    if !cliTestSuccess.isEmpty {
                        Text(cliTestSuccess)
                            .uiFont(.system(size: 11).monospaced())
                            .foregroundStyle(palette.text.color)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        if let cliTestError {
            SettingsStackedRow { SettingsErrorDetails(summary: "Command test failed", error: cliTestError) }
        }
    }

    private func testCLICommand() {
        guard !isTestingCLI else { return }
        isTestingCLI = true
        cliTestSuccess = nil
        cliTestError = nil
        let config = appSettings.localCLIConfig
        Task {
            do {
                let output = try await LocalCLIService().runTest(config: config)
                cliTestSuccess = String(output.prefix(500))
            } catch {
                cliTestError = error.localizedDescription
            }
            isTestingCLI = false
        }
    }
}
