import Foundation

enum AppThemeMode: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Follow System"
        }
    }
}

enum ViewerAppearanceMode: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case paper
    case darkPaper

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .paper: "Paper"
        case .darkPaper: "Dark Paper"
        }
    }

    var isDark: Bool {
        self == .dark || self == .darkPaper
    }

    var isPaper: Bool {
        self == .paper || self == .darkPaper
    }
}

enum ViewerReadingFont: String, Codable, CaseIterable, Sendable {
    case systemDefault
    case sanFrancisco
    case inter
    case georgia
    case openDyslexic
    case monospace

    var displayName: String {
        switch self {
        case .systemDefault: "Default"
        case .sanFrancisco: "San Francisco"
        case .inter: "Inter"
        case .georgia: "Georgia"
        case .openDyslexic: "OpenDyslexic"
        case .monospace: "Monospace"
        }
    }
}

enum ViewerDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case comfortable
    case spacious

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }

    var rowVerticalPadding: Double {
        switch self {
        case .compact: 9
        case .comfortable: 17
        case .spacious: 25
        }
    }

    var speakerHeaderGap: Double {
        switch self {
        case .compact: 5
        case .comfortable: 9
        case .spacious: 13
        }
    }

    var lineHeightTarget: Double {
        switch self {
        case .compact: 1.55
        case .comfortable: 1.75
        case .spacious: 1.90
        }
    }
}

struct ViewerAppearancePreferences: Equatable, Sendable {
    static let defaultSourceAccentHex = "#1268F5"
    static let defaultFontSize = 16
    static let defaultChatFontSize = 14

    private enum Keys {
        static let mode = "viewerAppearanceMode"
        static let themeMode = "appThemeMode"
        static let lightTheme = "appLightTheme"
        static let darkTheme = "appDarkTheme"
        static let accentHex = "viewerAccentHex"
        static let readingFont = "viewerReadingFont"
        static let density = "viewerTranscriptDensity"
        static let fontSize = "transcriptFontSize"
        static let chatFontSize = "transcriptChatFontSize"
        static let showSpeakerNames = "showSpeakerNames"
    }

    var themeMode: AppThemeMode

    var lightTheme: ViewerAppearanceMode {
        didSet { if lightTheme.isDark { lightTheme = .light } }
    }

    var darkTheme: ViewerAppearanceMode {
        didSet { if !darkTheme.isDark { darkTheme = .dark } }
    }

    /// Compatibility for viewer quick controls and previously stored choices.
    var mode: ViewerAppearanceMode? {
        get {
            switch themeMode {
            case .light: lightTheme
            case .dark: darkTheme
            case .system: nil
            }
        }
        set {
            guard let newValue else {
                themeMode = .system
                return
            }
            if newValue.isDark {
                darkTheme = newValue
                themeMode = .dark
            } else {
                lightTheme = newValue
                themeMode = .light
            }
        }
    }

    var sourceAccentHex: String {
        didSet {
            if ViewerRGB(hex: sourceAccentHex) == nil {
                sourceAccentHex = Self.defaultSourceAccentHex
            }
        }
    }

    var readingFont: ViewerReadingFont
    var density: ViewerDensity

    var fontSize: Int {
        didSet { fontSize = Self.clampedFontSize(fontSize) }
    }

    var chatFontSize: Int {
        didSet { chatFontSize = Self.clampedChatFontSize(chatFontSize) }
    }

    var showSpeakerNames: Bool

    init(
        mode: ViewerAppearanceMode? = nil,
        themeMode: AppThemeMode? = nil,
        lightTheme: ViewerAppearanceMode = .light,
        darkTheme: ViewerAppearanceMode = .dark,
        sourceAccentHex: String = Self.defaultSourceAccentHex,
        readingFont: ViewerReadingFont = .systemDefault,
        density: ViewerDensity = .comfortable,
        fontSize: Int = Self.defaultFontSize,
        chatFontSize: Int = Self.defaultChatFontSize,
        showSpeakerNames: Bool = true
    ) {
        self.themeMode = themeMode ?? .system
        self.lightTheme = lightTheme.isDark ? .light : lightTheme
        self.darkTheme = darkTheme.isDark ? darkTheme : .dark
        self.sourceAccentHex = ViewerRGB(hex: sourceAccentHex) == nil
            ? Self.defaultSourceAccentHex
            : sourceAccentHex
        self.readingFont = readingFont
        self.density = density
        self.fontSize = Self.clampedFontSize(fontSize)
        self.chatFontSize = Self.clampedChatFontSize(chatFontSize)
        self.showSpeakerNames = showSpeakerNames
        if themeMode == nil { self.mode = mode }
    }

    static func load(from defaults: UserDefaults) -> Self {
        let mode = defaults.string(forKey: Keys.mode).flatMap(ViewerAppearanceMode.init(rawValue:))
        // Older installations stored a single explicit viewer theme. Retain it
        // until the new global mode has been saved for the first time.
        let themeMode: AppThemeMode? = defaults.object(forKey: Keys.themeMode) == nil
            ? nil
            : defaults.string(forKey: Keys.themeMode).flatMap(AppThemeMode.init(rawValue:)) ?? .system
        let lightTheme = defaults.string(forKey: Keys.lightTheme)
            .flatMap(ViewerAppearanceMode.init(rawValue:)) ?? .light
        let darkTheme = defaults.string(forKey: Keys.darkTheme)
            .flatMap(ViewerAppearanceMode.init(rawValue:)) ?? .dark
        let storedAccentHex = defaults.string(forKey: Keys.accentHex)
        let accentHex = storedAccentHex.flatMap { ViewerRGB(hex: $0) == nil ? nil : $0 }
            ?? defaultSourceAccentHex
        let readingFont = defaults.string(forKey: Keys.readingFont)
            .flatMap(ViewerReadingFont.init(rawValue:)) ?? .systemDefault
        let density = defaults.string(forKey: Keys.density)
            .flatMap(ViewerDensity.init(rawValue:)) ?? .comfortable
        let fontSize = defaults.object(forKey: Keys.fontSize) as? Int ?? defaultFontSize
        let chatFontSize = defaults.object(forKey: Keys.chatFontSize) as? Int ?? defaultChatFontSize
        let showSpeakerNames = defaults.object(forKey: Keys.showSpeakerNames) as? Bool ?? true

        return Self(
            mode: mode,
            themeMode: themeMode,
            lightTheme: lightTheme,
            darkTheme: darkTheme,
            sourceAccentHex: accentHex,
            readingFont: readingFont,
            density: density,
            fontSize: fontSize,
            chatFontSize: chatFontSize,
            showSpeakerNames: showSpeakerNames
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(themeMode.rawValue, forKey: Keys.themeMode)
        defaults.set(lightTheme.rawValue, forKey: Keys.lightTheme)
        defaults.set(darkTheme.rawValue, forKey: Keys.darkTheme)
        if let mode {
            defaults.set(mode.rawValue, forKey: Keys.mode)
        } else {
            defaults.removeObject(forKey: Keys.mode)
        }

        let accentHex = ViewerRGB(hex: sourceAccentHex) == nil
            ? Self.defaultSourceAccentHex
            : sourceAccentHex
        defaults.set(accentHex, forKey: Keys.accentHex)
        defaults.set(readingFont.rawValue, forKey: Keys.readingFont)
        defaults.set(density.rawValue, forKey: Keys.density)
        defaults.set(Self.clampedFontSize(fontSize), forKey: Keys.fontSize)
        defaults.set(Self.clampedChatFontSize(chatFontSize), forKey: Keys.chatFontSize)
        defaults.set(showSpeakerNames, forKey: Keys.showSpeakerNames)
    }

    func effectiveMode(systemIsDark: Bool) -> ViewerAppearanceMode {
        switch themeMode {
        case .light: lightTheme
        case .dark: darkTheme
        case .system: systemIsDark ? darkTheme : lightTheme
        }
    }

    /// Resolves the "Default" reading choice without changing its stored value.
    func effectiveReadingFont(for mode: ViewerAppearanceMode) -> ViewerReadingFont {
        readingFont == .systemDefault && mode.isPaper ? .georgia : readingFont
    }

    /// Resets only reading controls. Appearance, accent, and unrelated settings remain intact.
    mutating func resetReading() {
        readingFont = .systemDefault
        fontSize = Self.defaultFontSize
        density = .comfortable
        showSpeakerNames = true
    }

    private static func clampedFontSize(_ size: Int) -> Int {
        min(max(size, 12), 24)
    }

    private static func clampedChatFontSize(_ size: Int) -> Int {
        min(max(size, 12), 24)
    }
}
