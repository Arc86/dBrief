import SwiftUI

struct PromptGenerationStatus: View {
    let progress: PromptGenerationProgress
    let generationTitle: String
    let cancel: () -> Void

    private var title: String {
        switch progress {
        case .preparingModel: return "Preparing Gemma…"
        case .downloadingModel: return "Downloading Gemma…"
        case .loadingModel: return "Loading Gemma…"
        case .generating: return generationTitle
        }
    }
    private var detail: String? {
        switch progress {
        case .preparingModel: return "Getting the local model ready. First use may require a download."
        case .downloadingModel: return "The model needs to download to this Mac before it can run. Generation starts automatically."
        case .loadingModel: return "Loading the model into memory on this Mac."
        case .generating: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if case .downloadingModel(.some) = progress {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Button("Cancel", action: cancel).controlSize(.small)
            }
            if case .downloadingModel(let fraction?) = progress {
                HStack(spacing: 10) {
                    ProgressView(value: fraction).accessibilityLabel("Model download")
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
