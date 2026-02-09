import SwiftUI

struct SettingsAITab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedEndpointId: UUID?
    @State private var isEditing = false
    @State private var editingEndpoint = Endpoint(name: "", baseURL: "http://localhost:11434", modelName: "llama3")
    @State private var isNew = false
    @State private var testResult: SettingsTranscriptionTab.TestResult?
    @State private var expandedPrompt: String?

    var body: some View {
        if isEditing {
            endpointEditor
        } else {
            @Bindable var settings = appSettings
            Form {
                Section("Engine") {
                    Toggle("Use built-in Apple Intelligence", isOn: $settings.useBuiltInAI)
                    Text("On-device AI processing. Requires macOS 26+ with Apple Silicon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .listRowBackground(Color.clear)
                Section("Post-Recording Defaults") {
                    Toggle("Auto-transcribe after recording", isOn: $settings.autoTranscribe)
                    Toggle("Generate summary", isOn: $settings.autoSummary)
                    Toggle("Extract action items", isOn: $settings.autoActionItems)
                    Toggle("Analyze tags & sentiment", isOn: $settings.autoTags)
                }
                    .listRowBackground(Color.clear)
                Section("Prompts") {
                    promptRow(label: "Summary", key: "summary", text: $settings.summaryPrompt, defaultText: AppSettings.defaultSummaryPrompt)
                    promptRow(label: "Action Items", key: "actionItems", text: $settings.actionItemsPrompt, defaultText: AppSettings.defaultActionItemsPrompt)
                    promptRow(label: "Tags & Sentiment", key: "tags", text: $settings.tagsPrompt, defaultText: AppSettings.defaultTagsPrompt)
                }
                    .listRowBackground(Color.clear)
                if !appSettings.useBuiltInAI {
                    Section("Endpoints") {
                        endpointsSection
                    }
                        .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.switch)
            .controlSize(.regular)
            .padding(.top, -20)
        }
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
                    NativeTextField(placeholder: "llama3", text: $editingEndpoint.modelName)
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
                            let service = AIService()
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
}
