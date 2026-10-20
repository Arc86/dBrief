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
        return AnyView(content(recording: recording)
            .onChange(of: copied) { _, copied in
                if copied { appState.announcer.announce("Notes copied") }
            })
    }

    private func content(recording: Recording) -> some View {
        let markdownURL = findMarkdownFile(for: recording)
        return VStack(alignment: .leading, spacing: 14) {
            header(recording: recording, markdownURL: markdownURL)

            if let warning = appState.preflightWarning {
                preflightBanner(warning)
            }

            if recording.summary != nil || recording.transcription != nil {
                briefBody(recording: recording)
            }

            actions(recording: recording, markdownURL: markdownURL)

            ForEach(warningSteps) { step in
                warningRow(step)
            }
            if !failedSteps.isEmpty {
                failureRow
            }

            Button("Done") { finishBrief() }
                .buttonStyle(MenuPanelButtonStyle(kind: .hero, height: 32, fontSize: 13))
                .help("Clear this brief from the menu; the recording stays in your library")
        }
    }

    // MARK: - Header

    private func header(recording: Recording, markdownURL: URL?) -> some View {
        VStack(spacing: 6) {
            Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                .uiFont(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .help(recording.generatedTitle ?? recording.meetingTitleDraft)
            Text([recording.date.formatted(date: .abbreviated, time: .omitted),
                  recording.duration > 0 ? recording.formattedDuration : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .uiFont(.system(size: 11))
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
                .uiFont(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Details

    /// Summary (or the transcript when there is no summary) with a Show all / Show less
    /// toggle in its header, so the control stays put whatever the length. Expanded
    /// content scrolls inside a capped box instead of stretching the panel.
    private func briefBody(recording: Recording) -> some View {
        let isTranscript = recording.summary == nil
        let expandable = MenuPanelProgress.offersMoreDetails(
            summary: recording.summary,
            transcriptFallback: isTranscript,
            actionCount: recording.actionItems?.count ?? 0,
            tagCount: recording.tags?.count ?? 0,
            hasSentiment: recording.sentiment != nil
        )
        let text = recording.summary ?? recording.transcription?.text ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isTranscript ? "Transcript" : "Summary")
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Spacer()
                if expandable {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "Show less" : "Show all")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .quiet, height: 22, fontSize: 11))
                    .accessibilityValue(showDetails ? "expanded" : "collapsed")
                }
            }
            if showDetails {
                MenuPanelBoundedScroll(maxHeight: 280) {
                    VStack(alignment: .leading, spacing: 12) {
                        briefText(text)
                        details(recording: recording)
                    }
                    .padding(.trailing, 6)
                }
            } else {
                briefText(text).lineLimit(4)
            }
        }
    }

    private func briefText(_ text: String) -> some View {
        Text(.init(text))
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.text.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func details(recording: Recording) -> some View {
        if let items = recording.actionItems, !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Action items (\(items.count))")
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(palette.secondary.color)
                        Text(item).foregroundStyle(palette.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .uiFont(.system(size: 12))
                }
            }
        }
        if let tags = recording.tags, !tags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(recording.sentiment.map { String(localized: "Tags · \($0)") } ?? String(localized: "Tags"))
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .uiFont(.system(size: 11))
                            .foregroundStyle(palette.accentText.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(palette.selected.color, in: Capsule())
                    }
                }
            }
        } else if let sentiment = recording.sentiment {
            Text("Sentiment · \(sentiment)")
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
        }
    }

    private func finishBrief() {
        appState.processingSteps.removeAll()
        appState.preflightWarning = nil
    }

    // MARK: - Actions

    private func actions(recording: Recording, markdownURL: URL?) -> some View {
        VStack(spacing: 8) {
            if let transcript = recording.richTranscript, !transcript.segments.isEmpty,
               let audioURL = recording.finalizedAudioURL {
                Button {
                    // Opening the transcript finishes the brief and gets the panel out of the way.
                    appState.pendingTranscriptSelectionURL = audioURL
                    finishBrief()
                    MenuBarPanel.open("transcript", with: openWindow)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                        Text("View transcript")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .uiFont(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ViewerBrandButtonStyle(height: 34))
            }

            HStack(spacing: 8) {
                Button {
                    copyNotes(recording: recording)
                } label: {
                    Label(copied ? "Copied" : "Copy Notes", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(recording.transcription == nil && recording.summary == nil)

                Button {
                    if let url = markdownURL { MenuBarPanel.open(url) }
                } label: {
                    Label("Open file", systemImage: "doc.text")
                }
                .disabled(markdownURL == nil)
                .help(markdownURL == nil ? "No Markdown file was written for this recording" : "Open the Markdown notes")
            }
            .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 30))
        }
    }

    // MARK: - Failures

    private var failedSteps: [ProcessingStep] {
        appState.processingSteps.filter { if case .failed = $0.status { true } else { false } }
    }

    private var warningSteps: [ProcessingStep] {
        appState.processingSteps.filter { if case .warning = $0.status { true } else { false } }
    }

    private func warningRow(_ step: ProcessingStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuPanelHairline()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(status.warning.color)
                    .accessibilityHidden(true)
                Text(step.warningMessage ?? step.name)
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Warning: \(step.warningMessage ?? step.name)")
        }
    }

    /// Each failed step with its reason, then the fix that matches what failed.
    private var failureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuPanelHairline()
            ForEach(failedSteps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(status.danger.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(step.name) didn’t finish")
                            .uiFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.text.color)
                        if case .failed(let reason) = step.status, !reason.isEmpty {
                            Text(UserFacingError.text(reason))
                                .uiFont(.system(size: 11))
                                .foregroundStyle(palette.secondary.color)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .accessibilityElement(children: .combine)
            }
            if let recording = appState.processingRecording, let audio = recording.finalizedAudioURL {
                let fixes = BriefRecovery.actions(for: appState.processingSteps)
                if !fixes.isEmpty {
                    HStack(spacing: 8) {
                        if fixes.contains(.reanalyze) {
                            Button("Re-run AI Analysis…") {
                                appState.preflightWarning = nil
                                RecordingActionWindowController.shared.showReprocessing(recording: recording, operation: .analysis)
                            }
                            .recordingBlock(recordingManager.eligibility(for: audio, .reprocess),
                                            help: "Run AI analysis again, with any engine or endpoint")
                        }
                        if fixes.contains(.integrations) {
                            Button("Integrations…") {
                                Task { await recordingManager.reviewIntegrationDeliveries(for: audio) }
                            }
                            .disabled(appState.processingJob != nil || recordingManager.reviewingIntegrationDeliveries)
                            .help("Review delivery status and retry an individual integration")
                        }
                    }
                    .buttonStyle(MenuPanelButtonStyle(kind: .secondary, height: 26, fontSize: 11, fillsWidth: false))
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
                    .uiFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Group {
                    if warning.hasRemoteEndpoint {
                        Text("\(warning.modelName) requires \(warning.requiredGB, specifier: "%.1f") GB but only \(warning.availableGB, specifier: "%.1f") GB is available. Processing will still be attempted, but it may run slowly or fail under memory pressure. Close other apps or retry with a remote endpoint if it stalls.")
                    } else {
                        Text("\(warning.modelName) requires \(warning.requiredGB, specifier: "%.1f") GB but only \(warning.availableGB, specifier: "%.1f") GB is available. Processing will still be attempted, but it may run slowly or fail under memory pressure. Close other apps if it stalls.")
                    }
                }
                    .uiFont(.system(size: 11))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(status.warning.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private func copyNotes(recording: Recording) {
        let text = RecordingNotesText.compose(summary: recording.summary, actionItems: recording.actionItems,
                                              transcript: recording.transcription?.text) ?? ""
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
