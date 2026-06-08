import SwiftUI

/// Reusable download/cancel/cached control for a single local model.
/// Reads its state from `RecordingManager.modelDownloads[kind]`.
struct ModelDownloadButton: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings
    let kind: LocalModelKind

    @State private var cached = false

    private var phase: ModelDownloadPhase {
        recordingManager.modelDownloads[kind] ?? .idle
    }

    private var phaseKey: String {
        switch phase {
        case .idle: return "idle"
        case .downloading: return "downloading"
        case .failed: return "failed"
        }
    }

    /// Identifies which concrete model this button targets, so the cache check
    /// re-runs when the user picks a different model (not just on phase changes).
    private var modelIdentity: String {
        switch kind {
        case .whisper: return appSettings.whisperModelName
        case .parakeet: return appSettings.parakeetModelVariant
        case .gemma: return "gemma"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .idle:
                idleRow
            case .downloading(let progress, let label):
                downloadingRow(progress: progress, label: label)
            case .failed(let message):
                failedRow(message)
            }
        }
        .task(id: "\(phaseKey):\(modelIdentity)") {
            cached = await recordingManager.isModelCached(kind)
        }
    }

    @ViewBuilder
    private var idleRow: some View {
        HStack(spacing: 8) {
            if cached {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Re-download") {
                    recordingManager.downloadModel(kind, forceRedownload: true)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!recordingManager.canDownloadModels)
            } else {
                Button("Download model") {
                    recordingManager.downloadModel(kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!recordingManager.canDownloadModels)
            }
        }
        .help(recordingManager.canDownloadModels ? "" : "Unavailable while recording or processing")
    }

    private func downloadingRow(progress: Double?, label: String) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                recordingManager.cancelDownload(kind)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func failedRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                recordingManager.downloadModel(kind)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

/// Collapsed-by-default per-engine guidance for the transcription settings.
struct TranscriptionEngineGuideView: View {
    var body: some View {
        DisclosureGroup("Need some help?") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(TranscriptionEngineGuide.entries) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}
