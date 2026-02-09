import SwiftUI

struct SettingsTranscriptionTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedEndpointId: UUID?
    @State private var isEditing = false
    @State private var editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:8080", modelName: "whisper-1")
    @State private var isNew = false
    @State private var testResult: TestResult?

    enum TestResult {
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    engineSection
                    languageSection
                    if appSettings.transcriptionEngine == .remoteEndpoint {
                        vocabularySection
                        endpointsSection
                    }
                }
                .padding()
            }
        }
    }

    private var engineSection: some View {
        @Bindable var settings = appSettings
        return SettingsSection(title: "Engine") {
            HStack {
                Text("Transcription engine:")
                Spacer()
                Picker("", selection: $settings.transcriptionEngine) {
                    ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            switch settings.transcriptionEngine {
            case .appleSpeech:
                Text("On-device, no server needed. Quality may be lower than Whisper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .localWhisper:
                Text("On-device Whisper with downloadable model. Best privacy, strong accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .remoteEndpoint:
                Text("Use a remote Whisper API or server. Requires an endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var languageSection: some View {
        @Bindable var settings = appSettings
        return SettingsSection(title: "Language") {
            HStack {
                Text("Audio language:")
                Spacer()
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
                .frame(width: 160)
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
        return SettingsSection(title: "Custom Vocabulary") {
            Text("Helps Whisper recognize proper nouns, acronyms, and domain-specific terms.")
                .font(.caption)
                .foregroundStyle(.secondary)
            NativeTextField(placeholder: "e.g. Acme Corp, JIRA, Kubernetes, GraphQL", text: $settings.whisperPrompt)
                .frame(height: 22)
        }
    }

    private var endpointsSection: some View {
        SettingsSection(title: "Endpoints") {
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
                    isEditing = true
                } label: {
                    Image(systemName: "plus")
                }

                Button {
                    if let id = selectedEndpointId {
                        appSettings.transcriptionEndpoints.removeAll { $0.id == id }
                        selectedEndpointId = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedEndpointId == nil)

                Spacer()

                Button("Set as Default") {
                    appSettings.defaultTranscriptionEndpointId = selectedEndpointId
                }
                .disabled(selectedEndpointId == nil)
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
                    NativeTextField(placeholder: "whisper-1", text: $editingEndpoint.modelName)
                        .frame(height: 22)
                }
                GridRow {
                    Text("API Key (optional):")
                    NativeTextField(placeholder: "", text: $editingEndpoint.apiKey, isSecure: true)
                        .frame(height: 22)
                }
            }
            .frame(maxWidth: 350)

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
                    testResult = .testing
                    Task {
                        do {
                            let service = TranscriptionService()
                            let success = try await service.testConnection(endpoint: editingEndpoint)
                            testResult = success ? .success : .failure("Connection failed")
                        } catch {
                            testResult = .failure(error.localizedDescription)
                        }
                    }
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
}
