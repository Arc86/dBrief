// Sources/dBrief/UI/BrandKit.swift
import SwiftUI

/// dBrief brand identity — the "neon-on-black" motif from the menu-bar popover
/// redesign, adapted to a native macOS hybrid. This is the single source of truth
/// for the brand colors, gradients, glass-card surface, gradient CTA, and the
/// glowing status dots that appear across the popover, the post-recording sheet,
/// the floating mini-player, and the call-detected popup.
///
/// Hybrid principle: brand *hues* are identical in Light and Dark; *surfaces* and
/// hairlines lean on `.regularMaterial` + opacity so both schemes work from one
/// palette. Controls that the system already does well (Picker, TextField) stay
/// native; only the signature moments (Record CTA, status, glass framing, mono
/// metrics) get the brand treatment.
enum Brand {

    // MARK: - Neon palette (pulled from the design-system color tokens)

    static let coral = Color(hex: "ff405f")
    static let coral2 = Color(hex: "ff7344")
    static let violet = Color(hex: "8b4dff")
    static let violet2 = Color(hex: "b85aff")
    static let cyan = Color(hex: "25abff")
    static let cyan2 = Color(hex: "54e6ff")

    /// Low-alpha brand fills for chips / soft buttons.
    static let coralTint = coral.opacity(0.15)
    static let violetTint = violet.opacity(0.15)
    static let cyanTint = cyan.opacity(0.15)

    // MARK: - Status hues (status dots + REC indicator)

    static let ready = Color(hex: "30d158")   // green
    static let recording = coral              // coral
    static let paused = Color(hex: "ffd60a")  // yellow
    static let processing = cyan              // cyan

    // MARK: - Gradients (coral → violet → cyan)

    static let gradient = LinearGradient(
        colors: [coral, violet, cyan],
        startPoint: .leading, endPoint: .trailing
    )

    static let gradientDiagonal = LinearGradient(
        colors: [coral, violet, cyan],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Hairline border for glass cards — a faint brand-tinted edge that reads on
    /// both light and dark surfaces.
    static let cardStroke = LinearGradient(
        colors: [violet.opacity(0.35), cyan.opacity(0.25)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: - Calm-appearance variants

    /// Primary-CTA fill: the coral→violet→cyan gradient normally, a flat solid
    /// coral (i.e. plain "red") in calm mode.
    static func ctaFill(calm: Bool) -> AnyShapeStyle {
        calm ? AnyShapeStyle(coral) : AnyShapeStyle(gradientDiagonal)
    }

    /// Accent fill for waveforms / top bars: the horizontal brand gradient
    /// normally, a flat solid coral in calm mode.
    static func accentFill(calm: Bool) -> AnyShapeStyle {
        calm ? AnyShapeStyle(coral) : AnyShapeStyle(gradient)
    }

    /// Glow color for CTA shadows — transparent in calm mode so a `.shadow`
    /// modifier renders no halo without restructuring the view.
    static func ctaGlow(calm: Bool, base: Color = coral, opacity: Double = 0.5) -> Color {
        calm ? .clear : base.opacity(opacity)
    }
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

// MARK: - Glass card surface

/// Frosted card surface: system material fill + a faint brand-tinted hairline and
/// a soft violet-tinted shadow. The material adapts to Light/Dark automatically.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 14
    @Environment(\.calmAppearance) private var calm

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(calm ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(Brand.cardStroke), lineWidth: 1)
                    .opacity(calm ? 1 : 0.6)
            )
            .shadow(color: calm ? .clear : Brand.violet.opacity(0.18), radius: calm ? 0 : 18, y: calm ? 0 : 10)
    }
}

extension View {
    /// Wrap content in the brand glass card (material fill + tinted hairline + glow).
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Gradient CTA button

/// The signature brand call-to-action: full-width coral→violet→cyan fill, white
/// label, soft coral glow, subtle press feedback. Used for "Record meeting",
/// "Process", and the call-detected "Record" button.
struct GradientButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 13
    @Environment(\.calmAppearance) private var calm

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Brand.ctaFill(calm: calm), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Brand.ctaGlow(calm: calm), radius: calm ? 0 : 14, y: calm ? 0 : 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Secondary control button: glass fill + hairline, used for Pause/Resume and
/// other neutral actions alongside the gradient CTA.
struct GlassControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Neutral glass action button sized to match the 38pt icon buttons in the
/// post-recording action row (Skip / Queue), so trash, Skip, Queue, and Process
/// all share one height and corner radius.
struct SheetActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Destructive/stop control: coral tint fill + coral label + coral hairline.
struct CoralControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 14, weight: .bold))
            .foregroundStyle(Brand.coral)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Brand.coralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.coral.opacity(0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Status dot

/// A glowing identity dot. Optionally pulses (live presence / REC blink).
struct BrandStatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulse: Bool = false

    @State private var on = true
    @Environment(\.calmAppearance) private var calm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: calm ? .clear : color.opacity(0.9), radius: calm ? 0 : size * 0.9)
            .opacity(pulse && !reduceMotion ? (on ? 1 : 0.35) : 1)
            .animation(pulse && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: on)
            .onAppear { if pulse && !reduceMotion { on = false } }
            .accessibilityHidden(true)
    }
}

// MARK: - Record glyph

/// The hollow-ring-with-dot record glyph used inside the gradient CTA.
struct RecordGlyph: View {
    var size: CGFloat = 18
    var color: Color = .white

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: size * 0.13)
            .frame(width: size, height: size)
            .overlay(Circle().fill(color).frame(width: size * 0.38, height: size * 0.38))
    }
}

// MARK: - Mono font helpers

extension Font {
    /// SF Mono at an explicit size/weight — the stand-in for JetBrains Mono used on
    /// timers, REC labels, kickers, shortcut hints, and file-name captions.
    static func brandMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Eyebrow / kicker label

/// A small uppercase mono kicker (e.g. "POST-PROCESSING", "CALL DETECTED").
struct BrandKicker: View {
    let text: String
    var color: Color = .secondary
    @Environment(\.uiTypography) private var typography

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(typography.readingFont == .openDyslexic ? text : text.uppercased())
            .uiFont(.brandMono(10, weight: .medium))
            .tracking(typography.readingFont == .openDyslexic ? 0 : 1.6)
            .foregroundStyle(color)
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
                        .uiFont(.system(size: 13))
                        .foregroundStyle(palette.heading.color)
                        .underline(hovering, color: palette.secondary.color)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Click to edit this name")
            } else {
                Text(name)
                    .uiFont(.system(size: 13))
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
                    .uiFont(.system(size: 13))
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
