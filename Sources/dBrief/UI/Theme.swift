// Sources/dBrief/UI/Theme.swift
import SwiftUI

/// App-wide visual tokens shared across surfaces.
///
/// Per the UI brief's "shared token file" rule: one place that owns the stable
/// name→`Color` maps and reused spacing so a given identity resolves to the same
/// color everywhere it appears. The speaker palette lives here so that every place
/// a person appears — transcript rails, action-item owner avatars, and the
/// document header avatar stack — resolves the *same* colour for a given speaker
/// (`TranscriptDesignTokens.speakerColor(for:)` delegates here), and the profile
/// palette so a profile icon looks identical in the list, the row, and the editor.
enum Theme {

    // MARK: - Spacing

    enum Spacing {
        /// Width of the master list pane in master-detail settings tabs.
        static let listPaneWidth: CGFloat = 240
    }

    // MARK: - Speaker identity palette

    /// Stable, semantic speaker-identity palette. Index assigned deterministically
    /// from the speaker id, so a person keeps the same colour everywhere and across
    /// launches. Uses system-style accents that read in Light and Dark.
    static let speakerPalette: [Color] = [
        Color(hex: "0a84ff"), // blue
        Color(hex: "ff9f0a"), // orange
        Color(hex: "30d158"), // green
        Color(hex: "bf5af2"), // purple
        Color(hex: "ff453a"), // red
        Color(hex: "5ac8fa"), // teal
        Color(hex: "ffd60a"), // yellow
        Color(hex: "ff375f"), // pink
    ]

    /// Deterministic colour for a speaker id. Always returns the same colour for
    /// the same id. Empty/nil ids fall back to the first palette entry.
    static func speakerColor(for speakerId: String?) -> Color {
        guard let id = speakerId, !id.isEmpty else { return speakerPalette[0] }
        let hash = abs(id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return speakerPalette[hash % speakerPalette.count]
    }

    /// Up-to-two-letter initials for an avatar, derived from a display name.
    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
        if words.isEmpty { return "?" }
        if words.count == 1 {
            return String(words[0].prefix(2)).uppercased()
        }
        let first = words[0].first.map(String.init) ?? ""
        let last = words[words.count - 1].first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    // MARK: - Profile identity palette

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

    // MARK: - Reused spacing

    static let cardGap: CGFloat = 12
    static let contentPadding: CGFloat = 16
}

/// Canonical circular speaker avatar: a filled identity-coloured circle with the
/// person's initials. Reads `Theme.speakerColor` so it matches transcript rails
/// and owner badges. When `speakerId` matches the recording's "me" speaker the
/// caller can pass the accent colour via `overrideColor`.
struct SpeakerAvatar: View {
    let speakerId: String?
    let name: String
    var size: CGFloat = 24
    /// When set, overrides the palette colour (used for the "this is me" accent).
    var overrideColor: Color? = nil

    var body: some View {
        Circle()
            .fill(overrideColor ?? Theme.speakerColor(for: speakerId))
            .frame(width: size, height: size)
            .overlay(
                Text(Theme.initials(for: name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityLabel(Text(name))
    }
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
