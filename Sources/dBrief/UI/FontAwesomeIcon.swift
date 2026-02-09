import AppKit
import SwiftUI

/// Font Awesome 6 brand icon identifiers with their Unicode code points.
enum FABrandIcon: String {
    case slack = "\u{f198}"
    case microsoft = "\u{f3ca}"
    case google = "\u{f1a0}"
    case apple = "\u{f179}"
    case discord = "\u{f392}"

    /// Renders the brand icon as a SwiftUI Text view.
    func text(size: CGFloat) -> Text {
        Text(self.rawValue)
            .font(.custom("Font Awesome 6 Brands", size: size))
    }
}

/// Registers the bundled Font Awesome Brands font. Call once at app launch.
func registerFontAwesomeBrands() {
    guard let url = Bundle.main.url(forResource: "FontAwesome6Brands-Regular", withExtension: "otf") else {
        return
    }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
