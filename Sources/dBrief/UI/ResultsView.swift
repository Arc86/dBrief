import SwiftUI
import AppKit

struct ResultsView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    @State private var copied = false
    @State private var showDetails = false

    enum Section: Hashable {
        case summary
        case actionItems
        case tagsAndSentiment
        case transcript   // shown only when AI failed but transcription succeeded
    }

    var body: some View {
        // The results reflect the processed recording, which may differ from the capture
        // slot (`currentRecording`) if a new recording started meanwhile.
        guard let recording = appState.processingRecording else { return AnyView(EmptyView()) }
        return AnyView(content(recording: recording))
    }

    private func content(recording: Recording) -> some View {
        let markdownURL = findMarkdownFile(for: recording)
        return VStack(alignment: .leading, spacing: 14) {
            header(recording: recording, markdownURL: markdownURL)

            if let warning = appState.preflightWarning {
                preflightBanner(warning)
            }

            if let summary = recording.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .uiFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                    Text(.init(summary))
                        .uiFont(.system(size: 14))
                        .foregroundStyle(palette.text.color)
                        .lineLimit(showDetails ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else if let transcription = recording.transcription {
                // AI failed or was off but transcription succeeded — show the transcript.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript")
                        .uiFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                    Text(.init(transcription.text))
                        .uiFont(.system(size: 14))
                        .foregroundStyle(palette.text.color)
                        .lineLimit(showDetails ? 30 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if hasDetails(recording) {
                detailsDisclosure(recording: recording)
            }

            actions(recording: recording, markdownURL: markdownURL)

            if !failedSteps.isEmpty {
                failureRow
            }

            Button("Dismiss brief") {
                appState.processingSteps.removeAll()
                appState.preflightWarning = nil
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 28, fontSize: 13))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private func header(recording: Recording, markdownURL: URL?) -> some View {
        VStack(spacing: 6) {
            Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                .uiFont(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .help(recording.generatedTitle ?? recording.meetingTitleDraft)
            Text([recording.date.formatted(date: .abbreviated, time: .omitted),
                  recording.duration > 0 ? recording.formattedDuration : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .uiFont(.system(size: 12))
                .foregroundStyle(palette.secondary.color)
            if let contents = MenuPanelProgress.briefContents(
                summary: recording.summary != nil,
                actions: !(recording.actionItems ?? []).isEmpty,
                tags: !(recording.tags ?? []).isEmpty,
                notes: markdownURL != nil
            ) {
                Label {
                    Text(contents).foregroundStyle(palette.secondary.color)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(status.success.color)
                }
                .uiFont(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Details

    private func hasDetails(_ recording: Recording) -> Bool {
        !(recording.actionItems ?? []).isEmpty || !(recording.tags ?? []).isEmpty || recording.sentiment != nil
            || (recording.summary?.count ?? 0) > 220
    }

    private func detailsDisclosure(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(showDetails ? "Fewer details" : "More details")
                        .uiFont(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.secondary.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showDetails ? "expanded" : "collapsed")

            if showDetails {
                if let items = recording.actionItems, !items.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Action items (\(items.count))")
                            .uiFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(palette.secondary.color)
                                Text(item).foregroundStyle(palette.text.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .uiFont(.system(size: 13))
                        }
                    }
                }
                if let tags = recording.tags, !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recording.sentiment.map { "Tags · \($0)" } ?? "Tags")
                            .uiFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.heading.color)
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .uiFont(.system(size: 12))
                                    .foregroundStyle(palette.accentText.color)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(palette.selected.color, in: Capsule())
                            }
                        }
                    }
                } else if let sentiment = recording.sentiment {
                    Text("Sentiment · \(sentiment)")
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.secondary.color)
                }
            }
        }
    }

    // MARK: - Actions

    private func actions(recording: Recording, markdownURL: URL?) -> some View {
        VStack(spacing: 8) {
            if let transcript = recording.richTranscript, !transcript.segments.isEmpty,
               let audioURL = recording.finalizedAudioURL {
                Button {
                    appState.pendingTranscriptSelectionURL = audioURL
                    openWindow(id: "transcript")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                        Text("View transcript")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .uiFont(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ViewerBrandButtonStyle(height: 40))
            }

            HStack(spacing: 8) {
                Button {
                    copyNotes(recording: recording)
                } label: {
                    Label(copied ? "Copied" : "Copy notes", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(recording.transcription == nil && recording.summary == nil)

                Button {
                    if let url = markdownURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open file", systemImage: "doc.text")
                }
                .disabled(markdownURL == nil)
                .help(markdownURL == nil ? "No Markdown file was written for this recording" : "Open the Markdown notes")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 33))
        }
    }

    // MARK: - Failures

    private var failedSteps: [ProcessingStep] {
        appState.processingSteps.filter { if case .failed = $0.status { true } else { false } }
    }

    private var failureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuPanelHairline()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(status.warning.color)
                Text("Didn’t finish: " + failedSteps.map(\.name).joined(separator: " · "))
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if aiStepFailed, appSettings.effectiveDefaultAIEndpoint != nil {
                    Button("Retry AI") {
                        Task {
                            guard let recording = appState.processingRecording else { return }
                            appState.preflightWarning = nil
                            await recordingManager.retryAIAnalysis(for: recording)
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 12, fillsWidth: false))
                    .help("Retry AI analysis with the remote endpoint")
                }
            }
        }
    }

    // MARK: - Banners

    private func preflightBanner(_ warning: PreflightWarning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(status.warning.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Low available memory")
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Text("\(warning.modelName) requires \(String(format: "%.1f", warning.requiredGB)) GB but only \(String(format: "%.1f", warning.availableGB)) GB is available. Processing will still be attempted, but it may run slowly or fail under memory pressure. Close other apps\(warning.hasRemoteEndpoint ? " or retry with a remote endpoint" : "") if it stalls.")
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(status.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private var aiStepFailed: Bool {
        appState.processingSteps.contains { step in
            guard case .failed = step.status else { return false }
            let name = step.name.lowercased()
            return name.contains("summar") || name.contains("action") || name.contains("tag") || name.contains("qwen") || name.contains("ai")
        }
    }

    private func copyNotes(recording: Recording) {
        var parts: [String] = []
        if let summary = recording.summary { parts.append("## Summary\n\(summary)") }
        if let items = recording.actionItems, !items.isEmpty {
            parts.append("## Action Items\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let transcript = recording.transcription?.text, parts.isEmpty {
            parts.append(transcript)
        }
        let text = parts.joined(separator: "\n\n")
        Task {
            copied = await RecordingClipboard.copy(text, for: recording)
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func findMarkdownFile(for recording: Recording) -> URL? {
        let base = (recording.finalizedAudioURL ?? recording.fileURL)
            .deletingPathExtension()
        let candidate = base.appendingPathExtension("md")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, maxHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += maxHeight + spacing; maxHeight = 0 }
            maxHeight = max(maxHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, maxHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += maxHeight + spacing; maxHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            maxHeight = max(maxHeight, size.height)
            x += size.width + spacing
        }
    }
}
