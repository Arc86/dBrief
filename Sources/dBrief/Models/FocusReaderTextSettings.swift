import Foundation

/// The Focus Reader's own text size and font. It reads larger than the viewer
/// (up to 40 pt) without changing the viewer's setting.
struct FocusReaderTextSettings: Equatable, Sendable {
    static let sizeRange = 14...40
    static let defaultSize = 22
    static let step = 2

    private(set) var size: Int
    /// Nil follows the viewer's reading font.
    var font: ViewerReadingFont?

    init(size: Int = defaultSize, font: ViewerReadingFont? = nil) {
        self.size = Self.clamped(size)
        self.font = font
    }

    mutating func enlarge() { size = Self.clamped(size + Self.step) }
    mutating func shrink() { size = Self.clamped(size - Self.step) }
    mutating func setSize(_ value: Int) { size = Self.clamped(value) }

    /// The size for a trackpad pinch, scaled from the size when it began.
    func pinched(by magnification: CGFloat) -> FocusReaderTextSettings {
        FocusReaderTextSettings(size: Int((CGFloat(size) * magnification).rounded()), font: font)
    }

    /// The viewer's reading preferences shown at this size and font.
    func applied(to viewer: ViewerAppearancePreferences) -> ViewerAppearancePreferences {
        var preferences = viewer
        preferences.displaySizeOverride = size
        if let font { preferences.readingFont = font }
        return preferences
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }
}
