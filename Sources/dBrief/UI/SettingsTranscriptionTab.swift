import SwiftUI
import dBriefWire

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
    @State private var whisperModels: [WhisperModelInfo] = []
    @State private var isFetchingWhisperModels = false
    @State private var whisperModelFetchError: String?
    @State private var showAllWhisperModels = false
    @State private var showModelHelp = false

    enum TestResult {
        case testing
        case success
        case failure(String)
    }

    private func fetchWhisperModels() {
        guard !isFetchingWhisperModels else { return }
        isFetchingWhisperModels = true
        whisperModelFetchError = nil
        Task {
            let modelNames = await recordingManager.fetchAvailableWhisperModels()
            if modelNames.isEmpty {
                whisperModels = WhisperModelInfo.fallbackModelNames
                    .map { WhisperModelInfo.parse($0) }.sorted()
                whisperModelFetchError = "Using offline model list — couldn't reach HuggingFace."
            } else {
                whisperModels = modelNames.map { WhisperModelInfo.parse($0) }.sorted()
            }
            isFetchingWhisperModels = false
        }
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
                if appSettings.powerUserMode {
                    if appSettings.transcriptionEngine == .localWhisper || appSettings.transcriptionEngine == .remoteEndpoint {
                        Section("Custom Vocabulary") { vocabularySection }
                            .listRowBackground(Color.clear)
                    }
                }
                if appSettings.transcriptionEngine == .remoteEndpoint {
                    Section("Endpoints") { endpointsSection }
                        .listRowBackground(Color.clear)
                    if appSettings.powerUserMode {
                        Section("Large File Handling") { chunkingSection }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.smallSwitch)
            .padding(.top, -20)
        }
    }

    private func formatMemory(_ mb: Int) -> String {
        let gb = Double(mb) / 1_024
        return String(format: "%.1f GB", gb)
    }

    private var engineSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Transcription engine:") {
                Picker("", selection: $settings.transcriptionEngine) {
                    ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.isRecommended ? "\(engine.displayName)  ·  Recommended" : engine.displayName).tag(engine)
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
            case .parakeetLocal:
                parakeetSection
            case .localWhisper:
                whisperSection
            case .remoteEndpoint:
                Text("Use a remote Whisper API or server. Requires an endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TranscriptionEngineGuideView()
        }
    }

    @ViewBuilder
    private var parakeetSection: some View {
        @Bindable var settings = appSettings
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Model:") {
                Picker("", selection: $settings.parakeetModelVariant) {
                    ForEach(ParakeetModelInfo.variants) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280, alignment: .trailing)
            }

            if let selected = ParakeetModelInfo.variants.first(where: { $0.id == settings.parakeetModelVariant }) {
                Text("~\(formatMemory(selected.estimatedMemoryMB)) required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("On-device transcription via FluidAudio and CoreML. Audio never leaves your Mac. Model is downloaded once from HuggingFace (~1.5–1.8 GB). v2 is English-only; v3 supports 25 European languages. Language selection has no effect. Speaker diarization is not supported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ModelDownloadButton(kind: .parakeet)

            Button("Purge local Parakeet model") {
                Task {
                    do {
                        try await recordingManager.purgeLocalParakeetModel()
                        purgeMessage = "Local Parakeet model cache removed."
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

    @ViewBuilder
    private var whisperSection: some View {
        @Bindable var settings = appSettings
        let selectedModel = whisperModels.first(where: { $0.id == settings.whisperModelName })

        VStack(alignment: .leading, spacing: 10) {
            // — Model group header with help popover —
            HStack(spacing: 6) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showModelHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .popover(isPresented: $showModelHelp, arrowEdge: .bottom) {
                    Text("Smaller models are faster but less accurate. Larger models are more accurate but use more memory and time. When in doubt, keep the recommended one.")
                        .font(.callout)
                        .padding()
                        .frame(width: 260)
                }
            }

            // — Model card —
            if isFetchingWhisperModels && whisperModels.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill)))
            } else {
                let modelsToShow = showAllWhisperModels ? whisperModels : whisperModels.filter { model in
                    model.isRecommended ||
                    model.family == "tiny" || model.family == "small" || model.family == "medium" ||
                    (model.family == "large-v3" && !model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "large-v3" && model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "distil-large-v3" && !model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil) ||
                    (model.family == "distil-large-v3" && model.isTurbo && !model.isEnglishOnly && model.quantizedSizeMB == nil)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(selectedModel?.displayName ?? settings.whisperModelName)
                                .font(.body).fontWeight(.semibold)
                            if selectedModel?.isRecommended == true {
                                Text("Recommended")
                                    .font(.caption2).fontWeight(.semibold)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        if let selectedModel {
                            Text("~\(formatMemory(selectedModel.estimatedMemoryMB)) memory")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("", selection: $settings.whisperModelName) {
                        if modelsToShow.isEmpty {
                            Text("openai_whisper-small").tag("openai_whisper-small")
                        } else {
                            ForEach(modelsToShow, id: \.id) { model in
                                Text(model.isRecommended ? "\(model.displayName)  ·  Recommended" : model.displayName)
                                    .tag(model.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill)))

                // — Per-model descriptor —
                if let selectedModel {
                    Text(selectedModel.plainDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // — Large-model safety warning —
                if let selectedModel, selectedModel.estimatedMemoryMB > 4_096 {
                    Label("Large models run best with other apps closed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // — Download status / action (wired) —
                ModelDownloadButton(kind: .whisper)
            }

            // — Diarization (plain label, jargon in caption) —
            Toggle(isOn: $settings.diarizationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify different speakers")
                    Text("Diarization — labels who said what. Slower, uses ~500 MB more memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // — Advanced (collapsed) —
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Where it runs")
                            Text("Compute units. Leave on Automatic unless transcription fails on large models.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.whisperComputeUnits) {
                            ForEach(AppSettings.WhisperComputeUnits.allCases, id: \.self) { unit in
                                Text(unit.friendlyName).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    Toggle(isOn: $showAllWhisperModels) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show all models")
                            Text("Adds experimental, English-only, and quantized variants to the list.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button {
                            fetchWhisperModels()
                        } label: {
                            Label("Refresh model list", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Refresh model list from HuggingFace")
                        Spacer()
                    }
                    if let error = whisperModelFetchError {
                        Label(error, systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

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
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
        .onAppear { fetchWhisperModels() }
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
            }
            if settings.transcriptionEngine == .appleSpeech && settings.transcriptionLanguage.isEmpty {
                Text("Apple Speech uses the system language when set to Auto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.transcriptionEngine == .localWhisper && settings.transcriptionLanguage.isEmpty {
                Text("WhisperKit auto-detects language when set to Auto-detect.")
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

    private var chunkingSection: some View {
        @Bindable var settings = appSettings
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable chunking for large files", isOn: $settings.remoteChunkingEnabled)

            if settings.remoteChunkingEnabled {
                LabeledContent("Max upload size:") {
                    Stepper(
                        "\(settings.remoteChunkMaxUploadMB) MB",
                        value: $settings.remoteChunkMaxUploadMB,
                        in: 1...100
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                LabeledContent("Overlap:") {
                    Stepper(
                        "\(Int(settings.remoteChunkOverlapSeconds)) sec",
                        value: $settings.remoteChunkOverlapSeconds,
                        in: 0...15,
                        step: 1
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                LabeledContent("Retry count:") {
                    Stepper(
                        "\(settings.remoteChunkRetryCount)",
                        value: $settings.remoteChunkRetryCount,
                        in: 0...5
                    )
                    .frame(width: 180, alignment: .trailing)
                }

                Text("Large files are split into smaller chunks, transcribed sequentially, and merged into a single timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
