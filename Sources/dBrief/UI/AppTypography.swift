import AppKit
import SwiftUI

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypographyPreferences()
}

extension EnvironmentValues {
    var uiTypography: AppTypographyPreferences {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

/// Keeps the existing hierarchy while applying the user's UI font and size.
struct AppFontStyle: Sendable {
    private var textStyle: Font.TextStyle?
    private var explicitSize: CGFloat?
    private var fontWeight: Font.Weight = .regular
    private var design: Font.Design = .default
    private var isItalic = false
    private var usesMonospacedDigits = false

    static let largeTitle = system(.largeTitle)
    static let title = system(.title)
    static let title2 = system(.title2)
    static let title3 = system(.title3)
    static let headline = system(.headline)
    static let subheadline = system(.subheadline)
    static let body = system(.body)
    static let callout = system(.callout)
    static let footnote = system(.footnote)
    static let caption = system(.caption)
    static let caption2 = system(.caption2)

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        Self(explicitSize: size, fontWeight: weight, design: design)
    }

    static func system(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil) -> Self {
        Self(textStyle: style, fontWeight: weight ?? (style == .headline ? .semibold : .regular), design: design)
    }

    static func brandMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Self {
        .system(size: size, weight: weight, design: .monospaced)
    }

    func weight(_ weight: Font.Weight) -> Self {
        var copy = self
        copy.fontWeight = weight
        return copy
    }

    func bold() -> Self { weight(.bold) }
    func italic() -> Self {
        var copy = self
        copy.isItalic = true
        return copy
    }
    func monospaced() -> Self {
        var copy = self
        copy.design = .monospaced
        return copy
    }
    func monospacedDigit() -> Self {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }

    @MainActor
    func pointSize(using preferences: AppTypographyPreferences) -> CGFloat {
        let baseline = explicitSize ?? NSFont.preferredFont(forTextStyle: nativeTextStyle).pointSize
        return baseline * CGFloat(preferences.scale)
    }

    @MainActor
    func nsFont(using preferences: AppTypographyPreferences) -> NSFont {
        let size = pointSize(using: preferences)
        let font: NSFont
        if preferences.readingFont == .systemDefault, design == .monospaced {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: nativeWeight)
        } else if preferences.readingFont == .systemDefault || preferences.readingFont == .sanFrancisco {
            font = NSFont.systemFont(ofSize: size, weight: nativeWeight)
        } else {
            let regular = ViewerFonts.nsFont(for: preferences.readingFont, size: size, effectiveMode: .light)
            font = fontWeight == .bold || fontWeight == .semibold || fontWeight == .heavy || fontWeight == .black
                ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
        }
        return isItalic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    @MainActor
    func resolve(using preferences: AppTypographyPreferences) -> Font {
        var result: Font
        if preferences.readingFont == .systemDefault || preferences.readingFont == .sanFrancisco {
            result = .system(size: pointSize(using: preferences), weight: fontWeight,
                             design: preferences.readingFont == .systemDefault ? design : .default)
        } else {
            result = Font(nsFont(using: preferences)).weight(fontWeight)
        }
        if isItalic { result = result.italic() }
        if usesMonospacedDigits { result = result.monospacedDigit() }
        return result
    }

    private var nativeTextStyle: NSFont.TextStyle {
        switch textStyle {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    private var nativeWeight: NSFont.Weight {
        switch fontWeight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private struct AppFontModifier: ViewModifier {
    let style: AppFontStyle
    @Environment(\.uiTypography) private var typography

    func body(content: Content) -> some View {
        content.font(style.resolve(using: typography))
    }
}

extension View {
    func uiFont(_ style: AppFontStyle) -> some View {
        modifier(AppFontModifier(style: style))
    }
}

/// Every independently hosted window receives the same live appearance settings.
struct AppAppearanceScope: ViewModifier {
    let settings: AppSettings?
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let typography = settings?.uiTypography ?? AppTypographyPreferences()
        let reading = settings?.viewerAppearance ?? ViewerAppearancePreferences()
        let mode = reading.effectiveMode(systemIsDark: systemScheme == .dark)
        let palette = ViewerThemeResolver.resolve(mode: mode, sourceHex: reading.sourceAccentHex, nonNeon: settings?.reduceNeon ?? false)
        content
            .environment(\.uiTypography, typography)
            .environment(\.font, AppFontStyle.body.resolve(using: typography))
            .environment(\.viewerPalette, palette)
            .environment(\.viewerMode, mode)
            .background(NativeControlTypography(preferences: typography).frame(width: 0, height: 0))
            .buttonStyle(.typographyBordered)
            .menuStyle(.button)
            .tint(palette.primary.color)
            .preferredColorScheme(reading.themeMode.preferredColorScheme)
    }
}

/// Native bordered buttons impose a system title font and a fixed bezel height.
/// Draw the label in SwiftUI so custom families keep their metrics and hierarchy.
struct TypographyButtonStyle: ButtonStyle {
    enum Kind { case bordered, prominent, borderless }
    let kind: Kind
    @Environment(\.uiTypography) private var typography
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.viewerPalette) private var palette

    private var baseline: CGFloat {
        switch controlSize {
        case .mini: 9
        case .small: 11
        case .large: 15
        default: 13
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFontStyle.system(size: baseline).resolve(using: typography))
            .foregroundStyle(kind == .prominent ? AnyShapeStyle(palette.onPrimary.color) : AnyShapeStyle(.tint))
            .padding(.horizontal, kind == .borderless ? 0 : 9)
            .padding(.vertical, kind == .borderless ? 2 : 4)
            .background {
                if kind == .prominent {
                    RoundedRectangle(cornerRadius: 6).fill(.tint)
                } else if kind == .bordered {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == TypographyButtonStyle {
    static var typographyBordered: Self { Self(kind: .bordered) }
    static var typographyProminent: Self { Self(kind: .prominent) }
    static var typographyBorderless: Self { Self(kind: .borderless) }
}
