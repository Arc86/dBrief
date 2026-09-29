import Foundation

/// App-wide control typography, independent of document reading preferences.
struct AppTypographyPreferences: Equatable, Sendable {
    static let defaultFontSize = 13
    static let fontSizeRange = 10...20

    var readingFont: ViewerReadingFont
    var fontSize: Int {
        didSet { fontSize = Self.clamp(fontSize) }
    }

    init(readingFont: ViewerReadingFont = .systemDefault, fontSize: Int = defaultFontSize) {
        self.readingFont = readingFont
        self.fontSize = Self.clamp(fontSize)
    }

    var scale: Double { Double(fontSize) / Double(Self.defaultFontSize) }

    static func load(from defaults: UserDefaults) -> Self {
        Self(
            readingFont: defaults.string(forKey: "uiFont").flatMap(ViewerReadingFont.init(rawValue:)) ?? .systemDefault,
            fontSize: defaults.object(forKey: "uiFontSize") as? Int ?? defaultFontSize
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(readingFont.rawValue, forKey: "uiFont")
        defaults.set(fontSize, forKey: "uiFontSize")
    }

    private static func clamp(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
