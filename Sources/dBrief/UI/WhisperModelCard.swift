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
                         accuracy: modernApple ? 4 : nil, speed: modernApple ? 4 : nil)
        }
        guard LocalTranscriptionChoice.engine(id) == .parakeetLocal else { return nil }
        let model = ParakeetModelInfo.find(id == LocalTranscriptionChoice.parakeetV2 ? "v2" : "v3")
        return .init(title: model.displayName, language: model.id == "v2" ? "English only" : "25 European languages",
                     footprint: String(format: "~%.1f GiB RAM", Double(model.estimatedMemoryMB) / 1024),
                     summary: "Parakeet / FluidAudio · fast transcription; ratings are family estimates.",
                     accuracy: 4, speed: 5)
    }
}

/// The same visual model identity in Settings and the comparison list.
struct TranscriptionModelCard<Actions: View>: View {
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
                            .foregroundStyle(Color.accentColor).accessibilityLabel("Selected")
                    }
                    Text(title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    actions()
                        .fixedSize(horizontal: true, vertical: false)
                }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metadata; ratings }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) { metadata }
                    ratings
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(summary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onChangeModel {
                Divider()
                HStack {
                    Text("Current model")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onChangeModel) {
                        Label("Change model…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityHint("Opens the local transcription model picker")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
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
                              ? ((value ?? 0) >= 4 ? Color.green : (value ?? 0) == 3 ? Color.yellow : Color.orange)
                              : Color.secondary.opacity(0.2))
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
