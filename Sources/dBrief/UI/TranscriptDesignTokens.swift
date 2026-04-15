// Sources/dBrief/UI/TranscriptDesignTokens.swift
import SwiftUI

/// All visual constants for the transcript viewer. Use these instead of
/// hard-coded colours or sizes so future surfaces can reuse the same tokens.
enum TranscriptDesignTokens {

    // MARK: - Window background

    static func windowBackground(scheme: ColorScheme) -> LinearGradient {
        let colors: [Color] = scheme == .dark
            ? [Color(hex: "1c1c2e"), Color(hex: "26263a")]
            : [Color(hex: "e8e8ed"), Color(hex: "d8d8e0")]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Structural surfaces (toolbar, player bar)

    static func structureFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55)
    }

    static func structureBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
    }

    // MARK: - Sidebar

    static func sidebarFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.20) : Color.white.opacity(0.35)
    }

    // MARK: - Content cards

    static func cardFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
    }

    static func cardBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.80)
    }

    static func cardShadowColor(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.06)
    }

    static func cardShadowRadius(scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 6 : 4
    }

    // MARK: - Chip (Chat tab template buttons)

    static func chipFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.50)
    }

    static func chipBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    // MARK: - Typography

    static func bodyText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.88) : Color(hex: "1d1d1f")
    }

    static func timestampText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.35)
    }

    static func sectionLabel(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.40)
    }

    static func secondaryText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.50)
    }

    // MARK: - Speaker accent colours

    /// Fixed palette; index assigned round-robin by hashing the speaker ID.
    static let speakerAccents: [Color] = [
        Color(hex: "ff453a"), // red
        Color(hex: "0a84ff"), // blue
        Color(hex: "ff9f0a"), // orange
        Color(hex: "30d158"), // green
        Color(hex: "bf5af2"), // purple
        Color(hex: "5ac8fa"), // teal
    ]

    /// Deterministic colour for a speaker ID. Always returns the same colour
    /// for the same ID within a session.
    static func speakerColor(for speakerId: String?) -> Color {
        guard let id = speakerId, !id.isEmpty else { return speakerAccents[0] }
        let hash = abs(id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return speakerAccents[hash % speakerAccents.count]
    }

    // MARK: - Shape & spacing

    static let cardCornerRadius: CGFloat = 10
    static let pillCornerRadius: CGFloat = 20
    static let cardGap: CGFloat = 8
    static let scrollPadding: CGFloat = 14
    static let cardPadding = EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
}
