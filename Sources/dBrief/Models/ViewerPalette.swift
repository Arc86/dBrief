import Foundation

struct ViewerRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let isHex = value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 70)
                || (byte >= 97 && byte <= 102)
        }
        guard value.utf8.count == 6,
              isHex,
              let bits = UInt32(value, radix: 16)
        else {
            return nil
        }

        red = Double((bits >> 16) & 0xFF) / 255
        green = Double((bits >> 8) & 0xFF) / 255
        blue = Double(bits & 0xFF) / 255
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var hex: String {
        let red8 = Self.channel8(red)
        let green8 = Self.channel8(green)
        let blue8 = Self.channel8(blue)
        return String(format: "#%02X%02X%02X", red8, green8, blue8)
    }

    func mixed(with target: Self, fraction: Double) -> Self {
        let amount = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return Self(
            red: red * (1 - amount) + target.red * amount,
            green: green * (1 - amount) + target.green * amount,
            blue: blue * (1 - amount) + target.blue * amount
        )
    }

    private static func channel8(_ channel: Double) -> Int {
        Int((min(max(channel, 0), 1) * 255).rounded())
    }
}

struct ViewerPalette: Equatable, Sendable {
    let canvas: ViewerRGB
    let surface: ViewerRGB
    let heading: ViewerRGB
    let text: ViewerRGB
    let secondary: ViewerRGB
    let divider: ViewerRGB
    let sidebarTop: ViewerRGB
    let sidebarBottom: ViewerRGB
    let primary: ViewerRGB
    let onPrimary: ViewerRGB
    let accentText: ViewerRGB
    let selected: ViewerRGB
    let brandStops: [ViewerRGB]
    let readingCardCornerRadius: Double
}

enum ViewerThemeResolver {
    private static let white = rgb("#FFFFFF")
    private static let black = rgb("#000000")
    private static let defaultAccent = rgb(ViewerAppearancePreferences.defaultSourceAccentHex)
    private static let brandGradientStops = [
        rgb("#FFA52C"),
        rgb("#FF4B65"),
        rgb("#FA27BB"),
        rgb("#8B39FA"),
        rgb("#3261FF"),
        rgb("#00C8FF"),
    ]

    static func resolve(
        mode: ViewerAppearanceMode,
        sourceHex: String,
        nonNeon: Bool
    ) -> ViewerPalette {
        let tokens: Tokens = switch mode {
        case .light:
            Tokens(
                canvas: "#FBFCFE", surface: "#FFFFFF", heading: "#0B1430", text: "#31405F",
                secondary: "#65718A", divider: "#E1E7F0", sidebarTop: "#FAFBFD", sidebarBottom: "#F1F5FA",
                target: "#FFFFFF", mixFraction: 0
            )
        case .dark:
            Tokens(
                canvas: "#1B2029", surface: "#242C38", heading: "#F0F3FA", text: "#D2DAE8",
                secondary: "#A3AFC4", divider: "#3A4658", sidebarTop: "#202733", sidebarBottom: "#191F29",
                target: "#FFFFFF", mixFraction: 0.16
            )
        case .paper:
            Tokens(
                canvas: "#F5F2EB", surface: "#FFFCF5", heading: "#302D28", text: "#514B42",
                secondary: "#756D60", divider: "#DBD4C5", sidebarTop: "#F0ECE2", sidebarBottom: "#EAE5D9",
                target: "#82796A", mixFraction: 0.25
            )
        case .darkPaper:
            Tokens(
                canvas: "#24211D", surface: "#302C26", heading: "#F0E8D8", text: "#D8CDB9",
                secondary: "#B9AD98", divider: "#50483C", sidebarTop: "#2B2721", sidebarBottom: "#211E19",
                target: "#E0D2B8", mixFraction: 0.38
            )
        }

        let source = ViewerRGB(hex: sourceHex) ?? defaultAccent
        let canvas = rgb(tokens.canvas)
        let surface = rgb(tokens.surface)
        let target = rgb(tokens.target)
        let mixed = source.mixed(with: target, fraction: tokens.mixFraction)
        let primary = rounded(mixed)
        let selectedColour = mixed.mixed(with: canvas, fraction: 0.86)
        let selected = rounded(selectedColour)
        let onPrimary = contrast(mixed, white) >= contrast(mixed, black) ? white : black

        var unroundedAccentText = mixed
        let textTarget = mode.isDark ? white : black
        while min(
            contrast(unroundedAccentText, surface),
            contrast(unroundedAccentText, selectedColour)
        ) < 4.6 {
            unroundedAccentText = unroundedAccentText.mixed(with: textTarget, fraction: 0.10)
        }
        var accentText = rounded(unroundedAccentText)
        while min(contrast(accentText, surface), contrast(accentText, selected)) < 4.5 {
            unroundedAccentText = unroundedAccentText.mixed(with: textTarget, fraction: 0.10)
            accentText = rounded(unroundedAccentText)
        }

        return ViewerPalette(
            canvas: canvas,
            surface: surface,
            heading: rgb(tokens.heading),
            text: rgb(tokens.text),
            secondary: rgb(tokens.secondary),
            divider: rgb(tokens.divider),
            sidebarTop: rgb(tokens.sidebarTop),
            sidebarBottom: rgb(tokens.sidebarBottom),
            primary: primary,
            onPrimary: onPrimary,
            accentText: accentText,
            selected: selected,
            brandStops: nonNeon
                ? Array(repeating: primary, count: brandGradientStops.count)
                : brandGradientStops,
            readingCardCornerRadius: 20
        )
    }

    static func contrast(_ first: ViewerRGB, _ second: ViewerRGB) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ colour: ViewerRGB) -> Double {
        0.2126 * linearize(colour.red)
            + 0.7152 * linearize(colour.green)
            + 0.0722 * linearize(colour.blue)
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func rounded(_ colour: ViewerRGB) -> ViewerRGB {
        ViewerRGB(hex: colour.hex)!
    }

    private static func rgb(_ hex: String) -> ViewerRGB {
        ViewerRGB(hex: hex)!
    }

    private struct Tokens {
        let canvas: String
        let surface: String
        let heading: String
        let text: String
        let secondary: String
        let divider: String
        let sidebarTop: String
        let sidebarBottom: String
        let target: String
        let mixFraction: Double
    }
}
