import SwiftUI

struct SettingsTranscriptionTab: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @State private var selectedEndpointId: UUID?
    @State private var isEditing = false
    @State private var editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:8080", modelName: "whisper-1")
    @State private var isNew = false
    @State private var testResult: TestResult?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var purgeMessage: String?

    enum TestResult {
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            Form {
                Section("Engine") { engineSection }
                    .listRowBackground(Color.clear)
                Section("Language") { languageSection }
                    .listRowBackground(Color.clear)
                if appSettings.transcriptionEngine == .localWhisper || appSettings.transcriptionEngine == .remoteEndpoint {
                    Section("Custom Vocabulary") { vocabularySection }
                        .listRowBackground(Color.clear)
                }
                if appSettings.transcriptionEngine == .remoteEndpoint {
                    Section("Endpoints") { endpointsSection }
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

    private var engineSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Transcription engine:") {
                Picker("", selection: $settings.transcriptionEngine) {
                    ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
            }

            switch settings.transcriptionEngine {
            case .appleSpeech:
                Text("On-device, no server needed. Quality may be lower than Whisper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .localWhisper:
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device transcription using WhisperKit small (~460 MB class). Best privacy — audio never leaves your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Model artifacts are downloaded once from Hugging Face (argmaxinc/whisperkit-coreml) with auto language detection and bilingual prompt bias for NL/EN code-switching.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Purge local WhisperKit model") {
                        Task {
                            do {
                                try await recordingManager.purgeLocalWhisperModel()
                                purgeMessage = "Local WhisperKit model cache removed."
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
            case .remoteEndpoint:
                Text("Use a remote Whisper API or server. Requires an endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var languageSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Audio language:") {
                Picker("", selection: $settings.transcriptionLanguage) {
                    Text(settings.transcriptionEngine == .appleSpeech ? "Auto (System language)" : "Auto-detect").tag("")
                    Divider()
                    Text("English").tag("en")
                    Text("Dutch").tag("nl")
                    Text("German").tag("de")
                    Text("French").tag("fr")
                    Text("Spanish").tag("es")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Russian").tag("ru")
                    Text("Arabic").tag("ar")
                    Text("Hindi").tag("hi")
                    Text("Polish").tag("pl")
                    Text("Turkish").tag("tr")
                    Text("Ukrainian").tag("uk")
                    Text("Swedish").tag("sv")
                    Text("Danish").tag("da")
                    Text("Norwegian").tag("no")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
                .disabled(settings.transcriptionEngine == .localWhisper)
            }
            if settings.transcriptionEngine == .appleSpeech && settings.transcriptionLanguage.isEmpty {
                Text("Apple Speech uses the system language when set to Auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.transcriptionEngine == .localWhisper {
                Text("Local Whisper always auto-detects language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vocabularySection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            Text("Helps Whisper recognize proper nouns, acronyms, and domain-specific terms.")
                .font(.caption)
                .foregroundStyle(.secondary)
            NativeTextField(placeholder: "e.g. Acme Corp, JIRA, Kubernetes, GraphQL", text: $settings.whisperPrompt)
                .frame(height: 22)
        }
    }

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appSettings.transcriptionEndpoints.isEmpty {
                Text("No endpoints configured. Click + to add one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(appSettings.transcriptionEndpoints.enumerated()), id: \.element.id) { index, endpoint in
                    endpointRow(endpoint)
                    if index < appSettings.transcriptionEndpoints.count - 1 {
                        Divider()
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:8080", modelName: "whisper-1")
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
                        appSettings.transcriptionEndpoints.removeAll { $0.id == id }
                        selectedEndpointId = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedEndpointId == nil)
                .buttonStyle(.bordered)

                Spacer()

                Button("Set as Default") {
                    appSettings.defaultTranscriptionEndpointId = selectedEndpointId
                }
                .disabled(selectedEndpointId == nil)
                .buttonStyle(.bordered)
            }
        }
    }

    private func endpointRow(_ endpoint: Endpoint) -> some View {
        let isDefault = endpoint.id == appSettings.defaultTranscriptionEndpointId
            || (appSettings.defaultTranscriptionEndpointId == nil
                && endpoint.id == appSettings.transcriptionEndpoints.first?.id)
        let isSelected = endpoint.id == selectedEndpointId

        return HStack {
            VStack(alignment: .leading) {
                Text(endpoint.name)
                    .fontWeight(.medium)
                Text(endpoint.baseURL)
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
                    NativeTextField(placeholder: "My Whisper Server", text: $editingEndpoint.name)
                        .frame(height: 22)
                }
                GridRow {
                    Text("Base URL:")
                    NativeTextField(placeholder: "http://localhost:8080", text: $editingEndpoint.baseURL)
                        .frame(height: 22)
                }
                GridRow {
                    Text("Model:")
                    if availableModels.isEmpty {
                        NativeTextField(placeholder: "whisper-1", text: $editingEndpoint.modelName)
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
                        appSettings.transcriptionEndpoints.append(editingEndpoint)
                    } else {
                        if let idx = appSettings.transcriptionEndpoints.firstIndex(where: { $0.id == editingEndpoint.id }) {
                            appSettings.transcriptionEndpoints[idx] = editingEndpoint
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
                let service = TranscriptionService()
                let models = try await service.fetchAvailableModels(endpoint: editingEndpoint)
                availableModels = models
                if !models.isEmpty, !models.contains(editingEndpoint.modelName), let firstModel = models.first {
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
