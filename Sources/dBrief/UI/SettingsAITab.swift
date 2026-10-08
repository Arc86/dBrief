import SwiftUI
import dBriefWire

struct SettingsAITab: View {
    @Environment(AppSettings.self) private var appSettings
    private var searchAdvanced: Bool { searchRequest?.section.isAdvanced ?? false }
    @Environment(\.settingsSearchRequest) private var searchRequest
    @Environment(RecordingManager.self) private var recordingManager
    @State private var purgeMessage: String?
    @State private var isTestingCLI = false
    @State private var cliTestSuccess: String?
    @State private var cliTestError: String?
    @State private var cliConfigExpanded = false

    var body: some View {
            @Bindable var settings = appSettings
            Form {
                Section {
                    Toggle("Enable AI processing", isOn: $settings.aiProcessingEnabled)
                } header: {
                    SettingsSearchHeading("AI Analysis", section: .aiEnabled)
                } footer: {
                    Text("Controls summary, action-item, and tag analysis by default. Transcription remains available. Profiles can override this setting.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                if !settings.aiProcessingEnabled {
                    Section {
                        Text("AI analysis is off by default. You can configure the options below for later use or for profiles that enable AI analysis.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Engine", settingsSearch: .aiEngine) {
                    Picker("AI engine", selection: $settings.aiEngine) {
                        ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                            Text(engine.isRecommended ? "\(engine.displayName)  ·  Recommended" : engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(engineDescription(for: settings.aiEngine))
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                    if (appSettings.powerUserMode || searchAdvanced), (settings.aiEngine == .qwenLocal || (searchAdvanced && searchRequest?.section == .aiEngine)) {
                        if settings.aiEngine != .qwenLocal {
                            Text("These model options apply to the local Gemma engine.")
                                .uiFont(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Output language", selection: outputLanguageSelectionBinding) {
                            Text("Match transcript").tag("matchInput")
                            Text("English").tag("english")
                            Text("Dutch").tag("dutch")
                            Text("Custom").tag("custom")
                        }
                        .pickerStyle(.menu)

                        if case .custom(let code) = settings.outputLanguage {
                            HStack {
                                Text("ISO code")
                                Spacer()
                                TextField(
                                    "EN",
                                    text: Binding(
                                        get: { code },
                                        set: { settings.outputLanguage = .custom($0.uppercased()) }
                                    )
                                )
                                .settingsTextField()
                                .frame(width: 90)
                            }
                        }
                    }
                    if (appSettings.powerUserMode || searchAdvanced), (settings.aiEngine == .qwenLocal || (searchAdvanced && searchRequest?.section == .aiEngine)) {
                        ModelDownloadButton(kind: .gemma)

                        Button("Remove downloaded Gemma model") {
                            Task {
                                do {
                                    try await recordingManager.purgeLocalQwenModel()
                                    purgeMessage = "Local Gemma model cache removed."
                                } catch {
                                    purgeMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.typographyBordered)
                        .controlSize(.small)
                        if let purgeMessage {
                            Text(purgeMessage)
                                .uiFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                    .listRowBackground(Color.clear)
                if appSettings.powerUserMode || searchAdvanced {
                    Section {
                        PromptSettingsRow(kind: .summary)
                        PromptSettingsRow(kind: .actionItems)
                        PromptSettingsRow(kind: .tags)
                    } header: {
                        SettingsSearchHeading("Prompts", section: .aiPrompts)
                    } footer: {
                        if appSettings.aiEngine != .remoteEndpoint {
                            Text("On-device and Local CLI engines merge these three prompts into a single structured call, so the model returns one JSON result. The output is always JSON regardless of any “output only…” wording — format the summary (e.g. bullets) inside its text.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                        .listRowBackground(Color.clear)
                }
                if appSettings.aiEngine == .localCLI || searchRequest?.section == .aiCLI || searchRequest?.section == .aiChatFallback {
                    Section("Local CLI", settingsSearch: .aiCLI) {
                        if appSettings.aiEngine != .localCLI {
                            Text("These options apply when Local CLI is selected as the AI engine.")
                                .uiFont(.caption).foregroundStyle(.secondary)
                        }
                        localCLISection
                    }
                        .listRowBackground(Color.clear)
                    Section("Chat Fallback", settingsSearch: .aiChatFallback) {
                        chatFallbackSection
                    }
                        .listRowBackground(Color.clear)
                }
                if searchRequest?.section == .aiProviders || appSettings.aiEngine == .remoteEndpoint
                    || (appSettings.aiEngine == .localCLI && appSettings.chatFallbackEngine == .remoteEndpoint) {
                    Section("AI Providers", settingsSearch: .aiProviders) {
                        VStack(spacing: 0) {
                            SettingsProviderList(kind: .ai, endpoints: $settings.aiEndpoints,
                                                 defaultID: $settings.defaultAIEndpointId)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .settingsFormStyle()
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

    private var localCLISection: some View {
        DisclosureGroup(isExpanded: $cliConfigExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Command")
                    Spacer()
                    Menu("Load Template") {
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
        .buttonStyle(.typographyBorderless)
                    .fixedSize()
                }

                NativeTextView(text: localCLICommandBinding, monospaced: true, accessibilityName: "Local CLI command")
                    .frame(height: 70)

                if appSettings.localCLIConfig.supportsClaudeModel {
                    ClaudeModelPicker(modelID: Binding(
                        get: { appSettings.localCLIConfig.modelID },
                        set: { modelID in
                            appSettings.localCLIConfig.modelID = modelID
                            cliTestSuccess = nil
                            cliTestError = nil
                        }
                    ))
                    Text("An explicit --model option or inline ANTHROPIC_MODEL assignment in the command takes precedence over this picker.")
                        .uiFont(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text("Timeout")
                    Spacer()
                    Picker("Timeout", selection: Binding(
                        get: { appSettings.localCLIConfig.timeoutSeconds },
                        set: { appSettings.localCLIConfig.timeoutSeconds = $0 }
                    )) {
                        ForEach([15, 30, 45, 60, 90, 120, 180, 300, 600, 900, 1200, 1800, 3600], id: \.self) { secs in
                            Text(secs >= 60 ? "\(secs / 60)m" : "\(secs)s").tag(secs)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

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

                if appSettings.localCLIConfig.effortProvider == .claude {
                    CLIReasoningEffortPicker(title: "AI analysis CLI effort", selection: Binding(
                        get: { appSettings.localCLIConfig.effort },
                        set: { effort in
                            appSettings.localCLIConfig.effort = effort
                            cliTestSuccess = nil
                            cliTestError = nil
                        }
                    ), recommendation: .medium)
                    Text("The effort setting applies to this child process. An inline environment assignment in a custom command can override it.")
                        .uiFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Select Claude Code as the effort provider for a Claude wrapper command. Other commands keep their own settings.")
                        .uiFont(.caption).foregroundStyle(.secondary)
                }

                Text("Environment variables available: DBRIEF_SYSTEM_PROMPT, DBRIEF_USER_PROMPT, DBRIEF_FULL_PROMPT. The full prompt is also written to stdin for every command. The command must print a JSON object (title_concept, summary, action_items, tags, sentiment) to stdout. The command runs with your login shell's PATH; if a tool still isn't found, use its absolute path (find it with `which <tool>` in Terminal).")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Test command") { testCLICommand() }
                        .buttonStyle(.typographyBordered)
                        .controlSize(.small)
                        .disabled(isTestingCLI || appSettings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isTestingCLI {
                        ProgressView().controlSize(.small)
                    }
                }

                if let cliTestSuccess {
                    Text(cliTestSuccess.isEmpty ? "Command ran successfully (no output)." : "Output: \(cliTestSuccess)")
                        .uiFont(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let cliTestError {
                    SettingsErrorDetails(summary: "Command test failed", error: cliTestError)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("CLI configuration")
        }
        .onAppear {
            // Open by default the first time, when nothing is configured yet.
            if searchRequest?.section == .aiCLI || appSettings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliConfigExpanded = true
            }
        }
    }

    private var chatFallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Chat engine", selection: Binding(
                get: { appSettings.chatFallbackEngine },
                set: { appSettings.chatFallbackEngine = $0 }
            )) {
                ForEach(AppSettings.AIEngine.allCases.filter { $0 != .localCLI }, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.menu)
            Text("The Local CLI runs once per recording and can't stream, so the transcript chat window uses this engine instead.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            if appSettings.chatFallbackEngine == .remoteEndpoint {
                Text("Chat uses the default endpoint selected below.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
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
