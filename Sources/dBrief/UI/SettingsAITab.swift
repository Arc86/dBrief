import SwiftUI
import dBriefWire

struct SettingsAITab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var voicePreview = VoicePreviewPlayer()
    @State private var selectedEndpointId: UUID?
    @State private var isEditing = false
    @State private var editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:11434", modelName: "llama3")
    @State private var isNew = false
    @State private var testResult: SettingsTranscriptionTab.TestResult?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var expandedPrompt: String?
    @State private var purgeMessage: String?
    @State private var isTestingCLI = false
    @State private var cliTestSuccess: String?
    @State private var cliTestError: String?
    @State private var cliConfigExpanded = false

    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            @Bindable var settings = appSettings
            Form {
                Section {
                    Toggle("Enable AI processing", isOn: $settings.aiProcessingEnabled)
                } footer: {
                    Text("When off, recordings are transcribed only — no summary, action items, or tag analysis. This gates every AI feature below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Engine") {
                    Picker("AI engine", selection: $settings.aiEngine) {
                        ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                            Text(engine.isRecommended ? "\(engine.displayName)  ·  Recommended" : engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(engineDescription(for: settings.aiEngine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if appSettings.powerUserMode, settings.aiEngine == .qwenLocal {
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
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            }
                        }
                    }
                    if appSettings.powerUserMode, settings.aiEngine == .qwenLocal {
                        ModelDownloadButton(kind: .gemma)

                        Button("Purge local Gemma model") {
                            Task {
                                do {
                                    try await recordingManager.purgeLocalQwenModel()
                                    purgeMessage = "Local Gemma model cache removed."
                                } catch {
                                    purgeMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if let purgeMessage {
                            Text(purgeMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                    .listRowBackground(Color.clear)
                Section("Post-Recording Defaults") {
                    Toggle("Auto-transcribe after recording", isOn: $settings.autoTranscribe)
                    Toggle("Generate summary", isOn: $settings.autoSummary)
                    Toggle("Extract action items", isOn: $settings.autoActionItems)
                    Toggle("Analyze tags & sentiment", isOn: $settings.autoTags)
                }
                    .listRowBackground(Color.clear)
                if appSettings.powerUserMode {
                    Section("Prompts") {
                        promptRow(label: "Summary", key: "summary", text: $settings.summaryPrompt, defaultText: AppSettings.defaultSummaryPrompt)
                        promptRow(label: "Action Items", key: "actionItems", text: $settings.actionItemsPrompt, defaultText: AppSettings.defaultActionItemsPrompt)
                        promptRow(label: "Tags & Sentiment", key: "tags", text: $settings.tagsPrompt, defaultText: AppSettings.defaultTagsPrompt)
                        promptRow(label: "Spoken Summary", key: "spokenSummary", text: $settings.spokenSummaryPrompt, defaultText: AppSettings.defaultSpokenSummaryPrompt)
                    }
                        .listRowBackground(Color.clear)
                }
                Section("Spoken Voice") {
                    Picker("Voice model", selection: $settings.ttsModelSize) {
                        ForEach(TTSModelSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("1.7B sounds the most natural and follows the voice style below. 0.6B is lighter on memory (better for 16 GB Macs) but ignores the style instruction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Voice", selection: $settings.ttsVoice) {
                        ForEach(TTSVoice.allCases, id: \.self) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(settings.ttsVoice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Language", selection: $settings.ttsLanguage) {
                        ForEach(TTSLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Each voice sounds best in its native language. Choose the language your summary is written in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    voicePreviewRow
                    promptRow(label: "Voice Style", key: "ttsVoiceStyle", text: $settings.ttsDeliveryInstruction, defaultText: AppSettings.defaultTTSDeliveryInstruction)
                }
                    .listRowBackground(Color.clear)
                if appSettings.aiEngine == .remoteEndpoint {
                    Section("Endpoints") {
                        endpointsSection
                    }
                        .listRowBackground(Color.clear)
                }
                if appSettings.aiEngine == .localCLI {
                    Section("Local CLI") {
                        localCLISection
                    }
                        .listRowBackground(Color.clear)
                    Section("Chat Fallback") {
                        chatFallbackSection
                    }
                        .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.smallSwitch)
            .padding(.top, -20)
        }
    }

    /// Audition the selected voice/language/model/style with a short sample.
    @ViewBuilder
    private var voicePreviewRow: some View {
        HStack(spacing: 10) {
            switch voicePreview.state {
            case .idle, .failed:
                Button {
                    voicePreview.preview(
                        voice: appSettings.ttsVoice,
                        language: appSettings.ttsLanguage,
                        model: appSettings.ttsModelSize,
                        instruction: appSettings.ttsDeliveryInstruction,
                        plugin: recordingManager.localPlugin
                    )
                } label: {
                    Label("Preview voice", systemImage: "play.circle")
                }
                if case let .failed(message) = voicePreview.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            case .playing:
                Button(role: .cancel) {
                    voicePreview.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            case .preparingVoice(let progress):
                ProgressView().controlSize(.small)
                Text(progress != nil ? "Preparing voice… \(Int((progress ?? 0) * 100))%" : "Preparing voice…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .synthesizing:
                ProgressView().controlSize(.small)
                Text("Synthesizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onDisappear { voicePreview.stop() }
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

    private func promptRow(label: String, key: String, text: Binding<String>, defaultText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedPrompt = expandedPrompt == key ? nil : key
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expandedPrompt == key ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 10)
                        Text(label)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if text.wrappedValue != defaultText {
                    Button("Reset") {
                        text.wrappedValue = defaultText
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if expandedPrompt == key {
                NativeTextView(text: text)
                    .frame(height: 80)
            }
        }
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
                                cliTestSuccess = nil
                                cliTestError = nil
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                NativeTextView(text: localCLICommandBinding, monospaced: true)
                    .frame(height: 70)

                HStack {
                    Text("Timeout")
                    Spacer()
                    Picker("Timeout", selection: Binding(
                        get: { appSettings.localCLIConfig.timeoutSeconds },
                        set: { appSettings.localCLIConfig.timeoutSeconds = $0 }
                    )) {
                        ForEach([15, 30, 45, 60, 90, 120, 180, 300, 600], id: \.self) { secs in
                            Text("\(secs)s").tag(secs)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Text("Environment variables available: DBRIEF_SYSTEM_PROMPT, DBRIEF_USER_PROMPT, DBRIEF_FULL_PROMPT. The full prompt is also written to stdin for every command. The command must print a JSON object (title_concept, summary, action_items, tags, sentiment) to stdout. The command runs with your login shell's PATH; if a tool still isn't found, use its absolute path (find it with `which <tool>` in Terminal).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Test command") { testCLICommand() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isTestingCLI || appSettings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isTestingCLI {
                        ProgressView().controlSize(.small)
                    }
                }

                if let cliTestSuccess {
                    Text(cliTestSuccess.isEmpty ? "Command ran successfully (no output)." : "Output: \(cliTestSuccess)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let cliTestError {
                    Text(cliTestError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("CLI configuration")
        }
        .onAppear {
            // Open by default the first time, when nothing is configured yet.
            if appSettings.localCLIConfig.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appSettings.aiEndpoints.isEmpty {
                Text("No endpoints configured. Click + to add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(appSettings.aiEndpoints) { endpoint in
                    endpointRow(endpoint)
                }
            }

            HStack {
                Menu {
                    ForEach(ProviderPresets.ai) { preset in
                        Button(preset.name) { beginAddEndpoint(preset.makeEndpoint()) }
                    }
                    Divider()
                    Button("Custom…") { beginAddEndpoint(ProviderPresets.custom(modelPlaceholder: "llama3")) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    if let id = selectedEndpointId {
                        appSettings.aiEndpoints.removeAll { $0.id == id }
                        selectedEndpointId = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedEndpointId == nil)
                .buttonStyle(.bordered)

                Spacer()

                Button("Set as Default") {
                    appSettings.defaultAIEndpointId = selectedEndpointId
                }
                .disabled(selectedEndpointId == nil)
                .buttonStyle(.bordered)
            }
        }
    }

    private func endpointRow(_ endpoint: Endpoint) -> some View {
        let isDefault = endpoint.id == appSettings.defaultAIEndpointId
            || (appSettings.defaultAIEndpointId == nil
                && endpoint.id == appSettings.aiEndpoints.first?.id)
        let isSelected = endpoint.id == selectedEndpointId

        return HStack {
            VStack(alignment: .leading) {
                Text(endpoint.name)
                    .fontWeight(.medium)
                Text("\(endpoint.baseURL) (\(endpoint.modelName))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            selectedEndpointId = endpoint.id
        }
        .onTapGesture(count: 2) {
            editingEndpoint = endpoint
            isNew = false
            testResult = nil
            availableModels = []
            isEditing = true
        }
    }

    private func beginAddEndpoint(_ endpoint: Endpoint) {
        editingEndpoint = endpoint
        isNew = true
        testResult = nil
        availableModels = []
        isEditing = true
    }

    private var endpointEditor: some View {
        VStack(spacing: 16) {
            Spacer()

            Text(isNew ? "Add Endpoint" : "Edit Endpoint")
                .font(.title3)
                .fontWeight(.medium)

            if editingEndpoint.provider == .anthropic {
                Text("Anthropic Messages API (native). Enter your model name and API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text("Name:")
                    NativeTextField(placeholder: "My LLM Server", text: $editingEndpoint.name)
                        .frame(height: 22)
                }
                GridRow {
                    Text("Base URL:")
                    NativeTextField(placeholder: "http://localhost:11434", text: $editingEndpoint.baseURL)
                        .frame(height: 22)
                }
                GridRow {
                    Text("Model:")
                    if availableModels.isEmpty {
                        NativeTextField(placeholder: "llama3", text: $editingEndpoint.modelName)
                            .frame(height: 22)
                    } else {
                        Picker("", selection: $editingEndpoint.modelName) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(height: 22)
                    }
                }
                GridRow {
                    Text("API Key (optional):")
                    NativeTextField(placeholder: "", text: $editingEndpoint.apiKey, isSecure: true)
                        .frame(height: 22)
                }
            }
            .frame(maxWidth: 350)

            if isLoadingModels {
                ProgressView("Loading models...")
                    .controlSize(.small)
            } else if !availableModels.isEmpty {
                Text("Loaded \(availableModels.count) model\(availableModels.count == 1 ? "" : "s") from endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let testResult {
                HStack {
                    switch testResult {
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing...")
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connection successful")
                    case .failure(let error):
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .lineLimit(2)
                    }
                }
                .font(.callout)
            }

            HStack {
                Button("Test Connection") {
                    testAndLoadModels()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    if isNew {
                        appSettings.aiEndpoints.append(editingEndpoint)
                    } else {
                        if let idx = appSettings.aiEndpoints.firstIndex(where: { $0.id == editingEndpoint.id }) {
                            appSettings.aiEndpoints[idx] = editingEndpoint
                        }
                    }
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(editingEndpoint.name.isEmpty || editingEndpoint.baseURL.isEmpty || editingEndpoint.modelName.isEmpty)
            }
            .frame(maxWidth: 350)

            Spacer()
        }
        .padding()
    }

    private func testAndLoadModels() {
        testResult = .testing
        isLoadingModels = true
        Task {
            do {
                let service = AIService()
                let models = try await service.fetchAvailableModels(endpoint: editingEndpoint)
                availableModels = models
                if !models.contains(editingEndpoint.modelName), let firstModel = models.first {
                    editingEndpoint.modelName = firstModel
                }
                testResult = .success
            } catch {
                availableModels = []
                testResult = .failure(error.localizedDescription)
            }
            isLoadingModels = false
        }
    }
}
