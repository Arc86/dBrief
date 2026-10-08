// Sources/dBrief/UI/TranscriptDesignTokens.swift
import SwiftUI

/// The transcript tokens still read outside the viewer palette. New surfaces use
/// `ViewerPalette` instead.
enum TranscriptDesignTokens {

    // MARK: - Typography

    static func bodyText(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.88) : Color(hex: "1d1d1f")
    }

    static func sectionLabel(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.40)
    }

    // MARK: - Speaker accent colours

    /// Deterministic colour for a speaker ID. Delegates to `Theme.speakerColor`.
    static func speakerColor(for speakerId: String?) -> Color {
        Theme.speakerColor(for: speakerId)
    }
}
