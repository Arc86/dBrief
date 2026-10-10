import SwiftUI
import dBriefWire

struct TranscriptionCardPresentation {
    let title: String
    let language: String
    let footprint: String
    let summary: String
    var accuracy: Int? = nil
    var speed: Int? = nil
}

extension TranscriptionCardPresentation {
    static func local(_ id: String, modernApple: Bool = false) -> Self? {
        if id == LocalTranscriptionChoice.apple {
            return .init(title: "Apple Speech", language: "System-supported languages",
                         footprint: "macOS managed",
                         summary: modernApple
                            ? "Apple SpeechAnalyzer · provisional research-based ratings."
                            : "Apple Speech · older or unsupported-locale fallback is not rated.",
                         accuracy: LocalTranscriptionChoice.profile(id, modernApple: modernApple)?.accuracy,
                         speed: LocalTranscriptionChoice.profile(id, modernApple: modernApple)?.speed)
        }
        guard let variant = LocalTranscriptionChoice.parakeetVariant(id) else { return nil }
        let model = ParakeetModelInfo.find(variant)
        let summary = switch model.id {
        case "ultra": "Parakeet Ultra / FluidAudio · v3 retrained for accuracy; fewest errors in FluidAudio's FLEURS and LibriSpeech results."
        case "redux": "Parakeet Redux / FluidAudio · ~220 MB download; first use compiles for several minutes."
        case "phonon2": "Parakeet Phonon-2 / FluidAudio · ~360 MB download; fastest English model, slightly less accurate than Ultra."
        default: "Parakeet / FluidAudio · fast transcription; ratings are family estimates."
        }
        return .init(title: model.displayName, language: model.isEnglishOnly ? "English only" : "25 European languages",
                     footprint: String(format: "~%.1f GiB RAM", Double(model.estimatedMemoryMB) / 1024),
                     summary: summary,
                     accuracy: LocalTranscriptionChoice.profile(LocalTranscriptionChoice.parakeet(model.id))?.accuracy,
                     speed: LocalTranscriptionChoice.profile(LocalTranscriptionChoice.parakeet(model.id))?.speed)
    }
}

/// The same visual model identity in Settings and the comparison list. Also the
/// shared Settings model card (Gemma uses it with a presentation).
struct TranscriptionModelCard<Actions: View>: View {
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status
    var modelID = ""
    var presentation: TranscriptionCardPresentation? = nil
    var selected = false
    var onChangeModel: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    private var model: WhisperModelInfo { .parse(modelID) }
    private var entry: WhisperCatalogEntry? { WhisperModelCatalog.entries[modelID] }
    private var title: String {
        if let presentation { return presentation.title }
        var text = model.displayName.replacingOccurrences(of: "Whisper ", with: "")
        if let size = model.quantizedSizeMB {
            text = text.replacingOccurrences(of: " (\(size) MB)", with: " (Quantized)")
        }
        return text
    }
    private var summary: String {
        if let presentation { return presentation.summary }
        guard entry != nil else { return "Guidance unavailable for this model." }
        if model.quantizedSizeMB != nil {
            return "Compressed model for a smaller footprint; ratings are family estimates."
        }
        if model.family == "large-v3-v20240930" {
            return "Faster large-v3 transcription with a small accuracy tradeoff."
        }
        if model.family == "distil-large-v3" {
            return "Fast English transcription, distilled from large v3."
        }
        switch model.family {
        case "tiny", "base": return "Lightweight transcription for quick, everyday recordings."
        case "small": return "A balance of accuracy, speed and memory use."
        case "medium": return "Higher accuracy with more memory and processing time."
        default: return "Accuracy-first transcription with greater processing demand."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.accentText.color).accessibilityLabel("Selected")
                    }
                    Text(title).uiFont(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    actions()
                        .fixedSize(horizontal: true, vertical: false)
                }
            // One fixed layout: ViewThatFits measures both candidates for every card in the picker.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) { metadata }
                ratings
            }
            .uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color)
            Text(summary).uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let onChangeModel {
                palette.divider.color.frame(height: 1)
                HStack {
                    Text("Current model")
                        .uiFont(.system(size: 11.5)).foregroundStyle(palette.secondary.color)
                    Spacer()
                    Button(action: onChangeModel) {
                        Label("Change model…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.settingsSecondary)
                    .accessibilityHint("Opens the local transcription model picker")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? palette.selected.color : palette.canvas.color,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? palette.primary.color : palette.divider.color,
                              lineWidth: selected ? 2 : 1)
        }
        .help(modelID.isEmpty ? title : modelID)
    }

    @ViewBuilder private var metadata: some View {
        if let presentation {
            Label(presentation.language, systemImage: "globe").fixedSize()
            Label(presentation.footprint, systemImage: "memorychip").fixedSize()
        } else {
        Label(entry.map { $0.englishOnly ? "English only" : "Multilingual" } ?? "Unknown language",
              systemImage: "globe").fixedSize()
        if let size = model.quantizedSizeMB {
            Label("\(size) MB", systemImage: "internaldrive").fixedSize()
                .help("Model variant size label; not runtime RAM")
        } else if let entry {
            Label(String(format: "~%.1f GiB RAM", entry.runtimeGiB), systemImage: "memorychip")
                .fixedSize()
        }
        }
    }

    private var ratings: some View {
        HStack(spacing: 16) {
            dots("Speed", value: presentation?.speed ?? entry?.speed)
            dots("Accuracy", value: presentation?.accuracy ?? entry?.accuracy)
        }.fixedSize()
    }

    private func dots(_ label: String, value: Int?) -> some View {
        HStack(spacing: 5) {
            Text(label).fontWeight(.medium)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { index in
                    Circle()
                        .fill(index <= (value ?? 0)
                              ? ((value ?? 0) >= 4 ? status.success.color : status.warning.color)
                              : palette.divider.color)
                        .frame(width: 6, height: 6)
                }
            }
            Text(value.map { "\($0)/5" } ?? "—").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value.map { "\($0) out of 5, estimated" } ?? "unavailable")")
        .help("Estimated \(label.lowercased()); higher is better")
    }
}
