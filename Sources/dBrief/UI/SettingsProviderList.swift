import SwiftUI

/// Which endpoint list a `SettingsProviderList` manages.
enum SettingsProviderKind {
    case transcription, ai

    var presets: [ProviderPreset] {
        switch self {
        case .transcription: ProviderPresets.transcription
        case .ai: ProviderPresets.ai
        }
    }

    var customEndpoint: Endpoint {
        switch self {
        case .transcription: Endpoint(name: "", baseURL: "http://localhost:8080", modelName: "whisper-1")
        case .ai: ProviderPresets.custom(modelPlaceholder: "llama3")
        }
    }

    var showsOutputTokenLimit: Bool { self == .ai }
    var namePlaceholder: String { self == .ai ? "My LLM server" : "My Whisper server" }
    var urlPlaceholder: String { self == .ai ? "http://localhost:11434" : "http://localhost:8080" }
    var modelPlaceholder: String { self == .ai ? "llama3" : "whisper-1" }
    var noun: String { self == .ai ? "AI provider" : "transcription service" }
}

/// Pure list rules shared by both endpoint lists.
enum SettingsProviderListLogic {
    /// Removing the default clears it, so the first remaining endpoint becomes the
    /// effective default (`AppSettings.default…Endpoint` already falls back to first).
    static func remove(_ id: UUID, from endpoints: [Endpoint], defaultID: UUID?) -> (endpoints: [Endpoint], defaultID: UUID?) {
        (endpoints.filter { $0.id != id }, defaultID == id ? nil : defaultID)
    }

    /// Mirrors `AppSettings.defaultTranscriptionEndpoint` / `defaultAIEndpoint`.
    static func isDefault(_ endpoint: Endpoint, in endpoints: [Endpoint], defaultID: UUID?) -> Bool {
        let effective = endpoints.first { $0.id == defaultID } ?? endpoints.first
        return effective?.id == endpoint.id
    }

    static func subtitle(for endpoint: Endpoint) -> String {
        var host = endpoint.baseURL
        if let components = URLComponents(string: endpoint.baseURL), let name = components.host {
            host = components.port.map { "\(name):\($0)" } ?? name
        }
        let model = endpoint.modelName.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? host : "\(host) · \(model)"
    }
}

/// One endpoint list for transcription services and AI providers: rows with a
/// Default pill and an actions menu, an add-from-preset menu, and an inline editor.
/// Inline rather than a sheet: text fields in sheets don't get keyboard focus in
/// this menu-bar app's Settings window.
struct SettingsProviderList: View {
    let kind: SettingsProviderKind
    @Binding var endpoints: [Endpoint]
    @Binding var defaultID: UUID?
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    @State private var editing: Endpoint?
    @State private var isNew = false
    @State private var outputTokenLimitText = ""
    @State private var testResult: SettingsTranscriptionTab.TestResult?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        if let draft = editing {
            editor(draft)
        } else {
            if endpoints.isEmpty {
                SettingsRow("No \(kind.noun)s yet", caption: "Add one from a preset or enter your own server.")
            }
            ForEach(endpoints) { endpoint in
                SettingsRow(verbatim: endpoint.name, caption: SettingsProviderListLogic.subtitle(for: endpoint),
                            systemImage: "link") {
                    HStack(spacing: 8) {
                        if SettingsProviderListLogic.isDefault(endpoint, in: endpoints, defaultID: defaultID) {
                            SettingsStatusPill("Default", kind: .accent)
                        }
                        Menu {
                            Button("Edit…") { beginEdit(endpoint, isNew: false) }
                            Button("Set as default") { defaultID = endpoint.id }
                            Divider()
                            Button("Remove", role: .destructive) {
                                let result = SettingsProviderListLogic.remove(endpoint.id, from: endpoints, defaultID: defaultID)
                                endpoints = result.endpoints
                                defaultID = result.defaultID
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(endpoint.name)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEdit(endpoint, isNew: false) }
            }
            SettingsRow("Add a \(kind.noun)") {
                Menu("Add…") {
                    ForEach(kind.presets) { preset in
                        Button(preset.name) { beginEdit(preset.makeEndpoint(), isNew: true) }
                    }
                    Divider()
                    Button("Custom…") { beginEdit(kind.customEndpoint, isNew: true) }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
    }

    // MARK: Editor

    private func beginEdit(_ endpoint: Endpoint, isNew: Bool) {
        editing = endpoint
        self.isNew = isNew
        outputTokenLimitText = endpoint.maxOutputTokens.map { String($0) } ?? ""
        testResult = nil
        availableModels = []
    }

    private var isOutputTokenLimitValid: Bool {
        let value = outputTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || (Int(value).map { $0 > 0 } ?? false)
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<Endpoint, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { editing?[keyPath: keyPath] ?? fallback },
                set: { editing?[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private func editor(_ draft: Endpoint) -> some View {
        SettingsStackedRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "Add \(kind.noun)" : "Edit \(kind.noun)")
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                if let note = providerNote(for: draft) {
                    Text(note)
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        SettingsRow("Name") {
            NativeTextField(placeholder: kind.namePlaceholder, text: draftBinding(\.name, ""),
                            accessibilityName: "\(kind.noun) name")
                .frame(width: 260, height: 22)
        }
        SettingsRow("Base URL") {
            NativeTextField(placeholder: kind.urlPlaceholder, text: draftBinding(\.baseURL, ""),
                            accessibilityName: "\(kind.noun) base URL")
                .frame(width: 260, height: 22)
        }
        SettingsRow("Model", caption: availableModels.isEmpty ? nil
                    : "Loaded \(availableModels.count) model\(availableModels.count == 1 ? "" : "s") from the server.") {
            if availableModels.isEmpty {
                NativeTextField(placeholder: kind.modelPlaceholder, text: draftBinding(\.modelName, ""),
                                accessibilityName: "\(kind.noun) model")
                    .frame(width: 260, height: 22)
            } else {
                Picker("Model", selection: draftBinding(\.modelName, "")) {
                    ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                }
                .pickerStyle(.menu)
            }
        }
        SettingsRow("API key", caption: "Optional for local servers.") {
            NativeTextField(placeholder: "", text: draftBinding(\.apiKey, ""), isSecure: true,
                            accessibilityName: "\(kind.noun) API key (optional)")
                .frame(width: 260, height: 22)
        }
        if kind.showsOutputTokenLimit {
            SettingsRow("Output token limit",
                        caption: isOutputTokenLimitValid
                            ? "Blank is automatic (\(draft.recommendedMaxOutputTokens.formatted()) tokens). Covers analysis and chat, including reasoning."
                            : "Enter a positive whole number, or leave blank for automatic.") {
                NativeTextField(placeholder: "Automatic", text: $outputTokenLimitText,
                                accessibilityName: "\(kind.noun) output token limit")
                    .frame(width: 120, height: 22)
            }
        }
        if let testResult {
            SettingsStackedRow {
                switch testResult {
                case .testing:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Testing…") }
                        .uiFont(.system(size: 12))
                case .success:
                    SettingsStatusPill("Connection successful", kind: .success)
                case .failure(let error):
                    SettingsErrorDetails(summary: "Connection failed", error: error)
                }
            }
        }
        SettingsStackedRow {
            HStack(spacing: 8) {
                Button(isLoadingModels ? "Testing…" : "Test connection") { testAndLoadModels() }
                    .buttonStyle(.settingsSecondary)
                    .disabled(isLoadingModels)
                Spacer()
                Button("Cancel") { editing = nil }
                    .buttonStyle(.settingsSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.settingsPrimary)
                    .disabled(draft.name.isEmpty || draft.baseURL.isEmpty || draft.modelName.isEmpty || !isOutputTokenLimitValid)
            }
        }
    }

    private func providerNote(for draft: Endpoint) -> String? {
        switch draft.provider {
        case .anthropic: "Anthropic Messages API (native). Enter your model name and API key."
        case .deepgram: "Deepgram native API. Long files and speaker identification are handled server-side."
        case .elevenLabs: "ElevenLabs native API. Long files are handled server-side."
        case .openAICompatible: nil
        }
    }

    private func save() {
        guard var draft = editing, isOutputTokenLimitValid else { return }
        if kind.showsOutputTokenLimit {
            draft.maxOutputTokens = Int(outputTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let index = endpoints.firstIndex(where: { $0.id == draft.id }) {
            endpoints[index] = draft
        } else {
            endpoints.append(draft)
        }
        editing = nil
    }

    private func testAndLoadModels() {
        guard let draft = editing else { return }
        testResult = .testing
        isLoadingModels = true
        Task {
            do {
                let models: [String] = switch kind {
                case .transcription: try await TranscriptionService().fetchAvailableModels(endpoint: draft)
                case .ai: try await AIService().fetchAvailableModels(endpoint: draft)
                }
                availableModels = models
                if !models.isEmpty, !models.contains(draft.modelName), let first = models.first {
                    editing?.modelName = first
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
