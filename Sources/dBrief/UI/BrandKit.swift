// Sources/dBrief/UI/BrandKit.swift
import SwiftUI

/// What remains of the original neon brand kit: the status hues a few live views
/// still read, the calm-appearance (Non-neon) environment flag, and two shared
/// components restyled on the viewer palette. Signature surfaces use
/// `ViewerPalette` / `MenuPanelPalette` instead.
enum Brand {
    static let coral = Color(hex: "ff405f")
    static let cyan = Color(hex: "25abff")

    // MARK: - Status hues

    static let recording = coral
    static let processing = cyan
}

// MARK: - Calm-appearance environment

/// Whether the UI should drop neon brand styling (gradients, glow, neon
/// backdrops) in favour of plain colors. Driven by `AppSettings.reduceNeon`,
/// injected at each surface root. Default `false` keeps BrandKit standalone.
private struct CalmAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var calmAppearance: Bool {
        get { self[CalmAppearanceKey.self] }
        set { self[CalmAppearanceKey.self] = newValue }
    }
}

// MARK: - Participant pill

/// A removable participant token: name + close affordance on the accent tint.
struct ParticipantPill: View {
    let name: String
    var onRemove: () -> Void
    /// When set, the name itself becomes a button that hands editing back to the caller
    /// (which swaps this pill for an inline text field). Nil keeps the pill read-only.
    var onEdit: (() -> Void)? = nil

    @Environment(\.viewerPalette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let onEdit {
                Button(action: onEdit) {
                    Text(name)
                        .uiFont(.system(size: 12))
                        .foregroundStyle(palette.heading.color)
                        .underline(hovering, color: palette.secondary.color)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Click to edit this name")
            } else {
                Text(name)
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.heading.color)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.text.color)
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(palette.selected.color, in: Capsule())
    }
}

// MARK: - Check row

/// A tappable post-processing option: an accent-filled check box (when on) + label.
struct BrandCheckRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled: Bool = true
    @Environment(\.viewerPalette) private var palette

    var body: some View {
        Button {
            if enabled { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(palette.divider.color, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isOn {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.primary.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(palette.onPrimary.color)
                            )
                    }
                }
                Text(title)
                    .uiFont(.system(size: 12))
                    .foregroundStyle(palette.text.color)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
