import Foundation

enum AppThemeMode: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system

    var displayName: String {
        switch self {
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .system: String(localized: "Follow System")
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
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .paper: String(localized: "Paper")
        case .darkPaper: String(localized: "Dark Paper")
        }
    }

    var isDark: Bool {
        self == .dark || self == .darkPaper
    }

    var isPaper: Bool {
        self == .paper || self == .darkPaper
    }
}

/// Reading fonts, in menu order. Besides the originals, the easy-to-read set
/// from smartpress.com/blog/features/easy-to-read-fonts: macOS's own Arial,
/// Helvetica, Times New Roman, Verdana, Tahoma and Trebuchet MS; bundled Lato,
/// Open Sans, Roboto, EB Garamond and Lexend (OFL); and Calibri and Dyslexie,
/// offered only when installed (neither is redistributable). Any other installed
/// family is `installed`, and `sameAsInterface` lets the reading text follow
/// the interface font. Raw values are persisted, so they never change.
enum ViewerReadingFont: Hashable, Sendable {
    case sameAsInterface
    case systemDefault
    case sanFrancisco
    case arial
    case calibri
    case dyslexie
    case ebGaramond
    case georgia
    case helvetica
    case inter
    case lato
    case lexend
    case openSans
    case roboto
    case tahoma
    case timesNewRoman
    case trebuchetMS
    case verdana
    case openDyslexic
    case monospace
    /// Any installed font family, by its family name.
    case installed(String)

    private static let installedPrefix = "installed:"

    var displayName: String {
        switch self {
        case .sameAsInterface: String(localized: "Same as Interface Text")
        case .systemDefault: String(localized: "Default")
        case .sanFrancisco: "San Francisco"
        case .arial: "Arial"
        case .calibri: "Calibri"
        case .dyslexie: "Dyslexie"
        case .ebGaramond: "EB Garamond"
        case .georgia: "Georgia"
        case .helvetica: "Helvetica"
        case .inter: "Inter"
        case .lato: "Lato"
        case .lexend: "Lexend"
        case .openSans: "Open Sans"
        case .roboto: "Roboto"
        case .tahoma: "Tahoma"
        case .timesNewRoman: "Times New Roman"
        case .trebuchetMS: "Trebuchet MS"
        case .verdana: "Verdana"
        case .openDyslexic: "OpenDyslexic"
        case .monospace: String(localized: "Monospace")
        case .installed(let family): family
        }
    }

    /// The named choice for a font family, so a family picked from the
    /// installed list that is already on the menu is stored as that choice.
    static func forFamily(_ family: String) -> ViewerReadingFont {
        allCases.first { $0.familyName == family } ?? .installed(family)
    }

    /// The font family this choice draws with; nil for the system-font choices.
    var familyName: String? {
        switch self {
        case .sameAsInterface, .systemDefault, .sanFrancisco, .monospace: nil
        default: displayName
        }
    }
}

extension ViewerReadingFont: CaseIterable {
    /// The named fonts, in menu order: neither `sameAsInterface` nor `installed`.
    static let allCases: [ViewerReadingFont] = [
        .systemDefault, .sanFrancisco, .arial, .calibri, .dyslexie, .ebGaramond, .georgia, .helvetica,
        .inter, .lato, .lexend, .openSans, .roboto, .tahoma, .timesNewRoman, .trebuchetMS, .verdana,
        .openDyslexic, .monospace,
    ]
}

extension ViewerReadingFont: RawRepresentable {
    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.installedPrefix) {
            let family = String(rawValue.dropFirst(Self.installedPrefix.count))
            guard !family.isEmpty else { return nil }
            self = .installed(family)
        } else if rawValue == "sameAsInterface" {
            self = .sameAsInterface
        } else if let named = Self.allCases.first(where: { $0.rawValue == rawValue }) {
            self = named
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .sameAsInterface: "sameAsInterface"
        case .systemDefault: "systemDefault"
        case .sanFrancisco: "sanFrancisco"
        case .arial: "arial"
        case .calibri: "calibri"
        case .dyslexie: "dyslexie"
        case .ebGaramond: "ebGaramond"
        case .georgia: "georgia"
        case .helvetica: "helvetica"
        case .inter: "inter"
        case .lato: "lato"
        case .lexend: "lexend"
        case .openSans: "openSans"
        case .roboto: "roboto"
        case .tahoma: "tahoma"
        case .timesNewRoman: "timesNewRoman"
        case .trebuchetMS: "trebuchetMS"
        case .verdana: "verdana"
        case .openDyslexic: "openDyslexic"
        case .monospace: "monospace"
        case .installed(let family): Self.installedPrefix + family
        }
    }
}

extension ViewerReadingFont: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let font = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown reading font \(raw)"))
        }
        self = font
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ViewerDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case comfortable
    case spacious

    var displayName: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .comfortable: String(localized: "Comfortable")
        case .spacious: String(localized: "Spacious")
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
    /// A display-only size from the Focus Reader, which reads larger than the
    /// viewer's 12–24 range allows. Never saved; the viewer's `fontSize` stays.
    var displaySizeOverride: Int? = nil
    var effectiveFontSize: Int { displaySizeOverride ?? fontSize }
    /// Display-only line height (× text size) from the Focus Reader; overrides density.
    var displayLineHeightOverride: Double? = nil
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

    /// These preferences with "Same as Interface Text" replaced by the interface
    /// font. The interface's Default is the system font, so it becomes San
    /// Francisco rather than the reading Default (Georgia in Paper themes).
    func resolvingInterfaceFont(_ interfaceFont: ViewerReadingFont) -> Self {
        guard readingFont == .sameAsInterface else { return self }
        var resolved = self
        switch interfaceFont {
        case .systemDefault, .sameAsInterface: resolved.readingFont = .sanFrancisco
        default: resolved.readingFont = interfaceFont
        }
        return resolved
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
