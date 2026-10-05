import Foundation

/// Status colours the menu bar panel needs on top of the viewer palette.
/// Light and dark match the Pen "Signature" frames; the paper values are tuned
/// to the paper surfaces and held to 4.5:1 by `MenuPanelPaletteTests`.
struct MenuPanelPalette: Equatable, Sendable {
    let success: ViewerRGB
    let successFill: ViewerRGB
    let danger: ViewerRGB
    let dangerFill: ViewerRGB
    let dangerBorder: ViewerRGB
    /// Label on a filled danger button (white or black, whichever reads better).
    let onDanger: ViewerRGB
    let warning: ViewerRGB
    /// Quiet accent outline (play circles); held to 3:1 against the surface.
    let accentBorder: ViewerRGB
    /// Accent for small marks (play glyph, level bars): the primary when it reads
    /// at 3:1 on the surface, otherwise the contrast-safe accent text colour.
    let accentMark: ViewerRGB

    static func resolve(mode: ViewerAppearanceMode, base: ViewerPalette) -> MenuPanelPalette {
        let hex: (success: String, danger: String, dangerFill: String, dangerBorder: String, warning: String) = switch mode {
        case .light: ("#23804C", "#B93852", "#FFF2F5", "#D5B3C1", "#E0A21B")
        case .dark: ("#7BDCAA", "#FF91A6", "#382935", "#755C6F", "#E0A21B")
        case .paper: ("#3D7046", "#A63A3A", "#F8EAE3", "#D9B2A8", "#C08A2E")
        case .darkPaper: ("#9BD3A4", "#F2A08F", "#3D2C27", "#7A564C", "#D9A54A")
        }
        let success = rgb(hex.success)
        let danger = rgb(hex.danger)
        let white = rgb("#FFFFFF"), black = rgb("#000000")
        let onDanger = ViewerThemeResolver.contrast(white, danger) >= ViewerThemeResolver.contrast(black, danger) ? white : black
        return MenuPanelPalette(
            success: success,
            successFill: rounded(success.mixed(with: base.surface, fraction: 0.95)),
            danger: danger,
            dangerFill: rgb(hex.dangerFill),
            dangerBorder: rgb(hex.dangerBorder),
            onDanger: onDanger,
            warning: rgb(hex.warning),
            accentBorder: visibleBorder(from: base.primary.mixed(with: base.surface, fraction: 0.5), on: base.surface),
            accentMark: ViewerThemeResolver.contrast(base.primary, base.surface) >= 3 ? base.primary : base.accentText
        )
    }

    /// Pushes a border away from the surface (toward black or white, whichever
    /// contrasts more) until it reaches the 3:1 non-text contrast floor.
    private static func visibleBorder(from start: ViewerRGB, on surface: ViewerRGB) -> ViewerRGB {
        let white = rgb("#FFFFFF"), black = rgb("#000000")
        let target = ViewerThemeResolver.contrast(white, surface) > ViewerThemeResolver.contrast(black, surface) ? white : black
        var border = rounded(start)
        for _ in 0..<20 where ViewerThemeResolver.contrast(border, surface) < 3 {
            border = rounded(border.mixed(with: target, fraction: 0.15))
        }
        return border
    }

    private static func rgb(_ hex: String) -> ViewerRGB { ViewerRGB(hex: hex)! }
    private static func rounded(_ colour: ViewerRGB) -> ViewerRGB { ViewerRGB(hex: colour.hex)! }
}
