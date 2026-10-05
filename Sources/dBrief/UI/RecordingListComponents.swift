import SwiftUI

/// Shared menu-bar library chrome (Recent recordings, Queue & Recovery). Flat rows
/// split by hairlines; the accent is reserved for playback.
struct RecordingListSectionHeader<Actions: View>: View {
    let title: String
    /// Secondary line under the title (queue summary). Nil keeps the header one line.
    var subtitle: String? = nil
    /// Count shown inline after the title.
    var count: Int? = nil
    @Binding var expanded: Bool
    @ViewBuilder var actions: Actions
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.heading.color)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(title)
                                .uiFont(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.heading.color)
                            if let count {
                                Text("\(count)")
                                    .uiFont(.system(size: 11))
                                    .foregroundStyle(palette.secondary.color)
                            }
                        }
                        if let subtitle {
                            Text(subtitle)
                                .uiFont(.system(size: 11))
                                .foregroundStyle(palette.secondary.color)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue([count.map { "\($0)" }, subtitle, expanded ? "expanded" : "collapsed"]
                .compactMap { $0 }.joined(separator: ", "))
            .help(expanded ? "Collapse \(title)" : "Expand \(title)")
            actions
        }
    }
}

struct RecordingListIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct RecordingListStatus: View {
    let title: String
    /// Nil renders a plain " · title" continuation of the metadata line.
    var systemImage: String? = nil
    var tint: Color? = nil
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Group {
            if let systemImage {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                Text("· \(title)")
            }
        }
        .foregroundStyle(tint ?? palette.secondary.color)
        .uiFont(.system(size: 11))
        .fixedSize()
        .accessibilityLabel("Status: \(title)")
    }
}

/// Circular play/pause control for a recording row.
struct RecordingListPlayButton: View {
    let isPlaying: Bool
    let title: String
    let action: () -> Void
    @Environment(\.viewerPalette) private var palette
    @Environment(\.menuPanelPalette) private var status

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.primary.color)
                .frame(width: 30, height: 30)
                .background(palette.surface.color, in: Circle())
                .overlay(Circle().strokeBorder(status.accentBorder.color, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(title)")
        .help("Play or pause recording")
    }
}

struct RecordingListRow<Leading: View, Metadata: View, Actions: View>: View {
    let title: String
    let expanded: Bool
    var selected = false
    let toggle: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var metadata: Metadata
    @ViewBuilder var actions: Actions
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                leading.frame(width: 30, height: 30)
                // Playback and disclosure are siblings, never nested buttons.
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .uiFont(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.heading.color)
                                .lineLimit(1)
                                .help(title)
                            metadata
                                .uiFont(.system(size: 11))
                                .foregroundStyle(palette.secondary.color)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondary.color)
                            .frame(width: 28, height: 28)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Actions expanded" : "Actions collapsed")
                .help(expanded ? "Hide actions for \(title)" : "Show actions for \(title)")
            }
            if expanded {
                actions
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, selected ? 6 : 0)
        .background(selected ? palette.selected.color : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RecordingListAction: View {
    enum Style { case compact, tile }
    let title: String
    let systemImage: String
    var destructive = false
    var style: Style = .compact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch style {
            case .compact:
                Label(title, systemImage: systemImage)
            case .tile:
                RecordingListTileLabel(title: title, systemImage: systemImage)
            }
        }
        .buttonStyle(MenuPanelButtonStyle(
            kind: destructive ? (style == .tile ? .dangerTile : .danger) : (style == .tile ? .tile : .secondary),
            height: style == .tile ? 47 : 28, fontSize: 12, fillsWidth: style == .tile))
    }
}

/// Icon over label, for the 3 × 2 recording action grid.
struct RecordingListTileLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 14)).frame(height: 18)
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.vertical, 6)
    }
}

struct RecordingListEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(palette.text.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .uiFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.heading.color)
                Text(message)
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
