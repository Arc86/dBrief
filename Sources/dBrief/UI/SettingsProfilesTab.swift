import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsProfilesTab: View {
    @Environment(AppSettings.self) private var appSettings
    @State private var selectedProfileId: UUID?
    @State private var statusMessage: String?
    private let profileIcons: [(label: String, symbol: String)] = [
        ("General", "slider.horizontal.3"),
        ("Team", "person.3.fill"),
        ("Sales", "briefcase.fill"),
        ("Work", "building.2.fill"),
        ("Personal", "person.crop.circle.fill"),
        ("Client", "person.crop.square.fill"),
        ("Call", "phone.fill"),
        ("Notes", "note.text")
    ]
    private let iconBackgroundColors: [(label: String, key: String, color: Color)] = [
        ("Blue", "blue", .blue),
        ("Indigo", "indigo", .indigo),
        ("Purple", "purple", .purple),
        ("Pink", "pink", .pink),
        ("Red", "red", .red),
        ("Orange", "orange", .orange),
        ("Green", "green", .green),
        ("Teal", "teal", .teal),
        ("Gray", "gray", .gray)
    ]

    var body: some View {
        HStack(spacing: 20) {
            profileListPane
                .frame(width: 260)
            Divider()
            editorPane
        }
        .padding(.leading, 14)
        .padding(.top, -10)
        .onAppear {
            ensureSelection()
        }
        .onChange(of: appSettings.profiles.count) { _, _ in ensureSelection() }
        .onChange(of: selectedProfileId) { _, _ in ensureSelection() }
    }

    private var profileListPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.headline)
                .padding(.leading, 2)

            List(selection: $selectedProfileId) {
                ForEach(appSettings.profiles) { profile in
                    profileRow(profile)
                    .tag(profile.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        Color(nsColor: .windowBackgroundColor).opacity(0.55)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )

            bottomControlStrip

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func profileRow(_ profile: MeetingProfile) -> some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackgroundColor(for: profile).opacity(0.28))
                Image(systemName: profile.iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 34, height: 34)
            .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 15.5, weight: .semibold))
                HStack(spacing: 6) {
                    if profile.id == appSettings.activeProfileId {
                        Label("Active", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if profile.preset == .custom {
                        Text("Custom profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
    }

    private var bottomControlStrip: some View {
        HStack(spacing: 0) {
            toolbarIconButton(systemImage: "plus", tooltip: "Add profile") {
                let created = appSettings.createProfile(name: "New profile")
                selectedProfileId = created.id
            }

            stripDivider

            toolbarIconButton(systemImage: "minus", tooltip: "Delete selected profile") {
                guard let selected = selectedProfile else { return }
                appSettings.deleteProfile(id: selected.id)
                selectedProfileId = appSettings.activeProfileId
            }
            .disabled(selectedProfile?.isProtectedDefault ?? true)

            stripDivider

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
                .frame(width: 52, height: 32)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            stripDivider

            Text(selectedProfile?.name ?? "No Profile")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    Color(nsColor: .windowBackgroundColor).opacity(0.7)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 22)
    }

    private func toolbarIconButton(systemImage: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 32)
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

                    Picker(
                        "Icon",
                        selection: profileBinding(\.iconSystemName, fallback: selectedProfile.iconSystemName)
                    ) {
                        ForEach(profileIcons, id: \.symbol) { item in
                            Label(item.label, systemImage: item.symbol).tag(item.symbol)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(
                        "Icon background",
                        selection: profileBinding(\.iconBackgroundColorKey, fallback: selectedProfile.iconBackgroundColorKey)
                    ) {
                        ForEach(iconBackgroundColors, id: \.key) { option in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 10, height: 10)
                                Text(option.label)
                            }
                            .tag(option.key)
                        }
                    }
                    .pickerStyle(.menu)

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

    private func ensureSelection() {
        if let selectedProfileId,
           appSettings.profiles.contains(where: { $0.id == selectedProfileId }) {
            return
        }

        if appSettings.profiles.contains(where: { $0.id == appSettings.activeProfileId }) {
            self.selectedProfileId = appSettings.activeProfileId
        } else {
            self.selectedProfileId = appSettings.profiles.first?.id
        }
    }

    private func iconBackgroundColor(for profile: MeetingProfile) -> Color {
        iconBackgroundColors.first(where: { $0.key == profile.iconBackgroundColorKey })?.color ?? .gray
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
            appSettings.profiles[index].iconSystemName = selectedProfile.iconSystemName
            appSettings.profiles[index].iconBackgroundColorKey = selectedProfile.iconBackgroundColorKey
            appSettings.profiles[index].preset = .custom
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
