// Sources/dBrief/UI/Theme.swift
import SwiftUI

/// App-wide visual tokens shared across surfaces. The speaker palette lives here
/// so that every place a person appears — transcript rails, action-item owner
/// avatars, and the document header avatar stack — resolves the *same* colour for
/// a given speaker. `TranscriptDesignTokens.speakerColor(for:)` delegates here.
enum Theme {

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
