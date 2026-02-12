import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsProfilesTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedProfileId: UUID?
    @State private var statusMessage: String?

    var body: some View {
        HStack(spacing: 16) {
            profileListPane
                .frame(width: 260)
            Divider()
            editorPane
        }
        .padding(.top, -10)
        .onAppear {
            if selectedProfileId == nil {
                selectedProfileId = appSettings.activeProfileId
            }
        }
    }

    private var profileListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            profilesToolbar

            List(selection: $selectedProfileId) {
                ForEach(appSettings.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if profile.id == appSettings.activeProfileId {
                            Text("Active")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                    .tag(profile.id)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profilesToolbar: some View {
        HStack(spacing: 0) {
            toolbarIconButton(systemImage: "plus", tooltip: "Add profile") {
                let created = appSettings.createProfile(name: "New profile")
                selectedProfileId = created.id
            }

            toolbarDivider

            toolbarIconButton(systemImage: "minus", tooltip: "Delete selected profile") {
                guard let selected = selectedProfile else { return }
                appSettings.deleteProfile(id: selected.id)
                selectedProfileId = appSettings.activeProfileId
            }
            .disabled(selectedProfile?.isProtectedDefault ?? true)

            toolbarDivider

            Menu {
                Button("Duplicate Profile", systemImage: "square.on.square") {
                    duplicateSelectedProfile()
                }
                .disabled(selectedProfile == nil)

                Button("Restore Default Profile Values", systemImage: "arrow.counterclockwise") {
                    appSettings.resetDefaultProfileToBuiltInDefaults()
                    statusMessage = "Default profile reset to built-in values."
                }
                .disabled(!(selectedProfile?.isProtectedDefault ?? false))

                Divider()

                Button("Import...", systemImage: "square.and.arrow.down") {
                    importProfiles()
                }
                Button("Export Selected...", systemImage: "square.and.arrow.up") {
                    exportProfiles(selectedOnly: true)
                }
                .disabled(selectedProfile == nil)
                Button("Export All...", systemImage: "square.and.arrow.up.on.square") {
                    exportProfiles(selectedOnly: false)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .frame(width: 64, height: 34)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            toolbarDivider

            Text(selectedProfile?.name ?? "No Profile")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 24)
    }

    private func toolbarIconButton(systemImage: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @ViewBuilder
    private var editorPane: some View {
        if let selectedProfile {
            Form {
                Section("Profile") {
                    NativeTextField(
                        placeholder: "Profile name",
                        text: profileBinding(\.name, fallback: selectedProfile.name)
                    )
                    .frame(height: 22)

                    Toggle(
                        "Active profile",
                        isOn: Binding(
                            get: { selectedProfile.id == appSettings.activeProfileId },
                            set: { isActive in
                                if isActive {
                                    appSettings.setActiveProfile(selectedProfile.id)
                                }
                            }
                        )
                    )

                    if selectedProfile.isProtectedDefault {
                        Button("Reset to default values") {
                            appSettings.resetDefaultProfileToBuiltInDefaults()
                            statusMessage = "Default profile reset to built-in values."
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(appSettings.warnings(for: selectedProfile), id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color.clear)

                Section("Transcription Overrides") {
                    overrideToggle(
                        "Transcription engine",
                        isOn: hasOverride(\.transcriptionEngine),
                        set: { setOverride(\.transcriptionEngine, enabled: $0, defaultValue: appSettings.transcriptionEngine) }
                    )
                    if hasOverride(\.transcriptionEngine).wrappedValue {
                        Picker(
                            "Engine",
                            selection: overrideBinding(\.transcriptionEngine, fallback: appSettings.transcriptionEngine)
                        ) {
                            ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    overrideToggle(
                        "Language",
                        isOn: hasOverride(\.transcriptionLanguage),
                        set: { setOverride(\.transcriptionLanguage, enabled: $0, defaultValue: appSettings.transcriptionLanguage) }
                    )
                    if hasOverride(\.transcriptionLanguage).wrappedValue {
                        NativeTextField(
                            placeholder: "Language code (e.g. en, nl)",
                            text: overrideBinding(\.transcriptionLanguage, fallback: appSettings.transcriptionLanguage)
                        )
                        .frame(height: 22)
                    }

                    overrideToggle(
                        "Whisper prompt",
                        isOn: hasOverride(\.whisperPrompt),
                        set: { setOverride(\.whisperPrompt, enabled: $0, defaultValue: appSettings.whisperPrompt) }
                    )
                    if hasOverride(\.whisperPrompt).wrappedValue {
                        NativeTextView(text: overrideBinding(\.whisperPrompt, fallback: appSettings.whisperPrompt))
                            .frame(height: 70)
                    }

                    overrideToggle(
                        "Transcription endpoint",
                        isOn: hasOverride(\.transcriptionEndpointId),
                        set: {
                            setOverride(
                                \.transcriptionEndpointId,
                                enabled: $0,
                                defaultValue: appSettings.defaultTranscriptionEndpoint?.id
                            )
                        }
                    )
                    if hasOverride(\.transcriptionEndpointId).wrappedValue {
                        if appSettings.transcriptionEndpoints.isEmpty {
                            Text("No transcription endpoints configured.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                "Endpoint",
                                selection: overrideBinding(
                                    \.transcriptionEndpointId,
                                    fallback: appSettings.transcriptionEndpoints[0].id
                                )
                            ) {
                                ForEach(appSettings.transcriptionEndpoints) { endpoint in
                                    Text(endpoint.name).tag(endpoint.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
                .listRowBackground(Color.clear)

                Section("AI Overrides") {
                    overrideToggle(
                        "AI engine",
                        isOn: hasOverride(\.aiEngine),
                        set: { setOverride(\.aiEngine, enabled: $0, defaultValue: appSettings.aiEngine) }
                    )
                    if hasOverride(\.aiEngine).wrappedValue {
                        Picker(
                            "AI engine",
                            selection: overrideBinding(\.aiEngine, fallback: appSettings.aiEngine)
                        ) {
                            ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    overrideToggle(
                        "AI endpoint",
                        isOn: hasOverride(\.aiEndpointId),
                        set: {
                            setOverride(
                                \.aiEndpointId,
                                enabled: $0,
                                defaultValue: appSettings.defaultAIEndpoint?.id
                            )
                        }
                    )
                    if hasOverride(\.aiEndpointId).wrappedValue {
                        if appSettings.aiEndpoints.isEmpty {
                            Text("No AI endpoints configured.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                "Endpoint",
                                selection: overrideBinding(\.aiEndpointId, fallback: appSettings.aiEndpoints[0].id)
                            ) {
                                ForEach(appSettings.aiEndpoints) { endpoint in
                                    Text(endpoint.name).tag(endpoint.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    overrideToggle(
                        "Summary prompt",
                        isOn: hasOverride(\.summaryPrompt),
                        set: { setOverride(\.summaryPrompt, enabled: $0, defaultValue: appSettings.summaryPrompt) }
                    )
                    if hasOverride(\.summaryPrompt).wrappedValue {
                        NativeTextView(text: overrideBinding(\.summaryPrompt, fallback: appSettings.summaryPrompt))
                            .frame(height: 70)
                    }

                    overrideToggle(
                        "Action items prompt",
                        isOn: hasOverride(\.actionItemsPrompt),
                        set: {
                            setOverride(
                                \.actionItemsPrompt,
                                enabled: $0,
                                defaultValue: appSettings.actionItemsPrompt
                            )
                        }
                    )
                    if hasOverride(\.actionItemsPrompt).wrappedValue {
                        NativeTextView(text: overrideBinding(\.actionItemsPrompt, fallback: appSettings.actionItemsPrompt))
                            .frame(height: 70)
                    }

                    overrideToggle(
                        "Tags prompt",
                        isOn: hasOverride(\.tagsPrompt),
                        set: { setOverride(\.tagsPrompt, enabled: $0, defaultValue: appSettings.tagsPrompt) }
                    )
                    if hasOverride(\.tagsPrompt).wrappedValue {
                        NativeTextView(text: overrideBinding(\.tagsPrompt, fallback: appSettings.tagsPrompt))
                            .frame(height: 70)
                    }
                }
                .listRowBackground(Color.clear)

                Section("Task Defaults Overrides") {
                    overrideToggle(
                        "Auto transcribe",
                        isOn: hasOverride(\.autoTranscribe),
                        set: { setOverride(\.autoTranscribe, enabled: $0, defaultValue: appSettings.autoTranscribe) }
                    )
                    if hasOverride(\.autoTranscribe).wrappedValue {
                        Toggle("", isOn: overrideBinding(\.autoTranscribe, fallback: appSettings.autoTranscribe))
                    }

                    overrideToggle(
                        "Auto summary",
                        isOn: hasOverride(\.autoSummary),
                        set: { setOverride(\.autoSummary, enabled: $0, defaultValue: appSettings.autoSummary) }
                    )
                    if hasOverride(\.autoSummary).wrappedValue {
                        Toggle("", isOn: overrideBinding(\.autoSummary, fallback: appSettings.autoSummary))
                    }

                    overrideToggle(
                        "Auto action items",
                        isOn: hasOverride(\.autoActionItems),
                        set: { setOverride(\.autoActionItems, enabled: $0, defaultValue: appSettings.autoActionItems) }
                    )
                    if hasOverride(\.autoActionItems).wrappedValue {
                        Toggle("", isOn: overrideBinding(\.autoActionItems, fallback: appSettings.autoActionItems))
                    }

                    overrideToggle(
                        "Auto tags",
                        isOn: hasOverride(\.autoTags),
                        set: { setOverride(\.autoTags, enabled: $0, defaultValue: appSettings.autoTags) }
                    )
                    if hasOverride(\.autoTags).wrappedValue {
                        Toggle("", isOn: overrideBinding(\.autoTags, fallback: appSettings.autoTags))
                    }
                }
                .listRowBackground(Color.clear)

                Section("Folder Overrides") {
                    folderOverrideRow(
                        label: "Recording folder",
                        keyPath: \.recordingFolderPath,
                        fallback: appSettings.recordingFolderURL.path
                    )
                    folderOverrideRow(
                        label: "Transcription folder",
                        keyPath: \.transcriptionFolderPath,
                        fallback: appSettings.transcriptionFolderURL.path
                    )
                    folderOverrideRow(
                        label: "Obsidian vault",
                        keyPath: \.obsidianVaultPath,
                        fallback: appSettings.obsidianVaultURL?.path ?? ""
                    )

                    overrideToggle(
                        "Obsidian default folder",
                        isOn: hasOverride(\.obsidianDefaultFolderRelativePath),
                        set: {
                            setOverride(
                                \.obsidianDefaultFolderRelativePath,
                                enabled: $0,
                                defaultValue: appSettings.obsidianDefaultFolderRelativePath
                            )
                        }
                    )
                    if hasOverride(\.obsidianDefaultFolderRelativePath).wrappedValue {
                        NativeTextField(
                            placeholder: "Relative folder in vault",
                            text: overrideBinding(
                                \.obsidianDefaultFolderRelativePath,
                                fallback: appSettings.obsidianDefaultFolderRelativePath
                            )
                        )
                        .frame(height: 22)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.smallSwitch)
        } else {
            ContentUnavailableView("No Profile Selected", systemImage: "person.3")
        }
    }

    private func overrideToggle(_ title: String, isOn: Binding<Bool>, set: @escaping (Bool) -> Void) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { isOn.wrappedValue },
                set: { set($0) }
            )
        )
    }

    private var selectedProfile: MeetingProfile? {
        guard let selectedProfileId else { return nil }
        return appSettings.profiles.first(where: { $0.id == selectedProfileId })
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<MeetingProfile, T>, fallback: T) -> Binding<T> {
        Binding(
            get: {
                guard let index = selectedProfileIndex else { return fallback }
                return appSettings.profiles[index][keyPath: keyPath]
            },
            set: { value in
                guard let index = selectedProfileIndex else { return }
                appSettings.profiles[index][keyPath: keyPath] = value
            }
        )
    }

    private func hasOverride<T>(_ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>) -> Binding<Bool> {
        Binding(
            get: {
                guard let index = selectedProfileIndex else { return false }
                return appSettings.profiles[index].overrides[keyPath: keyPath] != nil
            },
            set: { enabled in
                guard let index = selectedProfileIndex else { return }
                if !enabled {
                    appSettings.profiles[index].overrides[keyPath: keyPath] = nil
                }
            }
        )
    }

    private func setOverride<T>(_ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>, enabled: Bool, defaultValue: T?) {
        guard let index = selectedProfileIndex else { return }
        if enabled {
            appSettings.profiles[index].overrides[keyPath: keyPath] = defaultValue
        } else {
            appSettings.profiles[index].overrides[keyPath: keyPath] = nil
        }
    }

    private func overrideBinding<T>(_ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>, fallback: T) -> Binding<T> {
        Binding(
            get: {
                guard let index = selectedProfileIndex else { return fallback }
                return appSettings.profiles[index].overrides[keyPath: keyPath] ?? fallback
            },
            set: { value in
                guard let index = selectedProfileIndex else { return }
                appSettings.profiles[index].overrides[keyPath: keyPath] = value
            }
        )
    }

    private var selectedProfileIndex: Int? {
        guard let selectedProfileId else { return nil }
        return appSettings.profiles.firstIndex(where: { $0.id == selectedProfileId })
    }

    private func duplicateSelectedProfile() {
        guard let selectedProfile else { return }
        let duplicate = appSettings.createProfile(name: selectedProfile.name)
        if let index = appSettings.profiles.firstIndex(where: { $0.id == duplicate.id }) {
            appSettings.profiles[index].overrides = selectedProfile.overrides
        }
        selectedProfileId = duplicate.id
    }

    private func folderOverrideRow(
        label: String,
        keyPath: WritableKeyPath<MeetingProfileOverrides, String?>,
        fallback: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            overrideToggle(
                label,
                isOn: hasOverride(keyPath),
                set: { setOverride(keyPath, enabled: $0, defaultValue: fallback) }
            )

            if hasOverride(keyPath).wrappedValue {
                HStack {
                    Text(overrideBinding(keyPath, fallback: fallback).wrappedValue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") {
                        chooseFolder { url in
                            overrideBinding(keyPath, fallback: fallback).wrappedValue = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func chooseFolder(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try appSettings.importProfiles(from: data)
            selectedProfileId = appSettings.activeProfileId
            var message = "Imported \(result.importedCount) profile(s)."
            if result.renamedCount > 0 {
                message += " Renamed \(result.renamedCount)."
            }
            if !result.warnings.isEmpty {
                message += " \(result.warnings.joined(separator: " "))"
            }
            statusMessage = message
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func exportProfiles(selectedOnly: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = selectedOnly ? "profile.json" : "profiles.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let ids = selectedOnly ? selectedProfile.map { [$0.id] } : nil
            let data = try appSettings.exportProfiles(ids: ids)
            try data.write(to: url)
            statusMessage = "Profiles exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
