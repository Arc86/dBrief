import SwiftUI

/// Compact date and duration text for library rows. Recent recordings carry a
/// weekday and time; older ones a date, with the year once it is not this year.
enum LibraryRowFormat {
    static func date(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        if date <= now, calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(style.weekday(.abbreviated).hour().minute())
        }
        style = style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// `47m`, `1h 3m`, `45s`; empty for unknown durations.
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        format(seconds, width: .narrow, locale: locale)
    }

    /// `47 minutes`, for VoiceOver.
    static func spokenDuration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        format(seconds, width: .wide, locale: locale)
    }

    private static func format(
        _ seconds: TimeInterval,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "" }
        let duration = Duration.seconds(seconds.rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return duration.formatted(.units(allowed: units, width: width).locale(locale))
    }
}

/// Selected, hover and pressed fills shared by every library sidebar row.
struct LibrarySidebarRowStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, isSelected: isSelected)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.viewerPalette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if isSelected { return palette.selected.color }
            guard isEnabled else { return .clear }
            if configuration.isPressed { return palette.selected.color.opacity(0.8) }
            return hovering ? palette.selected.color.opacity(0.55) : .clear
        }
    }
}

/// Group heading in the results list. The trailing accessory slot is sized
/// like the status filter, so counts and controls line up across groups.
struct LibrarySectionHeader<Accessory: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var accessory: Accessory
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .uiFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondary.color)
            if let count {
                Text("\(count)")
                    .uiFont(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.secondary.color.opacity(0.8))
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 32)
        .accessibilityElement(children: .contain)
    }
}

extension LibrarySectionHeader where Accessory == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A section heading that collapses its group; the chevron takes the
/// accessory slot so it aligns with the status filter above it.
struct LibraryCollapsibleSectionHeader: View {
    let title: String
    let count: Int
    @Binding var collapsed: Bool
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : ViewerMotion.panel) { collapsed.toggle() }
        } label: {
            LibrarySectionHeader(title: title, count: count) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondary.color)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 30, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) recordings")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .help(collapsed ? "Show \(title.lowercased()) recordings" : "Hide \(title.lowercased()) recordings")
    }
}

/// Quiet one-line note inside a results group.
struct LibrarySidebarNote: View {
    let text: String
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Text(text)
            .uiFont(.system(size: 12))
            .foregroundStyle(palette.secondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

/// Status shown on a row only when it needs attention; completed recordings
/// stay quiet so the exceptions stand out.
struct LibraryRowStatusLabel: View {
    let status: LibraryRecordingStatus
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(status.title)
        }
        .fixedSize()
    }

    private var symbol: String {
        switch status {
        case .failed: "exclamationmark.triangle.fill"
        case .incomplete: "exclamationmark.circle"
        case .queued: "clock"
        case .unprocessed: "circle.dashed"
        case .done: "checkmark"
        }
    }

    private var tint: Color {
        switch status {
        case .failed: .red
        case .incomplete: .orange
        default: palette.secondary.color
        }
    }
}

/// Selectable recording row with theme-adapted selection and hover states.
struct SidebarRecordingRow: View {
    let item: RecordingBrowserItem
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.viewerPalette) private var palette

    /// Legacy rows without indexed state show nothing for unprocessed audio.
    private var status: LibraryRecordingStatus? {
        item.libraryStatus ?? ((item.hasRichTranscript || item.hasTranscript) ? .done : nil)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(captionText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let status, status != .done {
                        LibraryRowStatusLabel(status: status)
                    }
                }
                .uiFont(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.secondary.color)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var captionText: String {
        let date = LibraryRowFormat.date(item.date)
        let duration = LibraryRowFormat.duration(item.duration)
        return duration.isEmpty ? date : "\(date) · \(duration)"
    }

    private var accessibilityValue: String {
        [status?.title ?? "", item.date.formatted(date: .abbreviated, time: .shortened),
         LibraryRowFormat.spokenDuration(item.duration)]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Pinned in-progress row — pulsing red/orange dot plus "Recording…/Processing…".
struct LiveSidebarRow: View {
    let recording: Recording
    let isProcessing: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var title: String { recording.generatedTitle ?? recording.meetingTitleDraft }
    private var statusText: String { isProcessing ? "Processing…" : "Recording…" }
    private var dotColor: Color { isProcessing ? .orange : .red }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .opacity(reduceMotion || pulse ? 1 : 0.4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                        .accessibilityHidden(true)
                    Text(statusText)
                }
                .uiFont(.system(size: 11))
                .foregroundStyle(palette.secondary.color)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
        .onAppear { pulse = !reduceMotion }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Failed or interrupted work in the recovery smart views.
struct LibraryWorkRow: View {
    let item: LibraryWorkItem
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .uiFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                    .lineLimit(2)
                HStack(spacing: 3) {
                    if item.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                    Text("\(item.status) · \(LibraryRowFormat.date(item.date))")
                }
                .lineLimit(1)
                .uiFont(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.secondary.color)
                if let audio = item.audioURL {
                    Text(audio.deletingLastPathComponent().path)
                        .uiFont(.system(size: 11))
                        .foregroundStyle(palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LibrarySidebarRowStyle(isSelected: isSelected))
        .help(item.audioURL?.path ?? item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue("\(item.status), \(item.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
