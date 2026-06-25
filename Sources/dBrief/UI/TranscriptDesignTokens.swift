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

    // MARK: - Neon ambient foundation (redesign)

    /// Signature neon-on-black backdrop: a near-black base with three soft
    /// brand-coloured radial glows (coral, violet, cyan). Light mode is a flat
    /// near-white surface, matching the design's light frames. Sits behind the
    /// glass panels of the transcript window.
    @ViewBuilder
    static func ambientBackground(scheme: ColorScheme, calm: Bool = false) -> some View {
        if scheme == .dark {
            if calm {
                // Calm mode: the plain native macOS window background — no neon
                // glow orbs, no purple tint, just the system dark surface.
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else {
                GeometryReader { geo in
                    let s = max(geo.size.width, geo.size.height)
                    ZStack {
                        Color(hex: "07070b")
                        ambientOrb(Color(hex: "ff405f"), opacity: 0.14, x: 0.16, y: 0.08, radius: s * 0.55)
                        ambientOrb(Color(hex: "8b4dff"), opacity: 0.18, x: 0.88, y: 0.18, radius: s * 0.60)
                        ambientOrb(Color(hex: "25abff"), opacity: 0.14, x: 0.60, y: 1.10, radius: s * 0.55)
                    }
                }
                .ignoresSafeArea()
            }
        } else {
            Color(hex: "ffffff").ignoresSafeArea()
        }
    }

    private static func ambientOrb(_ color: Color, opacity: Double, x: Double, y: Double, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), .clear],
            center: UnitPoint(x: x, y: y),
            startRadius: 0,
            endRadius: radius
        )
    }

    /// Brand gradient (coral → violet → cyan), diagonal. Used for primary CTAs,
    /// the play button, the send button, and avatar / icon marks.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: "ff405f"), Color(hex: "8b4dff"), Color(hex: "25abff")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Brand fill for CTAs / play / send / avatars — the gradient normally, a
    /// flat solid coral in calm mode.
    static func brandFill(calm: Bool) -> AnyShapeStyle {
        calm ? AnyShapeStyle(Color(hex: "ff405f")) : AnyShapeStyle(brandGradient)
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

    /// Gradient fill behind the selected meeting row. Calm mode flattens it to a
    /// single neutral violet tint (no coral→violet gradient).
    static func sidebarActiveFill(scheme: ColorScheme, calm: Bool = false) -> LinearGradient {
        let colors: [Color]
        if calm {
            let tint = Color(hex: "8b4dff").opacity(scheme == .dark ? 0.14 : 0.10)
            colors = [tint, tint]
        } else {
            colors = scheme == .dark
                ? [Color(hex: "ff405f").opacity(0.16), Color(hex: "8b4dff").opacity(0.14)]
                : [Color(hex: "8b4dff").opacity(0.10), Color(hex: "8b4dff").opacity(0.10)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func sidebarActiveBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "8b4dff").opacity(0.28) : Color(hex: "8b4dff").opacity(0.22)
    }

    static func sidebarHoverFill(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04)
    }

    /// Vertical coral→violet bar marking the active row.
    static let accentBar = LinearGradient(
        colors: [Color(hex: "ff405f"), Color(hex: "8b4dff")],
        startPoint: .top, endPoint: .bottom)

    /// Active-row marker fill — the coral→violet bar normally, a flat solid
    /// coral in calm mode.
    static func accentBarFill(calm: Bool) -> AnyShapeStyle {
        calm ? AnyShapeStyle(Color(hex: "ff405f")) : AnyShapeStyle(accentBar)
    }

    // MARK: - Content cards

    static func cardFill(scheme: ColorScheme) -> Color {
        // Light: a faint grey so cards read as raised on the white page (a near-white
        // fill is invisible). Dark is unchanged.
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
    }

    static func cardBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
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

    // MARK: - Search highlight

    /// Background behind every match of the active search query.
    static func searchHighlight(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.yellow.opacity(0.32) : Color.yellow.opacity(0.45)
    }

    /// Background behind the currently-focused match (the one prev/next lands on).
    static func searchHighlightCurrent(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.orange.opacity(0.70) : Color.orange.opacity(0.65)
    }

    // MARK: - Speaker accent colours

    /// Canonical speaker palette now lives in `Theme` so every surface (transcript
    /// rails, owner avatars, header avatar stack) resolves the same colour map.
    static var speakerAccents: [Color] { Theme.speakerPalette }

    /// Deterministic colour for a speaker ID. Delegates to `Theme.speakerColor`.
    static func speakerColor(for speakerId: String?) -> Color {
        Theme.speakerColor(for: speakerId)
    }

    // MARK: - Shape & spacing

    static let cardCornerRadius: CGFloat = 10
    static let pillCornerRadius: CGFloat = 20
    static let cardGap: CGFloat = 8
    static let scrollPadding: CGFloat = 14
    static let cardPadding = EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
}
