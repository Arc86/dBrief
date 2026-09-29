import AppKit
import CoreText
import SwiftUI
import Testing
@testable import dBrief

@Suite("UI typography native render", .serialized) @MainActor
struct AppTypographyVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBRIEF_TYPOGRAPHY_SNAPSHOT_DIR"] != nil))
    func nativeControlsFollowFontChoiceWithoutInflatingTheGear() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fonts = root.appendingPathComponent("Sources/dBrief/Resources/Fonts")
        for url in try FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)
            where url.pathExtension == "otf" {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DBRIEF_TYPOGRAPHY_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for choice in [ViewerReadingFont.sanFrancisco, .inter, .openDyslexic] {
          for size in [14, 20] {
           for form in [false, true] {
            let preferences = AppTypographyPreferences(readingFont: choice, fontSize: size)
            let host = NSHostingView(rootView: TypographyFixture(form: form)
                .environment(\.uiTypography, preferences)
                .environment(\.font, AppFontStyle.body.resolve(using: preferences))
                .menuStyle(.button)
                .buttonStyle(.typographyBordered)
                .background(NativeControlTypography(preferences: preferences).frame(width: 0, height: 0)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let controls = descendants(host).compactMap { $0 as? NSControl }
                .filter { $0 is NSButton || $0 is NSTextField }
            #expect(!controls.isEmpty, "The fixture must exercise real native SwiftUI controls")
            let family = AppFontStyle.body.nsFont(using: preferences).familyName
            for control in controls {
                #expect((control.font?.pointSize ?? 0) <= CGFloat(size) + 1, "Control font must not be scaled twice")
                #expect(control.font?.familyName == family, "\(type(of: control)) font: \(String(describing: control.font))")
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("ui-\(choice.rawValue)-\(size)-\(form ? "form" : "controls").png"))
            window.close()
           }
          }
        }
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }
}

private struct TypographyFixture: View {
    let form: Bool
    @State private var theme = "Follow System"
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("dBrief").uiFont(.headline)
                Spacer()
                Text("Ready").uiFont(.caption)
                MenuBarSettingsMenu(onSettings: {})
            }
            if form {
                Form { controls }.formStyle(.grouped)
            } else {
                controls
            }
        }
        .padding(24)
        .frame(width: 600, height: 500)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Default theme mode", selection: $theme) {
                Text("Follow System").tag("Follow System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            HStack {
                Text("Recordings:")
                Spacer()
                Button("Choose…") {}.buttonStyle(.typographyBordered).controlSize(.small)
            }
            HStack {
                Menu("Jesper Mol") { Button("Rename…") {} }
                Spacer()
                Button("Transcribe File…") {}.buttonStyle(.typographyBordered).controlSize(.small)
            }
            Text("Ask a question about this transcript").uiFont(.callout)
            TextField("Ask a follow-up…", text: $message).textFieldStyle(.roundedBorder)
        }
    }
}
