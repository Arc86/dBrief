import SwiftUI

/// Per-recording processing evidence. Uses the viewer palette, the assistant-panel
/// header and viewer command buttons so it reads as part of the transcript viewer
/// (mirrors `SpokenSummaryPlayerView`).
struct PrivacyReceiptView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: PrivacyReceiptSnapshot?
    @State private var expanded: Set<PrivacyAttempt.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Execution evidence for this recording. No audio, transcript text, prompts, or credentials are stored in the receipt.")
                .uiFont(.system(size: 13))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot {
                summary(snapshot)
                attemptList(snapshot)
            } else {
                ProgressView("Loading evidence…")
                    .controlSize(.small)
                    .foregroundStyle(palette.secondary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 680, minHeight: 450, idealHeight: 600)
        .foregroundStyle(palette.text.color)
        .background(palette.surface.color)
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

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LinearGradient(colors: palette.brandStops.map(\.color),
                                                startPoint: .leading, endPoint: .trailing))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Privacy receipt")
                    .uiFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .accessibilityAddTraits(.isHeader)
                Text(recordingTitle)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close privacy receipt")
            .help("Close")
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { palette.divider.color.frame(height: 1) }
    }

    private var recordingTitle: String {
        let title = (recording.generatedTitle ?? recording.meetingTitleDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "This recording" : title
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Text("This receipt covers recorded attempts, including retries. It makes no claims about earlier activity or provider retention. Externally managed apps and processes may sync or send data elsewhere. A start without a completion does not prove whether data was received.")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { dismiss() }
                .buttonStyle(ViewerCommandButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Summary

    private func summary(_ snapshot: PrivacyReceiptSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(snapshot.heading)
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
            } icon: {
                Image(systemName: snapshot.hasGaps ? "exclamationmark.triangle.fill" : "list.bullet.rectangle")
                    .foregroundStyle(snapshot.hasGaps ? Color.orange : palette.secondary.color)
            }
            .accessibilityAddTraits(.isHeader)
            Group {
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
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Attempts

    @ViewBuilder
    private func attemptList(_ snapshot: PrivacyReceiptSnapshot) -> some View {
        if snapshot.attempts.isEmpty {
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.attempts.enumerated()), id: \.element.id) { index, attempt in
                        if index > 0 { palette.divider.color.frame(height: 1) }
                        attemptRow(attempt)
                    }
                }
            }
            .overlayScrollers()
            .frame(maxHeight: .infinity)
            .background(palette.canvas.color, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.divider.color, lineWidth: 1).allowsHitTesting(false))
        }
    }

    private func attemptRow(_ attempt: PrivacyAttempt) -> some View {
        let isExpanded = expanded.contains(attempt.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    if isExpanded { expanded.remove(attempt.id) } else { expanded.insert(attempt.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attempt.operation.stage.receiptLabel)
                            .uiFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        HStack(spacing: 5) {
                            Image(systemName: attempt.operation.destination.location.receiptSymbol)
                                .font(.system(size: 10))
                                .accessibilityHidden(true)
                            Text("\(attempt.operation.destination.provider.receiptLabel) · \(attempt.operation.destination.location.receiptLabel)")
                        }
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.text.color)
                        Text(attempt.startedAt.formatted(date: .abbreviated, time: .standard))
                            .uiFont(.system(size: 11).monospacedDigit())
                            .foregroundStyle(palette.secondary.color)
                    }
                    Spacer(minLength: 12)
                    outcomeBadge(attempt.outcome)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the details of this attempt." : "Shows the details of this attempt.")

            if isExpanded {
                attemptDetails(attempt)
                    .padding(.leading, 36)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private func outcomeBadge(_ outcome: PrivacyAttempt.Outcome) -> some View {
        Label {
            Text(outcome.receiptLabel)
        } icon: {
            Image(systemName: outcome.receiptSymbol)
                .foregroundStyle(outcomeTint(outcome))
        }
        .labelStyle(.titleAndIcon)
        .uiFont(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.secondary.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.surface.color, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.divider.color, lineWidth: 1))
    }

    private func outcomeTint(_ outcome: PrivacyAttempt.Outcome) -> Color {
        switch outcome {
        case .succeeded: palette.accentText.color
        case .failed: .red
        case .started: .orange
        case .cancelled, .redirected: palette.secondary.color
        }
    }

    private func attemptDetails(_ attempt: PrivacyAttempt) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
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
        .uiFont(.system(size: 12))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(palette.secondary.color)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
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

    var receiptSymbol: String {
        switch self {
        case .started: "questionmark.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        case .redirected: "arrow.triangle.turn.up.right.circle.fill"
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

    var receiptSymbol: String {
        switch self {
        case .local: "laptopcomputer"
        case .remote: "network"
        case .externallyManaged: "arrow.up.forward.app"
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
        case .promptImprovement: "Prompt improvement"
        case .markdownExport: "Markdown export"
        case .integration: "Integration"
        case .clipboardExport: "Copy to clipboard"
        case .spokenSummaryScript: "Spoken summary script"
        case .speechSynthesis: "Speech synthesis"
        case .audioExport: "Audio export"
        case .calendarFetch: "Calendar fetch"
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
        case .claudeCLI: "Claude CLI connector"
        }
    }
}
