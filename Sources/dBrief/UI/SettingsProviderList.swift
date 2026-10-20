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
    var namePlaceholder: String { self == .ai ? String(localized: "My LLM server") : String(localized: "My Whisper server") }
    var urlPlaceholder: String { self == .ai ? "http://localhost:11434" : "http://localhost:8080" }
    var modelPlaceholder: String { self == .ai ? "llama3" : "whisper-1" }
    var addLabel: String { self == .ai ? String(localized: "Add an AI provider") : String(localized: "Add a transcription service") }
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
        if let current = editing {
            editor(draftBinding(fallback: current))
        } else {
            if endpoints.isEmpty {
                SettingsRow(kind == .ai ? "No AI providers yet" : "No transcription services yet", caption: "Add one from a preset or enter your own server.")
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
                            Button("Remove…", role: .destructive) {
                                guard DestructiveConfirmation.confirm("Remove “\(endpoint.name)”?",
                                    message: "Its saved API key is deleted too. Profiles that use it switch to the default provider.",
                                    button: "Remove Provider") else { return }
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
            SettingsRow(verbatim: kind.addLabel) {
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

    /// Not `Binding($editing)`: that force-unwraps on every read, and the editor's
    /// fields and model picker still read it during the layout pass after Save or
    /// Cancel sets `editing` to nil, which traps. Reads fall back to the last draft,
    /// and a late write from a closing field can't reopen the editor.
    private func draftBinding(fallback: Endpoint) -> Binding<Endpoint> {
        Binding(
            get: { editing ?? fallback },
            set: { if editing != nil { editing = $0 } }
        )
    }

    private var isOutputTokenLimitValid: Bool {
        let value = outputTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || (Int(value).map { $0 > 0 } ?? false)
    }

    @ViewBuilder
    private func editor(_ draft: Binding<Endpoint>) -> some View {
        SettingsStackedRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .ai ? (isNew ? "Add AI provider" : "Edit AI provider")
                     : (isNew ? "Add transcription service" : "Edit transcription service"))
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                if let note = providerNote(for: draft.wrappedValue) {
                    Text(note)
                        .uiFont(.system(size: 11.5))
                        .foregroundStyle(palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        SettingsRow("Name") {
            NativeTextField(placeholder: kind.namePlaceholder, text: draft.name,
                            accessibilityName: kind == .ai ? String(localized: "AI provider name") : String(localized: "Transcription service name"))
                .frame(width: 260, height: 22)
        }
        SettingsRow("Base URL") {
            NativeTextField(placeholder: kind.urlPlaceholder, text: draft.baseURL,
                            accessibilityName: kind == .ai ? String(localized: "AI provider base URL") : String(localized: "Transcription service base URL"))
                .frame(width: 260, height: 22)
        }
        SettingsRow("Model", caption: availableModels.isEmpty ? nil
                    : "Loaded \(availableModels.count) models from the server.") {
            if availableModels.isEmpty {
                NativeTextField(placeholder: kind.modelPlaceholder, text: draft.modelName,
                                accessibilityName: kind == .ai ? String(localized: "AI provider model") : String(localized: "Transcription service model"))
                    .frame(width: 260, height: 22)
            } else {
                Picker("Model", selection: draft.modelName) {
                    ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                }
                .pickerStyle(.menu)
            }
        }
        SettingsRow("API key", caption: "Optional for local servers.") {
            NativeTextField(placeholder: "", text: draft.apiKey, isSecure: true,
                            accessibilityName: kind == .ai ? String(localized: "AI provider API key (optional)") : String(localized: "Transcription service API key (optional)"))
                .frame(width: 260, height: 22)
        }
        if kind.showsOutputTokenLimit {
            SettingsRow("Output token limit",
                        caption: isOutputTokenLimitValid
                            ? "Blank is automatic (\(draft.wrappedValue.recommendedMaxOutputTokens.formatted()) tokens). Covers analysis and chat, including reasoning."
                            : "Enter a positive whole number, or leave blank for automatic.") {
                NativeTextField(placeholder: String(localized: "Automatic"), text: $outputTokenLimitText,
                                accessibilityName: kind == .ai ? String(localized: "AI provider output token limit") : String(localized: "Transcription service output token limit"))
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
                    SettingsErrorDetails(summary: String(localized: "Connection failed"), error: error)
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
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.wrappedValue.name.isEmpty || draft.wrappedValue.baseURL.isEmpty
                              || draft.wrappedValue.modelName.isEmpty || !isOutputTokenLimitValid)
            }
        }
    }

    private func providerNote(for draft: Endpoint) -> String? {
        switch draft.provider {
        case .anthropic: String(localized: "Anthropic Messages API (native). Enter your model name and API key.")
        case .deepgram: String(localized: "Deepgram native API. Long files and speaker identification are handled server-side.")
        case .elevenLabs: String(localized: "ElevenLabs native API. Long files are handled server-side.")
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
                AccessibilityAnnouncer.shared.announce(models.isEmpty ? String(localized: "Connected") : String(localized: "Connected, \(models.count) models found"))
            } catch {
                availableModels = []
                testResult = .failure(error.localizedDescription)
                AccessibilityAnnouncer.shared.announce(String(localized: "Connection failed. \(error.localizedDescription)"), priority: .high)
            }
            isLoadingModels = false
        }
    }
}
