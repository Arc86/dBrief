import Foundation
import Testing
@testable import dBrief

/// The repo's `Sources/dBrief/Resources`, located from this file's path so tests
/// run against the committed bundle without an app bundle.
enum MarkdownEditorSourceBundle {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // dBriefTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources/dBrief/Resources", isDirectory: true)
}

@Suite("Markdown editor bridge messages")
struct MarkdownEditorMessageTests {
    @Test("Decodes every message type")
    func decodesAll() {
        #expect(MarkdownEditorMessage(body: ["type": "ready"]) == .ready)
        #expect(MarkdownEditorMessage(body: ["type": "loaded", "markdown": "# Hi"]) == .loaded(markdown: "# Hi"))
        #expect(MarkdownEditorMessage(body: ["type": "changed", "markdown": ""]) == .changed(markdown: ""))
        #expect(MarkdownEditorMessage(body: ["type": "height", "value": 412] as [String: Any]) == .height(412))
        #expect(MarkdownEditorMessage(body: ["type": "height", "value": 98.5] as [String: Any]) == .height(98.5))
        #expect(MarkdownEditorMessage(body: ["type": "shortcut", "name": "save"]) == .shortcut(.save))
        #expect(MarkdownEditorMessage(body: ["type": "shortcut", "name": "cancel"]) == .shortcut(.cancel))
    }

    @Test("Malformed or unknown payloads are ignored")
    func rejectsMalformed() {
        #expect(MarkdownEditorMessage(body: "ready") == nil)
        #expect(MarkdownEditorMessage(body: ["kind": "ready"]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "loaded"]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "changed", "markdown": 3] as [String: Any]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "height", "value": "tall"]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "height", "value": -1] as [String: Any]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "shortcut", "name": "delete"]) == nil)
        #expect(MarkdownEditorMessage(body: ["type": "explode"]) == nil)
    }
}

@Suite("Markdown editor draft dirty tracking")
struct MarkdownEditorDraftTests {
    @Test("Not dirty before the editor reports its first serialization")
    func cleanBeforeLoaded() {
        var draft = MarkdownEditorDraft(initial: "* item")
        #expect(!draft.isDirty)
        draft.apply(.changed(markdown: "* edited"))   // stale, pre-load: ignored
        #expect(!draft.isDirty)
        #expect(draft.current == "* item")
    }

    @Test("Normalization on load is not an edit")
    func normalizationIsClean() {
        var draft = MarkdownEditorDraft(initial: "- item")
        draft.apply(.loaded(markdown: "* item\n"))
        #expect(draft.baseline == "* item\n")
        #expect(!draft.isDirty)
    }

    @Test("A real change is dirty; reverting it is clean again")
    func realChange() {
        var draft = MarkdownEditorDraft(initial: "Overview")
        draft.apply(.loaded(markdown: "Overview\n"))
        draft.apply(.changed(markdown: "Overview\n\nNieuwe alinea\n"))
        #expect(draft.isDirty)
        draft.apply(.changed(markdown: "Overview\n"))
        #expect(!draft.isDirty)
    }

    @Test("Whitespace-only differences at the ends are not dirty")
    func whitespaceOnly() {
        var draft = MarkdownEditorDraft(initial: "Tekst")
        draft.apply(.loaded(markdown: "Tekst\n"))
        draft.apply(.changed(markdown: "Tekst\n\n"))
        #expect(!draft.isDirty)
    }

    @Test("A reload keeps the original baseline (crash recovery / restored draft)")
    func reloadKeepsBaseline() {
        var draft = MarkdownEditorDraft(initial: "A")
        draft.apply(.loaded(markdown: "A\n"))
        draft.apply(.changed(markdown: "A B\n"))
        draft.apply(.loaded(markdown: "A B\n"))   // page reloaded with the draft
        #expect(draft.baseline == "A\n")
        #expect(draft.isDirty)
    }
}

@Suite("Markdown editor theme")
struct MarkdownEditorThemeTests {
    private let palette = ViewerThemeResolver.resolve(mode: .light, sourceHex: "#1268F5", nonNeon: false)

    @Test("Maps the viewer palette onto Crepe variables")
    func mapsPalette() {
        let theme = MarkdownEditorTheme(palette: palette, readingFont: .sanFrancisco, fontSize: 18,
                                        density: .comfortable, mode: .light)
        let vars = theme.cssVariables
        #expect(vars["--crepe-color-on-background"] == palette.text.hex)
        #expect(vars["--crepe-color-on-surface"] == palette.heading.hex)
        #expect(vars["--crepe-color-on-surface-variant"] == palette.secondary.hex)
        #expect(vars["--crepe-color-surface"] == palette.surface.hex)
        #expect(vars["--crepe-color-surface-low"] == palette.canvas.hex)
        #expect(vars["--crepe-color-outline"] == palette.divider.hex)
        #expect(vars["--crepe-color-primary"] == palette.accentText.hex)
        #expect(vars["--crepe-color-selected"] == palette.selected.hex)
        #expect(vars["--crepe-base-font-size"] == "18px")
        #expect(vars["--dbrief-line-height"] == "1.75")
        #expect(vars.count == 19)
        #expect(vars["--crepe-color-background"] == nil)   // stays transparent
    }

    @Test("Dark palettes produce different colors")
    func darkDiffers() {
        let dark = ViewerThemeResolver.resolve(mode: .dark, sourceHex: "#1268F5", nonNeon: false)
        let light = MarkdownEditorTheme(palette: palette, readingFont: .sanFrancisco, fontSize: 16, density: .comfortable, mode: .light)
        let darkTheme = MarkdownEditorTheme(palette: dark, readingFont: .sanFrancisco, fontSize: 16, density: .comfortable, mode: .dark)
        #expect(light.cssVariables["--crepe-color-on-background"] != darkTheme.cssVariables["--crepe-color-on-background"])
    }

    @Test("Font families follow the reading font, with paper defaulting to Georgia")
    func fontFamilies() {
        #expect(MarkdownEditorTheme.fontFamily(for: .systemDefault, mode: .light) == "-apple-system, system-ui, sans-serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .systemDefault, mode: .paper) == "Georgia, serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .georgia, mode: .light) == "Georgia, serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .inter, mode: .light) == "\"dBrief Inter\", -apple-system, sans-serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .openDyslexic, mode: .dark) == "\"dBrief OpenDyslexic\", -apple-system, sans-serif")
        #expect(MarkdownEditorTheme.fontFamily(for: .monospace, mode: .light) == "ui-monospace, Menlo, monospace")
    }
}

@Suite("Markdown editor script calls")
struct MarkdownEditorScriptTests {
    /// Pulls the JSON argument back out of `window.dbrief.fn(<json>);`.
    private func argument<T: Decodable>(_ script: String, function: String, as type: T.Type) throws -> T {
        let prefix = "window.dbrief.\(function)("
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(");"))
        let json = script.dropFirst(prefix.count).dropLast(2)
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("Hostile summary text survives as a JSON string literal")
    func hostileText() throws {
        let text = "Quote \" back\\slash </script> 'single' line\nbreak \u{2028} emoji 🎙️ `tick`"
        let script = MarkdownEditorScript.call("setMarkdown", text)
        #expect(!script.contains("</script>"))   // JSONEncoder escapes "/" so the tag can't close
        #expect(try argument(script, function: "setMarkdown", as: String.self) == text)
    }

    @Test("Booleans and theme dictionaries encode as JSON")
    func otherArguments() throws {
        #expect(MarkdownEditorScript.call("setReadOnly", true) == "window.dbrief.setReadOnly(true);")
        let vars = ["--a": "#FFFFFF", "--b": "16px"]
        #expect(try argument(MarkdownEditorScript.call("setTheme", vars), function: "setTheme", as: [String: String].self) == vars)
    }
}

@Suite("Markdown editor navigation policy")
struct MarkdownEditorNavigationTests {
    private let index = URL(fileURLWithPath: "/Applications/dBrief.app/Contents/Resources/MarkdownEditor/index.html")

    @Test("Only the bundled page itself may load")
    func allowsIndexOnly() {
        #expect(MarkdownEditorNavigation.decide(index, indexURL: index) == .allow)
        #expect(MarkdownEditorNavigation.decide(URL(string: index.absoluteString + "#top"), indexURL: index) == .allow)
        #expect(MarkdownEditorNavigation.decide(URL(fileURLWithPath: "/etc/hosts"), indexURL: index) == .cancel)
        #expect(MarkdownEditorNavigation.decide(URL(string: "about:blank"), indexURL: index) == .cancel)
        #expect(MarkdownEditorNavigation.decide(nil, indexURL: index) == .cancel)
    }

    @Test("Web and mail links open in the default app instead")
    func externalLinks() throws {
        let web = try #require(URL(string: "https://www.servicenow.com/path"))
        let mail = try #require(URL(string: "mailto:aaron@example.com"))
        #expect(MarkdownEditorNavigation.decide(web, indexURL: index) == .openExternally(web))
        #expect(MarkdownEditorNavigation.decide(mail, indexURL: index) == .openExternally(mail))
        #expect(MarkdownEditorNavigation.decide(URL(string: "javascript:alert(1)"), indexURL: index) == .cancel)
    }
}

@Suite("Markdown editor bundled resources")
struct MarkdownEditorResourcesTests {
    @Test("The committed bundle is present and complete")
    func bundlePresent() throws {
        let index = try #require(MarkdownEditorResources.indexURL(in: MarkdownEditorSourceBundle.resources))
        let directory = index.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("editor.js").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("editor.css").path))
        let html = try String(contentsOf: index, encoding: .utf8)
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("src=\"editor.js\""))
        #expect(html.contains("href=\"editor.css\""))
    }

    @Test("Missing bundle resolves to nil (swift run fallback)")
    func missingBundle() {
        #expect(MarkdownEditorResources.indexURL(in: URL(fileURLWithPath: "/nonexistent")) == nil)
        #expect(MarkdownEditorResources.indexURL(in: nil) == nil)
    }
}
