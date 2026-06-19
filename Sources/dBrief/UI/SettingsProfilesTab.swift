import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsProfilesTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedProfileId: UUID?
    @State private var statusMessage: String?
    @State private var profilePendingDeletion: MeetingProfile?
    @State private var profilePendingRename: MeetingProfile?
    @State private var renameText: String = ""

    // Collapsible override groups — start collapsed; the "X of Y overridden"
    // badge surfaces state without expanding.
    @State private var showTranscriptionOverrides = false
    @State private var showAIOverrides = false
    @State private var showTaskOverrides = false
    @State private var showFolderOverrides = false

    // The symbol grid is hidden until the user taps the icon to change it.
    @State private var showSymbolPicker = false

    var body: some View {
        HStack(spacing: 16) {
            profileListPane
                .frame(width: Theme.Spacing.listPaneWidth)
            Divider()
            editorPane
        }
        .padding(.leading, 14)
        .onAppear { ensureSelection() }
        .onChange(of: appSettings.profiles.count) { _, _ in ensureSelection() }
        .onChange(of: selectedProfileId) { _, _ in
            ensureSelection()
            showSymbolPicker = false
        }
        .confirmationDialog(
            profilePendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button("Delete", role: .destructive) { performDelete(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This profile and its overrides will be removed. This can’t be undone.")
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { profilePendingRename != nil },
            set: { if !$0 { profilePendingRename = nil } }
        )) {
            TextField("Profile name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - List pane

    private var profileListPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.headline)
                .padding(.leading, 2)

            List(selection: $selectedProfileId) {
                ForEach(appSettings.profiles) { profile in
                    profileRow(profile)
                        .tag(profile.id)
                        .contextMenu { rowContextMenu(profile) }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            bottomControlBar

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func profileRow(_ profile: MeetingProfile) -> some View {
        HStack(spacing: 10) {
            ProfileIconView(systemName: profile.iconSystemName, colorKey: profile.iconBackgroundColorKey)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if profile.id == appSettings.activeProfileId {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else if profile.preset == .custom {
                    Text("Custom profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            profile.id == appSettings.activeProfileId ? "\(profile.name), active profile" : profile.name
        )
    }

    @ViewBuilder
    private func rowContextMenu(_ profile: MeetingProfile) -> some View {
        if profile.id != appSettings.activeProfileId {
            Button("Make Active", systemImage: "checkmark.seal") {
                appSettings.setActiveProfile(profile.id)
            }
        }
        Button("Rename…", systemImage: "pencil") { beginRename(profile) }
        Button("Duplicate", systemImage: "square.on.square") { duplicate(profile) }
        if !profile.isProtectedDefault {
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                profilePendingDeletion = profile
            }
        }
    }

    private var bottomControlBar: some View {
        HStack(spacing: 2) {
            Button {
                let created = appSettings.createProfile(name: "New profile")
                selectedProfileId = created.id
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Add profile")

            Button {
                guard let selectedProfile else { return }
                profilePendingDeletion = selectedProfile
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Delete selected profile")
            .disabled(selectedProfile?.isProtectedDefault ?? true)

            Spacer()

            Menu {
                Button("Duplicate", systemImage: "square.on.square") {
                    if let selectedProfile { duplicate(selectedProfile) }
                }
                .disabled(selectedProfile == nil)

                Button("Rename…", systemImage: "pencil") {
                    if let selectedProfile { beginRename(selectedProfile) }
                }
                .disabled(selectedProfile == nil)

                Button("Restore Default Profile Values", systemImage: "arrow.counterclockwise") {
                    appSettings.resetDefaultProfileToBuiltInDefaults()
                    statusMessage = "Default profile reset to built-in values."
                }
                .disabled(!(selectedProfile?.isProtectedDefault ?? false))

                Divider()

                Button("Import…", systemImage: "square.and.arrow.down") { importProfiles() }
                Button("Export Selected…", systemImage: "square.and.arrow.up") {
                    exportProfiles(selectedOnly: true)
                }
                .disabled(selectedProfile == nil)
                Button("Export All…", systemImage: "square.and.arrow.up.on.square") {
                    exportProfiles(selectedOnly: false)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Editor pane

    @ViewBuilder
    private var editorPane: some View {
        if let selectedProfile {
            Form {
                identitySection(selectedProfile)
                transcriptionOverridesSection
                aiOverridesSection
                taskOverridesSection
                folderOverridesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ContentUnavailableView("No Profile Selected", systemImage: "person.3")
        }
    }

    @ViewBuilder
    private func identitySection(_ profile: MeetingProfile) -> some View {
        Section("Profile") {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showSymbolPicker.toggle() }
                } label: {
                    ProfileIconView(
                        systemName: profile.iconSystemName,
                        colorKey: profile.iconBackgroundColorKey,
                        size: 52
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .help(showSymbolPicker ? "Hide symbols" : "Change symbol")
                .accessibilityLabel("Change symbol")

                VStack(alignment: .leading, spacing: 6) {
                    NativeTextField(
                        placeholder: "Profile name",
                        text: profileBinding(\.name, fallback: profile.name)
                    )
                    .frame(height: 22)

                    if profile.id == appSettings.activeProfileId {
                        Label("Active profile", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button("Make Active") { appSettings.setActiveProfile(profile.id) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
            }

            if showSymbolPicker {
                symbolGrid(profile)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(Theme.profileColorOptions) { option in
                        let isSelected = option.key == profile.iconBackgroundColorKey
                        Button {
                            profileBinding(\.iconBackgroundColorKey, fallback: profile.iconBackgroundColorKey)
                                .wrappedValue = option.key
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(.primary, lineWidth: isSelected ? 2 : 0)
                                )
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                        .accessibilityLabel(option.label)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }

            if profile.isProtectedDefault {
                Button("Reset to default values") {
                    appSettings.resetDefaultProfileToBuiltInDefaults()
                    statusMessage = "Default profile reset to built-in values."
                }
                .buttonStyle(.bordered)
            }

            ForEach(appSettings.warnings(for: profile), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Symbol-only icon picker: a wrapping grid of selectable SF Symbols (no
    /// labels). The selected glyph is tinted with the profile's own color.
    @ViewBuilder
    private func symbolGrid(_ profile: MeetingProfile) -> some View {
        let binding = profileBinding(\.iconSystemName, fallback: profile.iconSystemName)
        let tint = Theme.profileColor(for: profile.iconBackgroundColorKey)
        VStack(alignment: .leading, spacing: 8) {
            Text("Symbol")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 40), spacing: 8)],
                spacing: 8
            ) {
                ForEach(Theme.profileIconOptions, id: \.self) { symbol in
                    let isSelected = symbol == binding.wrappedValue
                    Button { binding.wrappedValue = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? tint : Color.primary)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? tint.opacity(0.18) : Color.secondary.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? tint : .clear, lineWidth: 2)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Override groups

    private var transcriptionOverridesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showTranscriptionOverrides) {
                overrideRow("Transcription engine", \.transcriptionEngine,
                            defaultValue: appSettings.transcriptionEngine) {
                    Picker("Engine", selection: overrideBinding(\.transcriptionEngine,
                                                                fallback: appSettings.transcriptionEngine)) {
                        ForEach(AppSettings.TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                }

                overrideRow("Language", \.transcriptionLanguage,
                            defaultValue: appSettings.transcriptionLanguage) {
                    NativeTextField(
                        placeholder: "Language code (e.g. en, nl)",
                        text: overrideBinding(\.transcriptionLanguage, fallback: appSettings.transcriptionLanguage)
                    )
                    .frame(height: 22)
                }

                overrideRow("Custom vocabulary", \.customVocabulary,
                            defaultValue: appSettings.customVocabulary.isEmpty ? nil : appSettings.customVocabulary) {
                    NativeTextView(text: Binding(
                        get: {
                            guard let index = selectedProfileIndex else {
                                return appSettings.customVocabulary.joined(separator: ", ")
                            }
                            return (appSettings.profiles[index].overrides.customVocabulary
                                ?? appSettings.customVocabulary).joined(separator: ", ")
                        },
                        set: { newValue in
                            guard let index = selectedProfileIndex else { return }
                            appSettings.profiles[index].overrides.customVocabulary =
                                TokenField.tokens(from: newValue)
                        }
                    ))
                    .frame(height: 70)
                }

                overrideRow("Transcription endpoint", \.transcriptionEndpointId,
                            defaultValue: appSettings.defaultTranscriptionEndpoint?.id) {
                    if appSettings.transcriptionEndpoints.isEmpty {
                        Text("No transcription endpoints configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Endpoint", selection: overrideBinding(\.transcriptionEndpointId,
                                                                      fallback: appSettings.transcriptionEndpoints[0].id)) {
                            ForEach(appSettings.transcriptionEndpoints) { endpoint in
                                Text(endpoint.name).tag(endpoint.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } label: {
                overrideGroupLabel("Transcription", keyPaths: [
                    isSet(\.transcriptionEngine), isSet(\.transcriptionLanguage),
                    isSet(\.customVocabulary), isSet(\.transcriptionEndpointId)
                ])
            }
        }
    }

    private var aiOverridesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAIOverrides) {
                overrideRow("AI processing", \.aiProcessingEnabled,
                            defaultValue: appSettings.aiProcessingEnabled) {
                    boolToggle("Enable AI processing", \.aiProcessingEnabled,
                               fallback: appSettings.aiProcessingEnabled)
                }

                overrideRow("AI engine", \.aiEngine, defaultValue: appSettings.aiEngine) {
                    Picker("AI engine", selection: overrideBinding(\.aiEngine, fallback: appSettings.aiEngine)) {
                        ForEach(AppSettings.AIEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                }

                overrideRow("AI endpoint", \.aiEndpointId,
                            defaultValue: appSettings.defaultAIEndpoint?.id) {
                    if appSettings.aiEndpoints.isEmpty {
                        Text("No AI endpoints configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Endpoint", selection: overrideBinding(\.aiEndpointId,
                                                                      fallback: appSettings.aiEndpoints[0].id)) {
                            ForEach(appSettings.aiEndpoints) { endpoint in
                                Text(endpoint.name).tag(endpoint.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                overrideRow("Summary prompt", \.summaryPrompt,
                            defaultValue: appSettings.summaryPrompt) {
                    NativeTextView(text: overrideBinding(\.summaryPrompt, fallback: appSettings.summaryPrompt))
                        .frame(height: 70)
                }

                overrideRow("Action items prompt", \.actionItemsPrompt,
                            defaultValue: appSettings.actionItemsPrompt) {
                    NativeTextView(text: overrideBinding(\.actionItemsPrompt, fallback: appSettings.actionItemsPrompt))
                        .frame(height: 70)
                }

                overrideRow("Tags prompt", \.tagsPrompt, defaultValue: appSettings.tagsPrompt) {
                    NativeTextView(text: overrideBinding(\.tagsPrompt, fallback: appSettings.tagsPrompt))
                        .frame(height: 70)
                }
            } label: {
                overrideGroupLabel("AI Analysis", keyPaths: [
                    isSet(\.aiProcessingEnabled), isSet(\.aiEngine), isSet(\.aiEndpointId),
                    isSet(\.summaryPrompt), isSet(\.actionItemsPrompt), isSet(\.tagsPrompt)
                ])
            }
        }
    }

    private var taskOverridesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showTaskOverrides) {
                overrideRow("Auto transcribe", \.autoTranscribe,
                            defaultValue: appSettings.autoTranscribe) {
                    boolToggle("Transcribe automatically", \.autoTranscribe, fallback: appSettings.autoTranscribe)
                }
                overrideRow("Auto summary", \.autoSummary, defaultValue: appSettings.autoSummary) {
                    boolToggle("Generate summary", \.autoSummary, fallback: appSettings.autoSummary)
                }
                overrideRow("Auto action items", \.autoActionItems,
                            defaultValue: appSettings.autoActionItems) {
                    boolToggle("Extract action items", \.autoActionItems, fallback: appSettings.autoActionItems)
                }
                overrideRow("Auto tags", \.autoTags, defaultValue: appSettings.autoTags) {
                    boolToggle("Generate tags", \.autoTags, fallback: appSettings.autoTags)
                }
            } label: {
                overrideGroupLabel("Task Defaults", keyPaths: [
                    isSet(\.autoTranscribe), isSet(\.autoSummary),
                    isSet(\.autoActionItems), isSet(\.autoTags)
                ])
            }
        }
    }

    private var folderOverridesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showFolderOverrides) {
                folderOverrideRow("Recording folder", \.recordingFolderPath,
                                  fallback: appSettings.recordingFolderURL.path)
                folderOverrideRow("Transcription folder", \.transcriptionFolderPath,
                                  fallback: appSettings.transcriptionFolderURL.path)
                folderOverrideRow("Obsidian vault", \.obsidianVaultPath,
                                  fallback: appSettings.obsidianVaultURL?.path ?? "")

                overrideRow("Obsidian default folder", \.obsidianDefaultFolderRelativePath,
                            defaultValue: appSettings.obsidianDefaultFolderRelativePath) {
                    NativeTextField(
                        placeholder: "Relative folder in vault",
                        text: overrideBinding(\.obsidianDefaultFolderRelativePath,
                                              fallback: appSettings.obsidianDefaultFolderRelativePath)
                    )
                    .frame(height: 22)
                }
            } label: {
                overrideGroupLabel("Folders", keyPaths: [
                    isSet(\.recordingFolderPath), isSet(\.transcriptionFolderPath),
                    isSet(\.obsidianVaultPath), isSet(\.obsidianDefaultFolderRelativePath)
                ])
            }
        }
    }

    // MARK: - Override row helpers

    private func overrideGroupLabel(_ title: String, keyPaths: [Bool]) -> some View {
        let active = keyPaths.filter { $0 }.count
        let total = keyPaths.count
        return HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(active) of \(total) overridden")
                .font(.caption)
                .foregroundStyle(active > 0 ? Color.accentColor : Color.secondary)
        }
    }

    /// A single override: a switch labelled with the setting name. When off the
    /// row reads "Inherits Default"; when on it reveals its inline control.
    @ViewBuilder
    private func overrideRow<T, Control: View>(
        _ title: String,
        _ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>,
        defaultValue: T?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let enabled = isSet(keyPath)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if !enabled {
                    Text("Inherits Default")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Toggle("", isOn: Binding(
                    get: { isSet(keyPath) },
                    set: { setOverride(keyPath, enabled: $0, defaultValue: defaultValue) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            if enabled {
                control()
            }
        }
    }

    private func boolToggle(
        _ label: String,
        _ keyPath: WritableKeyPath<MeetingProfileOverrides, Bool?>,
        fallback: Bool
    ) -> some View {
        Toggle(label, isOn: overrideBinding(keyPath, fallback: fallback))
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func folderOverrideRow(
        _ label: String,
        _ keyPath: WritableKeyPath<MeetingProfileOverrides, String?>,
        fallback: String
    ) -> some View {
        overrideRow(label, keyPath, defaultValue: fallback) {
            HStack {
                Text(overrideBinding(keyPath, fallback: fallback).wrappedValue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    chooseFolder { url in
                        overrideBinding(keyPath, fallback: fallback).wrappedValue = url.path
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Selection & bindings

    private var selectedProfile: MeetingProfile? {
        guard let selectedProfileId else { return nil }
        return appSettings.profiles.first(where: { $0.id == selectedProfileId })
    }

    private var selectedProfileIndex: Int? {
        guard let selectedProfileId else { return nil }
        return appSettings.profiles.firstIndex(where: { $0.id == selectedProfileId })
    }

    private func ensureSelection() {
        if let selectedProfileId,
           appSettings.profiles.contains(where: { $0.id == selectedProfileId }) {
            return
        }
        if appSettings.profiles.contains(where: { $0.id == appSettings.activeProfileId }) {
            selectedProfileId = appSettings.activeProfileId
        } else {
            selectedProfileId = appSettings.profiles.first?.id
        }
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

    private func isSet<T>(_ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>) -> Bool {
        guard let index = selectedProfileIndex else { return false }
        return appSettings.profiles[index].overrides[keyPath: keyPath] != nil
    }

    private func setOverride<T>(
        _ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>,
        enabled: Bool,
        defaultValue: T?
    ) {
        guard let index = selectedProfileIndex else { return }
        appSettings.profiles[index].overrides[keyPath: keyPath] = enabled ? defaultValue : nil
    }

    private func overrideBinding<T>(
        _ keyPath: WritableKeyPath<MeetingProfileOverrides, T?>,
        fallback: T
    ) -> Binding<T> {
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

    // MARK: - Mutations

    private func performDelete(_ profile: MeetingProfile) {
        appSettings.deleteProfile(id: profile.id)
        selectedProfileId = appSettings.activeProfileId
        profilePendingDeletion = nil
    }

    private func duplicate(_ profile: MeetingProfile) {
        let copy = appSettings.createProfile(name: profile.name)
        if let index = appSettings.profiles.firstIndex(where: { $0.id == copy.id }) {
            appSettings.profiles[index].overrides = profile.overrides
            appSettings.profiles[index].iconSystemName = profile.iconSystemName
            appSettings.profiles[index].iconBackgroundColorKey = profile.iconBackgroundColorKey
            appSettings.profiles[index].preset = .custom
        }
        selectedProfileId = copy.id
    }

    private func beginRename(_ profile: MeetingProfile) {
        renameText = profile.name
        profilePendingRename = profile
    }

    private func commitRename() {
        guard let profile = profilePendingRename,
              let index = appSettings.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appSettings.profiles[index].name = trimmed
        }
        profilePendingRename = nil
    }

    // MARK: - Folder / file panels

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
