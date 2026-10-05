import Foundation

/// Keyboard shortcuts the web editor forwards to the Summary card.
enum MarkdownEditorShortcut: String, Sendable {
    case save
    case cancel
}

/// A message posted by the bundled Milkdown page via `webkit.messageHandlers.dbrief`.
enum MarkdownEditorMessage: Equatable, Sendable {
    case ready
    /// The editor's own serialization right after `setMarkdown` — the dirty baseline.
    case loaded(markdown: String)
    case changed(markdown: String)
    case height(Double)
    case shortcut(MarkdownEditorShortcut)

    /// Decodes a `WKScriptMessage.body`; anything malformed is `nil` and ignored.
    init?(body: Any) {
        guard let fields = body as? [String: Any], let type = fields["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "loaded":
            guard let markdown = fields["markdown"] as? String else { return nil }
            self = .loaded(markdown: markdown)
        case "changed":
            guard let markdown = fields["markdown"] as? String else { return nil }
            self = .changed(markdown: markdown)
        case "height":
            guard let value = (fields["value"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            self = .height(value)
        case "shortcut":
            guard let name = fields["name"] as? String, let shortcut = MarkdownEditorShortcut(rawValue: name) else { return nil }
            self = .shortcut(shortcut)
        default:
            return nil
        }
    }
}

/// Dirty tracking against the editor's **own first serialization**, so opening and
/// closing the editor never rewrites a summary only because Milkdown normalized it.
struct MarkdownEditorDraft: Equatable, Sendable {
    private(set) var baseline: String?
    private(set) var current: String

    init(initial: String) {
        current = initial
    }

    var isDirty: Bool {
        guard let baseline else { return false }
        return Self.trimmed(current) != Self.trimmed(baseline)
    }

    mutating func apply(_ message: MarkdownEditorMessage) {
        switch message {
        case .loaded(let markdown):
            if baseline == nil { baseline = markdown }
            current = markdown
        case .changed(let markdown):
            // Before the first load the page has no real document yet.
            guard baseline != nil else { return }
            current = markdown
        case .ready, .height, .shortcut:
            break
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The viewer palette and reading font as CSS custom properties for the editor page.
struct MarkdownEditorTheme: Equatable, Sendable {
    let cssVariables: [String: String]

    init(palette: ViewerPalette, readingFont: ViewerReadingFont, fontSize: Int,
         density: ViewerDensity, mode: ViewerAppearanceMode) {
        let family = Self.fontFamily(for: readingFont, mode: mode)
        cssVariables = [
            "--crepe-color-on-background": palette.text.hex,
            "--crepe-color-surface": palette.surface.hex,
            "--crepe-color-surface-low": palette.canvas.hex,
            "--crepe-color-on-surface": palette.heading.hex,
            "--crepe-color-on-surface-variant": palette.secondary.hex,
            "--crepe-color-outline": palette.divider.hex,
            "--crepe-color-primary": palette.accentText.hex,
            "--crepe-color-secondary": palette.selected.hex,
            "--crepe-color-on-secondary": palette.heading.hex,
            "--crepe-color-inverse": palette.heading.hex,
            "--crepe-color-on-inverse": palette.surface.hex,
            "--crepe-color-inline-code": palette.accentText.hex,
            "--crepe-color-hover": palette.selected.hex,
            "--crepe-color-selected": palette.selected.hex,
            "--crepe-color-inline-area": palette.divider.hex,
            "--crepe-base-font-size": "\(fontSize)px",
            "--crepe-font-default": family,
            "--crepe-font-title": family,
            "--dbrief-line-height": String(density.lineHeightTarget),
        ]
    }

    init(palette: ViewerPalette, reading: ViewerAppearancePreferences, mode: ViewerAppearanceMode) {
        self.init(palette: palette, readingFont: reading.readingFont, fontSize: reading.fontSize,
                  density: reading.density, mode: mode)
    }

    /// Mirrors `ViewerFonts.nsFont(for:size:effectiveMode:)`; Inter and OpenDyslexic
    /// come from the page's `@font-face` rules over the bundled `Fonts/` files.
    static func fontFamily(for font: ViewerReadingFont, mode: ViewerAppearanceMode) -> String {
        switch font {
        case .systemDefault: mode.isPaper ? "Georgia, serif" : "-apple-system, system-ui, sans-serif"
        case .sanFrancisco: "-apple-system, system-ui, sans-serif"
        case .inter: "\"dBrief Inter\", -apple-system, sans-serif"
        case .georgia: "Georgia, serif"
        case .openDyslexic: "\"dBrief OpenDyslexic\", -apple-system, sans-serif"
        case .monospace: "ui-monospace, Menlo, monospace"
        }
    }
}

/// Builds `window.dbrief.<function>(<argument>);` with the argument JSON-encoded,
/// never string-interpolated, so any summary text is a safe JS literal.
enum MarkdownEditorScript {
    static func call<Argument: Encodable>(_ function: String, _ argument: Argument) -> String {
        let data = (try? JSONEncoder().encode(argument)) ?? Data("null".utf8)
        return "window.dbrief.\(function)(\(String(decoding: data, as: UTF8.self)));"
    }
}

/// What the editor's web view may navigate to.
enum MarkdownEditorNavigation {
    enum Decision: Equatable {
        case allow
        case openExternally(URL)
        case cancel
    }

    static func decide(_ url: URL?, indexURL: URL) -> Decision {
        guard let url else { return .cancel }
        if url.isFileURL, url.standardizedFileURL.path == indexURL.standardizedFileURL.path {
            return .allow
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .openExternally(url)
        default: return .cancel
        }
    }
}

/// Locates the committed Milkdown bundle (`Resources/MarkdownEditor/index.html`).
enum MarkdownEditorResources {
    static let directoryName = "MarkdownEditor"

    static func indexURL(in resourceDirectory: URL?) -> URL? {
        guard let resourceDirectory else { return nil }
        let index = resourceDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    /// `nil` when running outside the app bundle (e.g. `swift run`).
    static var bundledIndexURL: URL? { indexURL(in: Bundle.main.resourceURL) }
}
