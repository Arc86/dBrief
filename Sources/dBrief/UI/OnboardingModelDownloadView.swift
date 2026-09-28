import SwiftUI
import dBriefWire

struct OnboardingModelDownloadView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSettings.self) private var appSettings
    let models: [LocalModelKind]
    let onContinue: () -> Void
    @State private var cached: [LocalModelKind: Bool] = [:]
    @State private var checkingCache = true

    private var pending: [LocalModelKind] {
        OnboardingModelPlan.pendingModels(required: models, cached: cached,
                                         phases: recordingManager.modelDownloads)
    }

    private var isDownloading: Bool {
        models.contains { kind in
            if case .downloading = recordingManager.modelDownloads[kind] { return true }
            return false
        }
    }

    // Refresh cache status on completion/failure, not on every progress update.
    private var cacheCheckKey: [String] {
        models.map { kind in
            let phase = recordingManager.modelDownloads[kind] ?? .idle
            let state: String
            switch phase {
            case .idle: state = "idle"
            case .downloading: state = "active"
            case .failed: state = "failed"
            }
            return "\(modelTitle(kind)):\(state)"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            Text("Prepare your models")
                .font(.title3.weight(.semibold))

            Text("Download the models for your selected transcription and AI features. Once downloaded, these models run on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(models, id: \.self) { kind in
                    OnboardingModelDownloadCard(
                        title: modelTitle(kind),
                        purpose: kind == .gemma ? "AI chat & summaries" : "Transcription",
                        phase: recordingManager.modelDownloads[kind] ?? .idle,
                        cached: cached[kind] == true,
                        checkingCache: checkingCache,
                        canDownload: recordingManager.canDownloadModels,
                        onDownload: { recordingManager.downloadModel(kind) },
                        onCancel: { recordingManager.cancelDownload(kind) }
                    )
                }
            }

            if !pending.isEmpty {
                Text("You can set this up later in Settings. These features need their models before use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if !pending.isEmpty {
                    Button("Set up later") {
                        for kind in models { recordingManager.cancelDownload(kind) }
                        onContinue()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if pending.isEmpty {
                    Button("Continue", action: onContinue)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(checkingCache)
                } else {
                    Button(isDownloading ? "Downloading…" : "Download models") {
                        for kind in pending { recordingManager.downloadModel(kind) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(checkingCache || isDownloading || !recordingManager.canDownloadModels)
                }
            }
        }
        .task(id: cacheCheckKey) {
            checkingCache = true
            for kind in models {
                let isCached = await recordingManager.isModelCached(kind)
                guard !Task.isCancelled else { return }
                cached[kind] = isCached
            }
            checkingCache = false
        }
    }

    private func modelTitle(_ kind: LocalModelKind) -> String {
        switch kind {
        case .whisper: WhisperModelInfo.parse(appSettings.whisperModelName).displayName
        case .parakeet: LocalTranscriptionChoice.title(appSettings.parakeetModelVariant == "v2"
                                                     ? LocalTranscriptionChoice.parakeetV2
                                                     : LocalTranscriptionChoice.parakeetV3)
        case .gemma: AppSettings.AIEngine.qwenLocal.displayName
        }
    }
}

private struct OnboardingModelDownloadCard: View {
    let title: String
    let purpose: LocalizedStringKey
    let phase: ModelDownloadPhase
    let cached: Bool
    let checkingCache: Bool
    let canDownload: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(purpose).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))

            switch phase {
            case .idle:
                if checkingCache {
                    Label("Checking…", systemImage: "ellipsis.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if cached {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Waiting to download", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .downloading(let progress, let label):
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Model download progress")
                }
                HStack(spacing: 8) {
                    if progress == nil { ProgressView().controlSize(.small) }
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if let progress {
                        Text(min(max(progress, 0), 1), format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                    }
                    Spacer(minLength: 4)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless).controlSize(.small)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: onDownload)
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!canDownload)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OnboardingRecordingResponsibilityView: View {
    let onFinish: () -> Void
    @State private var acknowledged = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            Text("Before you record").font(.title3.weight(.semibold))

            Text("Let everyone know before recording a meeting or call.")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("You are responsible for how you use dBrief, including informing participants, obtaining any required consent, and following applicable laws and your organisation’s policies.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("dBrief does not notify participants or obtain consent on your behalf.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $acknowledged) {
                Text("I understand my responsibility to use dBrief lawfully and obtain any required consent.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            Button("Start using dBrief") {
                guard acknowledged else { return }
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!acknowledged)
        }
    }
}
