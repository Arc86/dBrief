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
    let warning: ViewerRGB
    let accentBorder: ViewerRGB

    static func resolve(mode: ViewerAppearanceMode, base: ViewerPalette) -> MenuPanelPalette {
        let hex: (success: String, danger: String, dangerFill: String, dangerBorder: String, warning: String) = switch mode {
        case .light: ("#23804C", "#B93852", "#FFF2F5", "#D5B3C1", "#E0A21B")
        case .dark: ("#7BDCAA", "#FF91A6", "#382935", "#755C6F", "#E0A21B")
        case .paper: ("#3D7046", "#A63A3A", "#F8EAE3", "#D9B2A8", "#C08A2E")
        case .darkPaper: ("#9BD3A4", "#F2A08F", "#3D2C27", "#7A564C", "#D9A54A")
        }
        let success = rgb(hex.success)
        return MenuPanelPalette(
            success: success,
            successFill: rounded(success.mixed(with: base.surface, fraction: 0.95)),
            danger: rgb(hex.danger),
            dangerFill: rgb(hex.dangerFill),
            dangerBorder: rgb(hex.dangerBorder),
            warning: rgb(hex.warning),
            accentBorder: rounded(base.primary.mixed(with: base.surface, fraction: 0.5))
        )
    }

    private static func rgb(_ hex: String) -> ViewerRGB { ViewerRGB(hex: hex)! }
    private static func rounded(_ colour: ViewerRGB) -> ViewerRGB { ViewerRGB(hex: colour.hex)! }
}
