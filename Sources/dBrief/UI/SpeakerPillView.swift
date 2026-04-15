// Sources/dBrief/UI/SpeakerPillView.swift
import SwiftUI

/// Canonical speaker badge used in transcript cards, segment headers,
/// and the sidebar People list. Never vary the style — one component everywhere.
struct SpeakerPillView: View {
    let speakerId: String?
    let displayName: String
    /// Optional tap handler. If nil the pill is non-interactive.
    var action: (() -> Void)? = nil

    private var color: Color {
        TranscriptDesignTokens.speakerColor(for: speakerId)
    }

    var body: some View {
        pillLabel
            .ifLet(action) { view, handler in
                Button(action: handler) { view }.buttonStyle(.plain)
            }
    }

    private var pillLabel: some View {
        Text(displayName.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.5)
            .foregroundColor(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - View helper

private extension View {
    /// Apply a modifier only when an optional value is non-nil.
    @ViewBuilder
    func ifLet<T, Modified: View>(
        _ value: T?,
        transform: (Self, T) -> Modified
    ) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
