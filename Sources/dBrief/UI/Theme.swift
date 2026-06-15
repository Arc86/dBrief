import SwiftUI

/// Shared visual tokens.
///
/// Per the UI brief's "shared token file" rule: one place that owns the stable
/// name→`Color` maps and reused spacing so a given identity (a profile color key,
/// and later a speaker) resolves to the same color everywhere it appears.
enum Theme {
    enum Spacing {
        /// Width of the master list pane in master-detail settings tabs.
        static let listPaneWidth: CGFloat = 240
    }

    /// A user-pickable, vibrant profile-icon color. The `key` is what gets
    /// persisted in `MeetingProfile.iconBackgroundColorKey`.
    struct ColorOption: Identifiable, Hashable {
        let key: String
        let label: String
        let color: Color
        var id: String { key }
    }

    /// Vibrant palette for profile identity icons — the deliberate pop of color
    /// called out in the Profiles ticket.
    static let profileColorOptions: [ColorOption] = [
        ColorOption(key: "blue", label: "Blue", color: .blue),
        ColorOption(key: "indigo", label: "Indigo", color: .indigo),
        ColorOption(key: "purple", label: "Purple", color: .purple),
        ColorOption(key: "pink", label: "Pink", color: .pink),
        ColorOption(key: "red", label: "Red", color: .red),
        ColorOption(key: "orange", label: "Orange", color: .orange),
        ColorOption(key: "green", label: "Green", color: .green),
        ColorOption(key: "teal", label: "Teal", color: .teal),
        ColorOption(key: "gray", label: "Gray", color: .gray)
    ]

    /// Resolve a persisted color key to its `Color` (falls back to blue).
    static func profileColor(for key: String) -> Color {
        profileColorOptions.first(where: { $0.key == key })?.color ?? .blue
    }

    /// SF Symbols offered for profile identity icons. Symbol-only (no labels) —
    /// the name is the profile's, not the glyph's. Curated for the kinds of
    /// meetings/contexts people make profiles for.
    static let profileIconOptions: [String] = [
        "slider.horizontal.3", "person.3.fill", "person.2.fill", "person.crop.circle.fill",
        "person.crop.square.fill", "briefcase.fill", "building.2.fill", "building.columns.fill",
        "phone.fill", "video.fill", "mic.fill", "headphones",
        "note.text", "doc.text.fill", "list.bullet.clipboard.fill", "calendar",
        "lightbulb.fill", "star.fill", "flag.fill", "bookmark.fill",
        "megaphone.fill", "bubble.left.and.bubble.right.fill", "envelope.fill", "globe",
        "cart.fill", "dollarsign.circle.fill", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "graduationcap.fill", "books.vertical.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "paintbrush.fill", "music.note", "gamecontroller.fill", "heart.fill",
        "bolt.fill", "flame.fill", "leaf.fill", "airplane",
        "house.fill", "cup.and.saucer.fill", "stethoscope", "scalemass.fill"
    ]
}

/// Vibrant filled rounded-square profile icon: a solid color fill with a white
/// SF Symbol. This is the deliberate splash of color from the Profiles ticket;
/// the list, the row context, and the editor preview all render through here so a
/// profile looks identical everywhere.
struct ProfileIconView: View {
    let systemName: String
    let colorKey: String
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.profileColor(for: colorKey).gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Theme.profileColor(for: colorKey).opacity(0.35), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}
