import Foundation

/// The Focus Reader's own text size and font. It reads larger than the viewer
/// (up to 40 pt) without changing the viewer's setting.
struct FocusReaderTextSettings: Equatable, Sendable {
    static let sizeRange = 14...40
    static let defaultSize = 22
    static let step = 2

    static let lineHeightRange = 1.3...2.6
    static let defaultLineHeight = 1.8

    private(set) var size: Int
    /// Nil follows the viewer's reading font.
    var font: ViewerReadingFont?
    /// Line height as a multiple of the text size.
    private(set) var lineHeight: Double

    init(size: Int = defaultSize, font: ViewerReadingFont? = nil, lineHeight: Double = defaultLineHeight) {
        self.size = Self.clamped(size)
        self.font = font
        self.lineHeight = min(max(lineHeight, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
    }

    mutating func setLineHeight(_ value: Double) {
        self = FocusReaderTextSettings(size: size, font: font, lineHeight: value)
    }

    mutating func enlarge() { size = Self.clamped(size + Self.step) }
    mutating func shrink() { size = Self.clamped(size - Self.step) }
    mutating func setSize(_ value: Int) { size = Self.clamped(value) }

    /// The size for a trackpad pinch, scaled from the size when it began.
    func pinched(by magnification: CGFloat) -> FocusReaderTextSettings {
        FocusReaderTextSettings(size: Int((CGFloat(size) * magnification).rounded()), font: font, lineHeight: lineHeight)
    }

    /// The viewer's reading preferences shown at this size and font.
    func applied(to viewer: ViewerAppearancePreferences) -> ViewerAppearancePreferences {
        var preferences = viewer
        preferences.displaySizeOverride = size
        preferences.displayLineHeightOverride = lineHeight
        if let font { preferences.readingFont = font }
        return preferences
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }
}

/// How wide the Focus Reader's reading column may grow.
enum FocusReaderWidth: String, CaseIterable, Sendable {
    case narrow, medium, wide, full

    static let `default` = FocusReaderWidth.wide

    var title: String {
        switch self {
        case .narrow: String(localized: "Narrow")
        case .medium: String(localized: "Medium")
        case .wide: String(localized: "Wide")
        case .full: String(localized: "Full width")
        }
    }

    /// Nil: the column fills the screen, less its margins.
    var maxWidth: CGFloat? {
        switch self {
        case .narrow: 680
        case .medium: 880
        case .wide: 1_120
        case .full: nil
        }
    }
}
