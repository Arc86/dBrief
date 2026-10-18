import SwiftUI

/// Owner-grouped action items, backed directly by the shell's canonical insights.
/// Completion identity remains the original raw action string.
struct RecordingActionsView: View {
    let insights: RecordingInsights?
    let owners: [String]
    let speakerLabels: [SpeakerLabel]
    let isReadOnly: Bool
    let isGenerating: Bool
    let canGenerate: Bool
    let onGenerate: () -> Void
    let onSetActionCompleted: (String, Bool) async throws -> RecordingInsights

    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode
    @State private var pendingRawKeys: Set<String> = []
    @State private var actionSaveFailed = false
    @FocusState private var focusedActionRaw: String?

    init(
        insights: RecordingInsights?,
        owners: [String],
        isReadOnly: Bool,
        speakerLabels: [SpeakerLabel] = [],
        isGenerating: Bool = false,
        canGenerate: Bool = false,
        onGenerate: @escaping () -> Void = {},
        onSetActionCompleted: @escaping (String, Bool) async throws -> RecordingInsights = { _, _ in
            throw InsightsStoreError.noSidecarURL
        }
    ) {
        self.insights = insights
        self.owners = owners
        self.isReadOnly = isReadOnly
        self.speakerLabels = speakerLabels
        self.isGenerating = isGenerating
        self.canGenerate = canGenerate
        self.onGenerate = onGenerate
        self.onSetActionCompleted = onSetActionCompleted
    }

    private var actionItems: [String] { insights?.actionItems ?? [] }

    private var groups: [ActionItemGroup] {
        ActionItemParser.group(actionItems, knownOwners: owners)
    }

    private var completedActions: Set<String> { insights?.completedActions ?? [] }

    private var hasOtherAnalysis: Bool {
        guard let insights else { return false }
        return !insights.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !insights.tags.isEmpty
            || !insights.sentiment.isEmpty
    }

    private var readingFont: Font {
        ViewerFonts.font(for: reading, effectiveMode: mode)
    }

    private var additionalLineSpacing: CGFloat {
        ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isGenerating {
                    generatingState
                } else if actionItems.isEmpty {
                    emptyState
                } else {
                    actionHeader
                    ForEach(groups) { group in
                        ownerCard(group)
                    }
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
            .overlayScrollers()
        }
        .scrollIndicators(.automatic)
        .background(palette.canvas.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Action status could not be saved", isPresented: $actionSaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The action may have changed or its recording may be unavailable. Reload the recording and try again.")
        }
    }

    private var actionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action items")
                .uiFont(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.heading.color)

            HStack(spacing: 7) {
                Text("\(insights?.unfinishedActionItems.count ?? actionItems.count) unfinished")
                Text("·")
                Text("\(insights?.completedActions.count ?? 0) completed")
            }
            .uiFont(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(palette.secondary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 3)
    }

    private func identity(for owner: String) -> String {
        let matches = speakerLabels.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(owner.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        return matches.count == 1 ? matches[0].id : owner
    }

    private func ownerCard(_ group: ActionItemGroup) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(reading.density.speakerHeaderGap)) {
            HStack(spacing: 9) {
                if group.isUnassigned {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 18))
                        .foregroundStyle(palette.secondary.color)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else {
                    HStack(spacing: 3) {
                        ForEach(group.owners, id: \.self) { owner in
                            SpeakerAvatar(speakerId: identity(for: owner), name: owner, size: 24,
                                          overrideColor: ViewerSpeakerPalette.color(for: identity(for: owner), mode: mode).color)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(group.owners.formatted(.list(type: .and))))
                }

                Text(group.owner)
                    .uiFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text("\(group.items.count)")
                    .uiFont(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.secondary.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.canvas.color, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.divider.color, lineWidth: 1))
            }

            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { entry in
                    actionRow(entry.element)
                }
            }
        }
        .padding(17)
        .modifier(ViewerCard())
    }

    private func actionRow(_ item: ParsedActionItem) -> some View {
        let isDone = completedActions.contains(item.raw)
        let isPending = pendingRawKeys.contains(item.raw)

        return HStack(alignment: .top, spacing: 11) {
            Button {
                setActionCompleted(item.raw, completed: !isDone)
            } label: {
                ZStack {
                    Circle()
                        .fill(isDone ? palette.primary.color : .clear)
                    Circle()
                        .strokeBorder(isDone ? palette.primary.color : palette.secondary.color.opacity(0.65), lineWidth: 1.5)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.onPrimary.color)
                    }
                }
                .frame(width: 17, height: 17)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedActionRaw, equals: item.raw)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focusedActionRaw == item.raw ? palette.accentText.color : .clear,
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            }
            .disabled(isReadOnly || !pendingRawKeys.isEmpty)
            .accessibilityLabel(Text(item.text))
            .accessibilityValue(isDone ? "Completed" : "Unfinished")
            .accessibilityHint(isDone ? "Mark this action unfinished" : "Mark this action complete")
            .accessibilityAddTraits(isDone ? [.isSelected] : [])

            Text(item.text)
                .font(readingFont)
                .lineSpacing(additionalLineSpacing)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? palette.secondary.color : palette.text.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, CGFloat(reading.density.rowVerticalPadding) * 0.25)
        }
        .opacity(isPending ? 0.65 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "checklist")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(palette.secondary.color)

            Text(isReadOnly ? "Actions are read-only during reprocessing" : (hasOtherAnalysis ? "No action items found" : "No analysis yet"))
                .uiFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)

            Text(emptyDescription)
                .uiFont(.system(size: 13))
                .foregroundStyle(palette.secondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if canGenerate && !isReadOnly {
                Button(action: onGenerate) {
                    Label("Generate summary, actions, and tags", systemImage: "sparkles")
                }
                .buttonStyle(ViewerBrandButtonStyle(height: 38))
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .modifier(ViewerCard())
    }

    private var emptyDescription: String {
        if isReadOnly {
            return "Existing results remain unchanged while reprocessing is pending."
        }
        if hasOtherAnalysis {
            return "This recording has other analysis, but no action items were saved."
        }
        if canGenerate {
            return "Generate available analysis from this recording's transcript."
        }
        return "A transcript is needed before action items can be generated."
    }

    private var generatingState: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.regular)
                .tint(palette.primary.color)
            Text("Generating summary and analysis…")
                .uiFont(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondary.color)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .modifier(ViewerCard())
        .accessibilityElement(children: .combine)
    }

    private func setActionCompleted(_ raw: String, completed: Bool) {
        guard !isReadOnly, pendingRawKeys.isEmpty else { return }
        pendingRawKeys.insert(raw)
        Task {
            defer { pendingRawKeys.remove(raw) }
            do {
                _ = try await onSetActionCompleted(raw, completed)
            } catch {
                actionSaveFailed = true
            }
        }
    }
}
