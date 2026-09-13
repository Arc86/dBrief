import SwiftUI
import dBriefWire

struct WhisperModelPicker: View {
    let modelIDs: [String]
    let language: String
    let identifySpeakers: Bool
    let onSelect: (String) -> Void
    @State private var selectedID: String
    @State private var showAll = false
    @State private var search = ""
    @State private var showDetails = false
    @State private var cached: [String: Bool] = [:]
    @State private var engineFilter = "All"
    @State private var modernApple = false
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    init(modelIDs: [String], selectedID: String, language: String, identifySpeakers: Bool,
         onSelect: @escaping (String) -> Void) {
        self.modelIDs = modelIDs
        self.language = language
        self.identifySpeakers = identifySpeakers
        self.onSelect = onSelect
        _selectedID = State(initialValue: selectedID)
    }

    private var visibleIDs: [String] {
        let available = Set(modelIDs).union([selectedID]).subtracting(LocalTranscriptionChoice.extraIDs)
        let curated = WhisperModelCatalog.curatedIDs.filter { available.contains($0) }
        let whisper = showAll || !search.trimmingCharacters(in: .whitespaces).isEmpty
            ? available.map { WhisperModelInfo.parse($0) }.sorted().map(\.id)
            : curated + (curated.contains(selectedID) || LocalTranscriptionChoice.extraIDs.contains(selectedID) ? [] : [selectedID])
        let recommended = WhisperModelInfo.recommendedModelID
        let candidates = (whisper.contains(recommended) ? [recommended] : [])
            + LocalTranscriptionChoice.extraIDs + whisper.filter { $0 != recommended }
        return candidates.filter { id in
            let engine = LocalTranscriptionChoice.engine(id)
            if engineFilter == "Whisper" && engine != .localWhisper { return false }
            if engineFilter == "Parakeet" && engine != .parakeetLocal { return false }
            if engineFilter == "Apple" && engine != .appleSpeech { return false }
            let language = WhisperModelCatalog.entries[id].map { $0.englishOnly ? "English only" : "Multilingual" } ?? ""
            return search.trimmingCharacters(in: .whitespaces).isEmpty ||
                "\(id) \(LocalTranscriptionChoice.title(id)) \(language)"
                    .localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespaces))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a transcription model").font(.title2.bold())
            Text("Estimated ratings")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search all models", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search all local transcription models")
                Toggle("All variants", isOn: $showAll).fixedSize()
                    .help("Include all available Whisper variants")
            }
            Picker("Engine filter", selection: $engineFilter) {
                ForEach(["All", "Whisper", "Parakeet", "Apple"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            List {
                ForEach(visibleIDs, id: \.self) { id in
                    modelRow(id)
                        .listRowSeparator(.hidden)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture { selectedID = id }
                        .focusable()
                        .onKeyPress(.space) { selectedID = id; return .handled }
                        .accessibilityAction(named: "Select model") { selectedID = id }
                        .accessibilityAddTraits(selectedID == id ? .isSelected : [])
                }
            }
            .listStyle(.inset)
            .overlay {
                if visibleIDs.isEmpty {
                    Text("No matching models").foregroundStyle(.secondary)
                }
            }
            // The list receives spare height; details never compete for that space.
            .frame(minHeight: 220, maxHeight: .infinity)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(LocalTranscriptionChoice.title(selectedID))
                    .font(.headline).lineLimit(2)
                Spacer()
                Button("Memory & sources") { showDetails.toggle() }
                    .popover(isPresented: $showDetails) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(LocalTranscriptionChoice.title(selectedID)).font(.headline)
                                if LocalTranscriptionChoice.engine(selectedID) == .localWhisper {
                                    WhisperModelImpactView(modelID: selectedID, identifySpeakers: identifySpeakers)
                                } else {
                                    LocalModelEvidenceView(modelID: selectedID)
                                }
                            }.padding(20)
                        }.frame(width: 380, height: 410)
                    }
            }
            memorySummary
            if !modelIDs.contains(selectedID) && !LocalTranscriptionChoice.extraIDs.contains(selectedID) {
                Text("Saved model is absent from the catalog; availability is unverified.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if WhisperModelCatalog.entries[selectedID]?.englishOnly == true || selectedID == LocalTranscriptionChoice.parakeetV2, !language.isEmpty,
               language.lowercased().split(separator: "-").first != "en" {
                Text("English only. Choose a multilingual model for the selected language.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("\(visibleIDs.count) models · No download until used")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use model") { onSelect(selectedID); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 680, maxWidth: 820,
               minHeight: 440, idealHeight: 570, maxHeight: 760)
        .task {
            for id in Set(modelIDs).union([selectedID]).subtracting(LocalTranscriptionChoice.extraIDs).sorted() {
                guard !Task.isCancelled else { return }
                cached[id] = await manager.localAIPluginService.isWhisperModelCached(name: id)
            }
        }
        .task(id: language) {
            if #available(macOS 26, *) {
                let supported = await AppleSpeechAnalyzerService.supports(
                    locale: language.isEmpty ? .current : Locale(identifier: language))
                guard !Task.isCancelled else { return }
                modernApple = supported
            }
        }
    }

    private func modelRow(_ id: String) -> some View {
        TranscriptionModelCard(modelID: id, presentation: .local(id, modernApple: modernApple),
                               selected: selectedID == id) {
            HStack(spacing: 8) {
                if LocalTranscriptionChoice.extraIDs.contains(id) {
                    Text(id == LocalTranscriptionChoice.apple ? "macOS managed" : "Local model")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let downloaded = cached[id] {
                    Label(downloaded ? "Downloaded" : "Not downloaded",
                          systemImage: downloaded ? "checkmark.circle" : "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                Menu {
                    Button("Memory & sources") { selectedID = id; showDetails = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Model actions")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var memorySummary: some View {
        if let runtimeGiB = LocalTranscriptionChoice.runtimeGiB(selectedID) {
            let installed = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            let total = runtimeGiB + (identifySpeakers ? 0.5 : 0)
            HStack(spacing: 12) {
                ProgressView(value: min(total / max(installed, 1), 1))
                    .tint(total / max(installed, 1) <= 0.25 ? .green : total / max(installed, 1) <= 0.5 ? .yellow : .orange)
                    .frame(width: 80)
                    .accessibilityLabel("Estimated share of installed RAM")
                    .accessibilityValue(String(format: "%.0f percent", total / max(installed, 1) * 100))
                Text(String(format: "~%.1f of %.0f GiB RAM%@", total, installed,
                            identifySpeakers ? " · includes speakers" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(selectedID == LocalTranscriptionChoice.apple
                 ? "Memory and language downloads managed by macOS"
                 : "Memory guidance unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}
