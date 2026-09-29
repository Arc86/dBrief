import SwiftUI

/// Shared calendar/analysis picker. Custom editing takes precedence over the
/// saved preset so choosing Custom doesn't immediately snap back to that preset.
struct ClaudeModelPicker: View {
    @Binding var modelID: String?
    @State private var usesCustomModel = false
    @State private var customModelID = ""

    private var selection: Binding<String> {
        Binding(
            get: {
                if usesCustomModel { return "__custom" }
                guard let modelID else { return "__default" }
                return ClaudeModelCatalog.contains(modelID) ? modelID : "__custom"
            },
            set: { value in
                usesCustomModel = value == "__custom"
                if usesCustomModel {
                    customModelID = modelID ?? ""
                } else {
                    modelID = value == "__default" ? nil : value
                }
            }
        )
    }

    var body: some View {
        Picker("Model", selection: selection) {
            Text("Claude default").tag("__default")
            Section("Model families") {
                ForEach(ClaudeModelCatalog.aliases) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            Section("Versions") {
                ForEach(ClaudeModelCatalog.versions) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            Text("Custom model ID").tag("__custom")
        }
        .pickerStyle(.menu)

        if selection.wrappedValue == "__custom" {
            TextField("Custom model ID", text: $customModelID, prompt: Text("e.g. claude-opus-5-5"))
                .onChange(of: customModelID) { _, value in
                    if let sanitized = CalendarCLIConfig.sanitizedModelID(value) {
                        modelID = sanitized
                    }
                }
            if !customModelID.isEmpty, CalendarCLIConfig.sanitizedModelID(customModelID) == nil {
                Text("Use a model ID without spaces or shell characters. The previous selection is kept until the ID is valid.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Text("Model families follow Claude's current aliases. Versions stay pinned. Availability depends on your Claude account and provider.")
            .uiFont(.caption)
            .foregroundStyle(.secondary)
            .onAppear { customModelID = modelID ?? "" }
    }
}
