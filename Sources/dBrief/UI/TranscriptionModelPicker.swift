import SwiftUI
import dBriefWire

/// Sheet for choosing the local transcription model: Quick pick tiles or the full list.
/// Both views share one selection; the last view used is remembered.
struct TranscriptionModelPicker: View {
    enum Mode: String { case quickPick, allModels }

    let modelIDs: [String]
    let language: String
    let identifySpeakers: Bool
    let onSelect: (String) -> Void
    private let currentID: String
    @State private var selectedID: String
    @State private var cached: [String: Bool] = [:]
    @State private var modernApple = false
    @AppStorage("modelPickerView") private var mode: Mode = .quickPick
    @Environment(RecordingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.viewerPalette) private var palette

    init(modelIDs: [String], selectedID: String, language: String, identifySpeakers: Bool,
         onSelect: @escaping (String) -> Void) {
        self.modelIDs = modelIDs
        self.language = language
        self.identifySpeakers = identifySpeakers
        self.onSelect = onSelect
        currentID = selectedID
        _selectedID = State(initialValue: selectedID)
    }

    private var installedRAMGiB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    private var suggestions: [ModelSuggestion] {
        ModelSuggestions.picks(
            language: language, installedRAMGiB: installedRAMGiB,
            macOSMajor: ParakeetModelInfo.currentMacOSMajor, identifySpeakers: identifySpeakers,
            available: WhisperModelCatalog.curatedIDs.filter(modelIDs.contains) + LocalTranscriptionChoice.extraIDs,
            downloaded: Set(cached.filter(\.value).keys))
    }

    var body: some View {
        let picks = suggestions
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose a transcription model").uiFont(.title2.bold())
                Spacer()
                Picker("View", selection: $mode) {
                    Text("Quick pick").tag(Mode.quickPick)
                    Text("All models").tag(Mode.allModels)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch mode {
            case .quickPick:
                ModelPickerQuickPick(suggestions: picks, currentID: currentID, cached: cached,
                                     language: language, installedRAMGiB: installedRAMGiB,
                                     modernApple: modernApple, selectedID: $selectedID,
                                     showAllModels: { mode = .allModels })
            case .allModels:
                Text("\(ModelPickerAllModels.visibleCount(modelIDs: modelIDs, selectedID: selectedID)) models · nothing downloads until first use")
                    .uiFont(.caption).foregroundStyle(palette.secondary.color)
                ModelPickerAllModels(modelIDs: modelIDs, suggestions: picks, cached: cached,
                                     modernApple: modernApple, language: language,
                                     identifySpeakers: identifySpeakers, selectedID: $selectedID)
                    .frame(minHeight: 380, idealHeight: 460, maxHeight: .infinity)
            }
            palette.divider.color.frame(height: 1)
            HStack {
                if mode == .quickPick {
                    Text("Ratings are estimates, not measured on this Mac")
                        .uiFont(.caption).foregroundStyle(palette.secondary.color)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.settingsSecondary)
                Button("Use \(LocalTranscriptionChoice.shortTitle(selectedID))") { onSelect(selectedID); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.settingsPrimary)
            }
        }
        .padding(20)
        // Each view sizes the sheet: Quick pick stays compact, All models gets list height.
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 840, maxHeight: 760)
        .background(palette.canvas.color)
        .task {
            for id in Set(modelIDs).union([selectedID]).sorted() where LocalTranscriptionChoice.engine(id) == .localWhisper {
                guard !Task.isCancelled else { return }
                cached[id] = await manager.localAIPluginService.isWhisperModelCached(name: id)
            }
            for id in LocalTranscriptionChoice.extraIDs {
                if Task.isCancelled { return }
                guard let variant = LocalTranscriptionChoice.parakeetVariant(id) else { continue }
                cached[id] = await manager.parakeetService.isModelDownloaded(variant: variant)
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
}
