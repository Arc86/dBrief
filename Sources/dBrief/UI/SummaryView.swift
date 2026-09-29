import SwiftUI

/// A full-height reading document for the selected recording's summary.
/// Analysis editing and persistence live in the viewer shell's shared editor.
struct SummaryView: View {
    let insights: RecordingInsights?
    let isGenerating: Bool
    let canGenerate: Bool
    let isReadOnly: Bool
    let onGenerate: () -> Void

    @Environment(\.viewerPalette) private var palette
    @Environment(\.viewerReading) private var reading
    @Environment(\.viewerMode) private var mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSummaryCollapsed = false

    init(
        insights: RecordingInsights?,
        isGenerating: Bool,
        canGenerate: Bool,
        isReadOnly: Bool = false,
        onGenerate: @escaping () -> Void = {}
    ) {
        self.insights = insights
        self.isGenerating = isGenerating
        self.canGenerate = canGenerate
        self.isReadOnly = isReadOnly
        self.onGenerate = onGenerate
    }

    private var summaryText: String? {
        guard let summary = insights?.summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    private var hasOtherAnalysis: Bool {
        guard let insights else { return false }
        return !insights.actionItems.isEmpty || !insights.tags.isEmpty || !insights.sentiment.isEmpty
    }

    private var readingFont: Font {
        ViewerFonts.font(for: reading, effectiveMode: mode)
    }

    private var additionalLineSpacing: CGFloat {
        ViewerFonts.additionalLineSpacing(for: reading, effectiveMode: mode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isGenerating {
                    generatingState
                } else if let summaryText {
                    summaryDocument(summaryText)
                } else {
                    unavailableState
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
            .overlayScrollers()
        }
        .scrollIndicators(.automatic)
        .background(palette.canvas.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: insights?.summary) { _, _ in isSummaryCollapsed = false }
    }

    private func summaryDocument(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                if reduceMotion {
                    isSummaryCollapsed.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSummaryCollapsed.toggle()
                    }
                }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.accentText.color)

                    Text("Summary")
                        .uiFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.heading.color)

                    Spacer(minLength: 8)
                    Text("\(summary.split(whereSeparator: { $0.isWhitespace }).count.formatted()) words")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .padding(.trailing, 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                        .rotationEffect(.degrees(isSummaryCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSummaryCollapsed ? "Expand summary" : "Collapse summary")

            if !isSummaryCollapsed {
                MarkdownText(summary, readingFont: readingFont)
                    .font(readingFont)
                    .lineSpacing(additionalLineSpacing)
                    .textSelection(.enabled)
                    .foregroundStyle(palette.text.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .modifier(ViewerCard())
    }

    private var unavailableState: some View {
        VStack(spacing: 13) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(palette.secondary.color)

            Text(isReadOnly ? "Summary unavailable during reprocessing" : (hasOtherAnalysis ? "No summary text" : "No analysis yet"))
                .uiFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.heading.color)
                .multilineTextAlignment(.center)

            Text(unavailableDescription)
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

    private var unavailableDescription: String {
        if isReadOnly {
            return "The current results remain available in other tabs while reprocessing is pending."
        }
        if hasOtherAnalysis {
            return "This recording has other analysis, but no summary text was saved."
        }
        if canGenerate {
            return "Generate a summary and the other available analysis from this transcript."
        }
        return "A transcript is needed before analysis can be generated."
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
}
