import SwiftUI

struct SettingsAITab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var selectedEndpointId: UUID?
    @State private var isEditing = false
    @State private var editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:11434", modelName: "llama3")
    @State private var isNew = false
    @State private var testResult: SettingsTranscriptionTab.TestResult?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var expandedPrompt: String?
    @State private var purgeMessage: String?

    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            @Bindable var settings = appSettings
            Form {
                Section {
                    Toggle("Enable AI processing", isOn: $settings.aiProcessingEnabled)
                    Text("When off, recordings are transcribed only — no summary, action items, or tag analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Engine") {
                    Picker("AI engine", selection: $settings.aiEngine) {
                        ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
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
                    }
                        .listRowBackground(Color.clear)
                }
                if appSettings.aiEngine == .remoteEndpoint {
                    Section("Endpoints") {
                        endpointsSection
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

    private func engineDescription(for engine: AppSettings.AIEngine) -> String {
        switch engine {
        case .appleIntelligence:
            "On-device Foundation Models. Requires macOS 26+ with Apple Silicon."
        case .qwenLocal:
            "On-device MLX Gemma 4 E4B 4-bit model. Downloaded once from Hugging Face."
        case .remoteEndpoint:
            "Use a remote LLM endpoint configured below."
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
                Button {
                    editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:11434", modelName: "llama3")
                    isNew = true
                    testResult = nil
                    availableModels = []
                    isEditing = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)

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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.2))
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

    private var endpointEditor: some View {
        VStack(spacing: 16) {
            Spacer()

            Text(isNew ? "Add Endpoint" : "Edit Endpoint")
                .font(.title3)
                .fontWeight(.medium)

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
