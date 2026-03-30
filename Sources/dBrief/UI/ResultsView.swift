import SwiftUI
import AppKit

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var appSettings
    @Environment(RecordingManager.self) private var recordingManager

    @State private var collapsedSections = Set<Section>()
    @State private var copied = false

    enum Section: Hashable {
        case summary
        case actionItems
        case tagsAndSentiment
        case transcript   // shown only when AI failed but transcription succeeded
    }

    var body: some View {
        guard let recording = appState.currentRecording else { return AnyView(EmptyView()) }
        return AnyView(content(recording: recording))
    }

    private func content(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(recording.generatedTitle ?? recording.meetingTitleDraft)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if recording.duration > 0 {
                    Text(recording.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)

            // Status strip
            statusStrip
                .padding(.bottom, 10)

            // Pre-flight warning banner
            if let warning = appState.preflightWarning {
                preflightBanner(warning)
                    .padding(.bottom, 8)
            }

            // Scrollable sections
            ScrollView {
                VStack(spacing: 6) {
                    if recording.summary != nil || recording.actionItems != nil {
                        if let summary = recording.summary {
                            collapsibleSection(.summary, title: "Summary") {
                                Text(summary)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let items = recording.actionItems, !items.isEmpty {
                            collapsibleSection(.actionItems, title: "Action Items (\(items.count))") {
                                VStack(alignment: .leading, spacing: 4) {
                                    let isCollapsed = collapsedSections.contains(.actionItems)
                                    let visible = isCollapsed ? [] : Array(items.prefix(3))
                                    ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("◦").foregroundStyle(.secondary).font(.caption)
                                            Text(item).font(.callout)
                                        }
                                    }
                                    if !isCollapsed && items.count > 3 {
                                        Button("+\(items.count - 3) more") {
                                            collapsedSections.remove(.actionItems)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .padding(.leading, 14)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if recording.tags != nil || recording.sentiment != nil {
                            collapsibleSection(.tagsAndSentiment, title: tagsAndSentimentTitle(recording)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let tags = recording.tags, !tags.isEmpty {
                                        FlowLayout(spacing: 4) {
                                            ForEach(tags, id: \.self) { tag in
                                                Text(tag)
                                                    .font(.caption)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(.fill)
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let transcription = recording.transcription {
                        // AI failed but transcription succeeded — show transcript
                        collapsibleSection(.transcript, title: "Transcript") {
                            Text(transcription.text)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Retry banner — shown when AI step failed and remote endpoint exists
                    if aiStepFailed, appSettings.effectiveDefaultAIEndpoint != nil {
                        retryBanner
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.vertical, 6)

            // Pinned action bar
            actionBar(recording: recording)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(appState.processingSteps.filter { isSignificantStep($0) }.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                }
                stepChip(step)
            }
            Spacer()
        }
        .lineLimit(1)
    }

    private func isSignificantStep(_ step: ProcessingStep) -> Bool {
        let name = step.name.lowercased()
        return name.contains("transcrib") || name.contains("summar") || name.contains("action") ||
               name.contains("tag") || name.contains("title") || name.contains("markdown")
    }

    private func stepChip(_ step: ProcessingStep) -> some View {
        Group {
            switch step.status {
            case .completed:
                Text("✓ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.green)
            case .failed:
                Text("✕ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.red)
            case .inProgress:
                Text("⋯ \(abbreviatedStepName(step.name))")
                    .foregroundStyle(.secondary)
            case .pending:
                Text(abbreviatedStepName(step.name))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
    }

    private func abbreviatedStepName(_ name: String) -> String {
        if name.lowercased().contains("transcrib") { return "Transcribed" }
        if name.lowercased().contains("summar") { return "Summary" }
        if name.lowercased().contains("action") { return "Actions" }
        if name.lowercased().contains("tag") { return "Tags" }
        if name.lowercased().contains("title") { return "Title" }
        if name.lowercased().contains("markdown") { return "Notes" }
        return name
    }

    // MARK: - Collapsible section

    private func collapsibleSection<Content: View>(
        _ section: Section,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(section)
        return VStack(spacing: 0) {
            Button {
                if isCollapsed { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(.fill.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Banners

    private func preflightBanner(_ warning: PreflightWarning) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Low available memory")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("\(warning.modelName) requires \(String(format: "%.1f", warning.requiredGB)) GB. Only \(String(format: "%.1f", warning.availableGB)) GB available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var retryBanner: some View {
        HStack(spacing: 8) {
            Text("Retry AI with remote endpoint?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task {
                    guard let recording = appState.currentRecording else { return }
                    appState.preflightWarning = nil
                    await recordingManager.retryAIAnalysis(for: recording)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Action bar

    private func actionBar(recording: Recording) -> some View {
        HStack(spacing: 6) {
            Button(copied ? "Copied!" : "Copy Notes") {
                copyNotes(recording: recording)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(recording.transcription == nil && recording.summary == nil)

            Spacer()

            let markdownURL = findMarkdownFile(for: recording)
            Button("Open File") {
                if let url = markdownURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(markdownURL == nil)

            Button("Dismiss") {
                appState.processingSteps.removeAll()
                appState.preflightWarning = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private var aiStepFailed: Bool {
        appState.processingSteps.contains { step in
            guard case .failed = step.status else { return false }
            let name = step.name.lowercased()
            return name.contains("summar") || name.contains("action") || name.contains("tag") || name.contains("qwen") || name.contains("ai")
        }
    }

    private func tagsAndSentimentTitle(_ recording: Recording) -> String {
        var parts: [String] = ["Tags"]
        if let sentiment = recording.sentiment { parts.append(sentiment) }
        return parts.joined(separator: " · ")
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
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
