import SwiftUI
import dBriefWire

/// "All models": grouped list (Built in / Parakeet / Whisper) beside an inspector.
struct ModelPickerAllModels: View {
    let modelIDs: [String]
    let currentID: String
    let suggestions: [ModelSuggestion]
    let cached: [String: Bool]
    let modernApple: Bool
    let language: String
    let identifySpeakers: Bool
    @Binding var selectedID: String
    @State private var search = ""
    @State private var showEveryVariant = false
    @FocusState private var focusedID: String?
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    struct ModelGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let ids: [String]
    }

    /// Whisper rows: curated (+ the saved and selected models) by default; the whole catalog when
    /// searching or when "Show every Whisper variant" is on. The recommended model always leads.
    nonisolated static func whisperIDs(modelIDs: [String], selectedID: String, currentID: String,
                                       showEveryVariant: Bool, query: String) -> [String] {
        // The saved model stays listed even after another row is selected.
        let pinned = [currentID, selectedID].filter { !$0.isEmpty && LocalTranscriptionChoice.engine($0) == .localWhisper }
        let available = Set(modelIDs).union(pinned)
        var ids: [String]
        if showEveryVariant || !query.isEmpty {
            ids = available.map { WhisperModelInfo.parse($0) }.sorted().map(\.id)
        } else {
            ids = WhisperModelCatalog.curatedIDs.filter(available.contains)
            for id in pinned where !ids.contains(id) { ids.append(id) }
        }
        let recommended = WhisperModelInfo.recommendedModelID
        return ids.contains(recommended) ? [recommended] + ids.filter { $0 != recommended } : ids
    }

    /// The list's groups after search and the variant toggle; empty groups are dropped.
    nonisolated static func groups(modelIDs: [String], selectedID: String, currentID: String,
                                   showEveryVariant: Bool, query: String, modernApple: Bool) -> [ModelGroup] {
        let parakeet = LocalTranscriptionChoice.extraIDs.filter { LocalTranscriptionChoice.engine($0) == .parakeetLocal }
        let whisper = whisperIDs(modelIDs: modelIDs, selectedID: selectedID, currentID: currentID,
                                 showEveryVariant: showEveryVariant, query: query)
        func matches(_ id: String) -> Bool {
            guard !query.isEmpty else { return true }
            let language = LocalTranscriptionChoice.profile(id, modernApple: modernApple)?.languageLabel ?? ""
            return "\(id) \(LocalTranscriptionChoice.title(id)) \(LocalTranscriptionChoice.shortTitle(id)) \(language)"
                .localizedCaseInsensitiveContains(query)
        }
        return [ModelGroup(id: "builtin", title: "Built in", ids: [LocalTranscriptionChoice.apple]),
                ModelGroup(id: "parakeet", title: "Parakeet", ids: parakeet),
                ModelGroup(id: "whisper", title: "Whisper", ids: whisper)]
            .map { ModelGroup(id: $0.id, title: $0.title, ids: $0.ids.filter(matches)) }
            .filter { !$0.ids.isEmpty }
    }

    /// Every row the list shows, in order (drives the count and arrow-key navigation).
    nonisolated static func listIDs(modelIDs: [String], selectedID: String, currentID: String,
                                    showEveryVariant: Bool, query: String, modernApple: Bool) -> [String] {
        groups(modelIDs: modelIDs, selectedID: selectedID, currentID: currentID,
               showEveryVariant: showEveryVariant, query: query, modernApple: modernApple).flatMap(\.ids)
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var flatIDs: [String] { groups.flatMap(\.ids) }

    private var groups: [ModelGroup] {
        Self.groups(modelIDs: modelIDs, selectedID: selectedID, currentID: currentID,
                    showEveryVariant: showEveryVariant, query: query, modernApple: modernApple)
    }

    var body: some View {
        let shown = groups
        let flatIDs = shown.flatMap(\.ids)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(flatIDs.count) models · nothing downloads until first use")
                .uiFont(.caption).foregroundStyle(palette.secondary.color)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search models", text: $search)
                        .settingsTextField()
                        .accessibilityLabel("Search local transcription models")
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(shown) { group in
                                    Text(group.title.uppercased())
                                        .uiFont(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(palette.secondary.color)
                                        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(group.ids, id: \.self) { row($0, group: group) }
                                }
                            }
                        }
                        .overlayScrollers()
                        .onChange(of: focusedID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                    }
                    .overlay {
                        if flatIDs.isEmpty {
                            Text("No matching models").foregroundStyle(palette.secondary.color)
                        }
                    }
                    Toggle("Show every Whisper variant", isOn: $showEveryVariant)
                        .toggleStyle(.checkbox)
                        .uiFont(.caption)
                        .help("Include all available Whisper variants, not only the curated set")
                }
                .frame(width: 250)
                .padding(.trailing, 12)
                palette.divider.color.frame(width: 1)
                ModelInspector(modelID: selectedID,
                               suggestion: suggestions.first { $0.modelID == selectedID },
                               downloaded: cached[selectedID],
                               modernApple: modernApple, language: language, identifySpeakers: identifySpeakers,
                               inCatalog: modelIDs.contains(selectedID) || LocalTranscriptionChoice.extraIDs.contains(selectedID))
                    .padding(.leading, 14)
            }
        }
    }

    private func rowTitle(_ id: String, group: ModelGroup) -> String {
        let title = LocalTranscriptionChoice.shortTitle(id)
        let prefix = group.title + " "
        return group.id != "builtin" && title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    private func ramText(_ id: String) -> String {
        if id == LocalTranscriptionChoice.apple { return "macOS" }
        return LocalTranscriptionChoice.profile(id)?.runtimeGiB.map { String(format: "%.1f GB", $0) } ?? "—"
    }

    private func row(_ id: String, group: ModelGroup) -> some View {
        let selected = id == selectedID
        let mark = suggestions.first { $0.modelID == id }?.intent
        let ready = cached[id] == true || id == LocalTranscriptionChoice.apple
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .uiFont(.system(size: 10, weight: .bold))
                .foregroundStyle(status.success.color)
                .opacity(ready ? 1 : 0)
                .frame(width: 12)
            Text(rowTitle(id, group: group)).lineLimit(1).foregroundStyle(palette.text.color)
            if let mark {
                Image(systemName: mark.symbol)
                    .uiFont(.system(size: 9))
                    .foregroundStyle(palette.accentText.color)
                    .help(mark.title)
            }
            Spacer(minLength: 8)
            Text(ramText(id)).monospacedDigit().foregroundStyle(palette.secondary.color)
        }
        .uiFont(.system(size: 12.5))
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(selected ? palette.selected.color : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = id; focusedID = id }
        .focusable()
        .focusEffectDisabled()
        .focused($focusedID, equals: id)
        .onKeyPress(.downArrow) { move(from: id, by: 1); return .handled }
        .onKeyPress(.upArrow) { move(from: id, by: -1); return .handled }
        .onKeyPress(.space) { selectedID = id; return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalTranscriptionChoice.shortTitle(id))
        .accessibilityValue([ready ? "Downloaded" : nil, mark?.title, ramText(id)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedID = id }
        .id(id)
    }

    private func move(from id: String, by step: Int) {
        guard let next = SettingsListNavigation.step(step, in: flatIDs, from: id) else { return }
        selectedID = next
        focusedID = next
    }
}

/// Details for the selected model: ratings, memory on this Mac, facts, warnings, sources.
struct ModelInspector: View {
    let modelID: String
    let suggestion: ModelSuggestion?
    let downloaded: Bool?
    let modernApple: Bool
    let language: String
    let identifySpeakers: Bool
    let inCatalog: Bool
    @State private var showSources = false
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    private var profile: LocalModelProfile? { LocalTranscriptionChoice.profile(modelID, modernApple: modernApple) }
    private var engine: AppSettings.TranscriptionEngine { LocalTranscriptionChoice.engine(modelID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalTranscriptionChoice.title(modelID))
                        .uiFont(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let suggestion { SettingsStatusPill(verbatim: suggestion.intent.title, kind: .accent) }
                        if modelID == LocalTranscriptionChoice.apple {
                            SettingsStatusPill("macOS managed", kind: .neutral)
                        } else if let downloaded {
                            SettingsStatusPill(downloaded ? "Downloaded" : "Not downloaded",
                                               kind: downloaded ? .success : .neutral)
                        }
                    }
                }
                VStack(spacing: 6) {
                    ModelRatingMeter(kind: .speed, value: profile?.speed)
                    ModelRatingMeter(kind: .accuracy, value: profile?.accuracy)
                }
                memory
                facts
                warnings
                DisclosureGroup("Sources", isExpanded: $showSources) {
                    Group {
                        if engine == .localWhisper {
                            WhisperModelImpactView(modelID: modelID, identifySpeakers: identifySpeakers)
                        } else {
                            LocalModelEvidenceView(modelID: modelID)
                        }
                    }
                    .padding(.top, 6)
                }
                .uiFont(.caption)
                Text("Speed and accuracy are estimates, not measured on this Mac.")
                    .uiFont(.caption).foregroundStyle(palette.secondary.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlayScrollers()
    }

    @ViewBuilder private var memory: some View {
        if let ram = profile?.runtimeGiB {
            let installed = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            let speakers = identifySpeakers ? ModelSuggestions.speakersGiB : 0
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory while transcribing").uiFont(.caption).foregroundStyle(palette.secondary.color)
                MemoryShareBar(model: ram, speakers: speakers, installed: installed)
                Text(identifySpeakers
                     ? String(format: "%.1f GB + %.1f GB speakers of %.0f GB", ram, speakers, installed)
                     : String(format: "%.1f GB of %.0f GB", ram, installed))
                    .uiFont(.caption).foregroundStyle(palette.text.color)
            }
        } else {
            Text(modelID == LocalTranscriptionChoice.apple
                 ? "Memory and language downloads are managed by macOS."
                 : "Memory guidance unavailable.")
                .uiFont(.caption).foregroundStyle(palette.secondary.color)
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Languages").foregroundStyle(palette.secondary.color)
                Text(profile?.languageLabel ?? "Unknown")
            }
            GridRow {
                Text("Download").foregroundStyle(palette.secondary.color)
                Text(downloadText)
            }
            GridRow {
                Text("Engine").foregroundStyle(palette.secondary.color)
                Text(engineText)
            }
        }
        .uiFont(.caption)
        .foregroundStyle(palette.text.color)
    }

    private var downloadText: String {
        if let mb = profile?.downloadMB { return "\(mb) MB" }
        switch engine {
        case .appleSpeech: return "Managed by macOS"
        default: return "Downloads on first use"
        }
    }

    private var engineText: String {
        switch engine {
        case .appleSpeech: modernApple ? "Apple SpeechAnalyzer" : "Apple Speech"
        case .parakeetLocal: "FluidAudio · on this Mac"
        default: "WhisperKit · on this Mac"
        }
    }

    @ViewBuilder private var warnings: some View {
        let code = LocalModelProfile.baseCode(language)
        if let profile, !code.isEmpty, !profile.covers(language: language) {
            let name = ModelSuggestions.languageName(language) ?? code
            Label(profile.languages == .englishOnly
                  ? "English only. Choose a multilingual model for \(name)."
                  : "Covers \(profile.languageLabel). Choose Whisper for \(name).",
                  systemImage: "exclamationmark.triangle")
                .uiFont(.caption).foregroundStyle(status.warning.color)
        }
        if !inCatalog {
            Label("Saved model is absent from the catalog; availability is unverified.",
                  systemImage: "exclamationmark.triangle")
                .uiFont(.caption).foregroundStyle(status.warning.color)
        }
    }
}

/// Installed-RAM bar: solid model segment, lighter speaker-identification segment.
private struct MemoryShareBar: View {
    let model: Double
    let speakers: Double
    let installed: Double
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        let total = max(installed, 1)
        let modelShare = min(model / total, 1)
        let speakerShare = min(speakers / total, 1 - modelShare)
        let tint = ModelSuggestions.fitsMemory(ramGiB: model, speakersGiB: speakers, installedGiB: installed)
            ? status.success.color : status.warning.color
        GeometryReader { geo in
            HStack(spacing: 0) {
                tint.frame(width: geo.size.width * modelShare)
                tint.opacity(0.45).frame(width: geo.size.width * speakerShare)
                Spacer(minLength: 0)
            }
            .background(palette.divider.color)
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Estimated share of installed memory")
        .accessibilityValue(String(format: "%.0f percent", (model + speakers) / total * 100))
    }
}
