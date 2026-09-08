import SwiftUI

/// Shared menu-bar library chrome. Keep content flat; reserve the brand treatment
/// for playback, and use the same disclosure and type hierarchy in both lists.
struct RecordingListSectionHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @Binding var expanded: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("\(subtitle), \(expanded ? "expanded" : "collapsed")")
            .help(expanded ? "Collapse \(title)" : "Expand \(title)")
            actions
        }
        .padding(.vertical, 4)
        .controlSize(.small)
    }
}

struct RecordingListIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct RecordingListStatus: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption2)
        .fixedSize()
        .accessibilityLabel("Status: \(title)")
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
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                leading.frame(width: 30, height: 30)
                // Playback and disclosure are siblings, never nested buttons.
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.callout).foregroundStyle(.primary)
                                .lineLimit(1).help(title)
                            metadata.font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Actions expanded" : "Actions collapsed")
                .help(expanded ? "Hide actions for \(title)" : "Show actions for \(title)")
            }
            .padding(6)
            if expanded {
                actions
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
        }
        .background(selected || expanded ? Brand.violet.opacity(0.1) : hovered ? Color.primary.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

struct RecordingListAction: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(destructive ? .red : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}

struct RecordingListEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}
