import SwiftUI

struct PrivacyReceiptView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: PrivacyReceiptSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Privacy receipt").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Execution evidence for this recording. No audio, transcript text, prompts, or credentials are stored in the receipt.")
                .foregroundStyle(.secondary)
            if let snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Label(snapshot.heading, systemImage: snapshot.hasGaps ? "exclamationmark.triangle" : "list.bullet.rectangle")
                        .font(.headline)
                    if snapshot.hasUnreadableReceipt {
                        Text("Some evidence could not be read. It may be damaged, unavailable, or from an unsupported version.")
                    }
                    if snapshot.hasGaps {
                        Text("Some attempts or outcomes are missing. This history cannot establish all processing that occurred.")
                    }
                    if snapshot.omittedAttempts > 0 {
                        Text("At least \(snapshot.omittedAttempts) attempts were omitted from the stored history.")
                    }
                    if snapshot.attempts.isEmpty {
                        Text("No processing attempts are available. Missing evidence does not mean processing stayed on this Mac.")
                    }
                }
                .font(.callout)
                List(snapshot.attempts) { attempt in
                    DisclosureGroup {
                        attemptDetails(attempt)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(attempt.operation.stage.receiptLabel).font(.headline)
                                Spacer()
                                Text(attempt.outcome.receiptLabel).font(.callout)
                            }
                            Text("\(attempt.operation.destination.provider.receiptLabel) · \(attempt.operation.destination.location.receiptLabel)")
                                .foregroundStyle(.secondary)
                            Text(attempt.startedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            } else {
                ProgressView("Loading evidence…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("This receipt covers recorded attempts, including retries. It makes no claims about earlier activity or provider retention. Externally managed apps and processes may sync or send data elsewhere. A start without a completion does not prove whether data was received.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 680, minHeight: 450, idealHeight: 600)
        .textSelection(.enabled)
        .task(id: recording.id) {
            while !Task.isCancelled {
                let scope = recording.privacyScope ?? RecordingPrivacyScope(recordingID: recording.id)
                var urls = [scope.pendingReceiptURL]
                if let audio = recording.finalizedAudioURL {
                    urls.insert(PrivacyReceiptStore.sidecarURL(for: audio), at: 0)
                }
                let updated = await scope.store.snapshot(at: urls)
                guard !Task.isCancelled else { return }
                if snapshot != updated { snapshot = updated }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func attemptDetails(_ attempt: PrivacyAttempt) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            detail("Provider", attempt.operation.destination.provider.receiptLabel)
            if let model = attempt.operation.destination.model { detail("Model", model) }
            if let host = attempt.operation.destination.hostname { detail("Hostname", host) }
            detail("Data", attempt.operation.data.map(\.receiptLabel).sorted().joined(separator: ", "))
            if let format = attempt.operation.responseFormat { detail("Response format", format.rawValue) }
            detail("Started", attempt.startedAt.formatted(date: .abbreviated, time: .standard))
            if let finished = attempt.finishedAt {
                detail("Finished", finished.formatted(date: .abbreviated, time: .standard))
            }
            detail("Run", attempt.runID.uuidString)
        }
        .font(.callout).padding(.vertical, 8)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension PrivacyAttempt.Outcome {
    var receiptLabel: String {
        switch self {
        case .started: "Completion unconfirmed"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .redirected: "Redirected"
        }
    }
}

private extension PrivacyDestination.Location {
    var receiptLabel: String {
        switch self {
        case .local: "On this Mac"
        case .remote: "Remote"
        case .externallyManaged: "Externally managed"
        }
    }
}

private extension PrivacyOperation.Stage {
    var receiptLabel: String {
        switch self {
        case .finalization: "Recording finalization"
        case .transcription: "Transcription"
        case .liveTranscription: "Live transcription"
        case .formatProbe: "Format probe"
        case .speakerAnalysis: "Speaker analysis"
        case .spelling: "Spelling correction"
        case .analysis: "AI analysis"
        case .summary: "Summary"
        case .actionItems: "Action items"
        case .tags: "Tags"
        case .title: "Title"
        case .chat: "Chat"
        case .markdownExport: "Markdown export"
        case .integration: "Integration"
        case .clipboardExport: "Copy to clipboard"
        case .spokenSummaryScript: "Spoken summary script"
        case .speechSynthesis: "Speech synthesis"
        case .audioExport: "Audio export"
        }
    }
}

private extension PrivacyOperation.DataCategory {
    var receiptLabel: String {
        switch self {
        case .recordingAudio: "Recording audio"
        case .syntheticAudio: "Synthetic probe audio"
        case .generatedAudio: "Generated audio"
        case .text: "Text"
        case .metadata: "Metadata"
        }
    }
}

private extension PrivacyDestination.Provider {
    var receiptLabel: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible API"
        case .anthropic: "Anthropic"
        case .deepgram: "Deepgram"
        case .elevenLabs: "ElevenLabs"
        case .custom: "Custom provider"
        case .whisper: "Whisper"
        case .speakerKit: "SpeakerKit"
        case .parakeet: "Parakeet"
        case .fluidAudio: "FluidAudio"
        case .appleSpeech: "Apple Speech"
        case .speechAnalyzer: "Apple SpeechAnalyzer"
        case .appleIntelligence: "Apple Intelligence"
        case .localModel: "Local model"
        case .localCLI: "Custom command"
        case .appleNotes: "Apple Notes"
        case .appleReminders: "Apple Reminders"
        case .webhook: "Webhook"
        case .fileSystem: "File system"
        case .clipboard: "System clipboard"
        case .ttsKit: "TTSKit"
        case .kokoro: "Kokoro"
        }
    }
}
